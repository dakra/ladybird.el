;;; ladybird-live.el --- Elate startup for the live scenarios -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded with `elate start --eval-file' by the scenarios of
;; test/elate/live/scenarios, which drive the package against a real
;; Ladybird server.  Puts ladybird from this checkout on the load-path,
;; loads the native module (the one with the test accessors from
;; .build/test-module when it is built) and defines the helpers the
;; steps call.
;;
;; A scenario starts with (ladybird-live-start VARIANT PAGE).  VARIANT
;; says where the server is:
;;
;;   "stdio"    a local server started by the connection
;;   "socket"   a local server listening on a Unix socket
;;   "ssh"      a server on another machine, started by ssh
;;   "forward"  a server on another machine listening on a Unix socket
;;              that ssh forwards to this machine
;;
;; The pages come from test/elate/live/serve.py, which runs on the
;; server's machine: here for the local variants, and for the remote
;; ones on the remote machine, where the pages are copied to a temporary
;; directory.  So every server loads http://127.0.0.1:PORT/PAGE.  A page
;; reports its state in its title as "key=value;key=value", which
;; `ladybird-live-field' reads from the buffer's state.
;;
;; ssh runs through the script test/elate/live/ssh, with the user's own
;; home directory and without connection sharing.
;;
;; Environment:
;;
;;   LADYBIRD_LIVE_PROGRAM         the local Ladybird program
;;   LADYBIRD_LIVE_SSH_HOST        ssh destination of the remote machine
;;   LADYBIRD_LIVE_REMOTE_PROGRAM  the Ladybird program there
;;   LADYBIRD_LIVE_PYTHON          Python that runs serve.py here
;;   LADYBIRD_LIVE_REMOTE_PYTHON   Python that runs it on the remote machine
;;   LADYBIRD_LIVE_HOME            the home directory ssh uses, by default
;;                                 that of the user who runs Emacs
;;   LADYBIRD_LIVE_RUN             a word in the names of sockets, set by
;;                                 run-live.sh to find what a run left

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst ladybird-live-directory
  (expand-file-name "../" (file-name-directory (or load-file-name
                                                   buffer-file-name)))
  "The directory test/elate/live.")

(defconst ladybird-live-repo
  (expand-file-name "../../../" ladybird-live-directory)
  "The ladybird checkout.")

(add-to-list 'load-path (expand-file-name "lisp" ladybird-live-repo))

(setq load-prefer-newer t
      ring-bell-function 'ignore
      use-short-answers t)

(defvar ladybird-module-directory)
(let ((directory (expand-file-name ".build/test-module" ladybird-live-repo)))
  (when (file-exists-p (expand-file-name (concat "ladybird-module"
                                                 module-file-suffix)
                                         directory))
    (setq ladybird-module-directory directory)))

(require 'ladybird)

(unless (ladybird-load-module)
  (error "The native module does not load; run `make build'"))

(defvar ladybird-live-program
  (or (getenv "LADYBIRD_LIVE_PROGRAM")
      "/Users/daniel/src/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird")
  "The local Ladybird program.")

(defvar ladybird-live-ssh-host (getenv "LADYBIRD_LIVE_SSH_HOST")
  "The ssh destination of the remote machine, or nil.")

(defvar ladybird-live-remote-program
  (or (getenv "LADYBIRD_LIVE_REMOTE_PROGRAM") "Ladybird")
  "The Ladybird program on the remote machine.")

(defvar ladybird-live-python
  (or (getenv "LADYBIRD_LIVE_PYTHON")
      (seq-find #'file-executable-p
                '("/opt/homebrew/bin/python3" "/usr/local/bin/python3"
                  "/usr/bin/python3"))
      "python3")
  "The Python that runs the page server.")

(defvar ladybird-live-remote-python
  (or (getenv "LADYBIRD_LIVE_REMOTE_PYTHON") "python3")
  "The Python that runs the page server on the remote machine.")

(defconst ladybird-live-ssh (expand-file-name "ssh" ladybird-live-directory)
  "The script that runs ssh for the scenarios.")

(unless (getenv "LADYBIRD_LIVE_HOME")
  (setenv "LADYBIRD_LIVE_HOME"
          (expand-file-name (concat "~" (user-real-login-name)))))

(defconst ladybird-live-id
  (format "%s-%d" (or (getenv "LADYBIRD_LIVE_RUN") "manual") (emacs-pid))
  "A word that names this session's sockets and remote processes.")

(defconst ladybird-live-socket (format "/tmp/ladybird-live-%s.sock" ladybird-live-id)
  "The Unix socket the connection of a socket variant dials.")

(defconst ladybird-live-remote-socket
  (format "/tmp/ladybird-live-%s-remote.sock" ladybird-live-id)
  "The Unix socket of the server on the remote machine.")

(defconst ladybird-live-remote-directory
  (format "/tmp/ladybird-live-%s-pages" ladybird-live-id)
  "The directory of the pages on the remote machine.")

(defvar ladybird-live-variant nil "The variant of the running scenario.")
(defvar ladybird-live-port nil "Port of the page server.")
(defvar ladybird-live-http nil "Process of the page server.")
(defvar ladybird-live-server nil "Process of the server of a socket variant.")
(defvar ladybird-live-tunnel nil "The ssh process that forwards ports and sockets.")
(defvar ladybird-live-intruder nil "Connection of the second client.")
(defvar ladybird-live-sent nil "Types of the messages sent, newest first.")
(defvar ladybird-live-received nil "The messages received, newest first.")
(defvar ladybird-live-statuses nil
  "Statuses of the frames received, newest first.")
(defvar ladybird-live-scratch nil "A variable for the steps of a scenario.")
(defvar ladybird-live-saved nil "Another variable for the steps of a scenario.")

(advice-add 'ladybird--send :before
            (lambda (_conn message)
              (push (alist-get 'type message) ladybird-live-sent))
            '((name . ladybird-live)))

(advice-add 'ladybird--handle-frame :before
            (lambda (_conn event) (push (car (last event)) ladybird-live-statuses))
            '((name . ladybird-live)))

(advice-add 'ladybird--handle-control :before
            (lambda (_conn message) (push message ladybird-live-received))
            '((name . ladybird-live)))


;;; Servers

(defun ladybird-live--wait (predicate seconds what)
  "Wait until PREDICATE returns non-nil, at most SECONDS; WHAT names it."
  (with-timeout (seconds (error "Timed out waiting for %s" what))
    (while (not (funcall predicate))
      (accept-process-output nil 0.05))))

(defun ladybird-live--remote (&rest command)
  "Run COMMAND on the remote machine and return its exit status."
  (apply #'call-process ladybird-live-ssh nil nil nil
         ladybird-live-ssh-host command))

(defun ladybird-live-remote-p ()
  "Return non-nil if the scenario's server runs on the remote machine."
  (member ladybird-live-variant '("ssh" "forward")))

(defun ladybird-live--http ()
  "Start the page server unless it runs and return its port.
It runs on the machine of the scenario's server."
  (unless (process-live-p ladybird-live-http)
    (when (ladybird-live-remote-p)
      ;; Copy the pages and the server to the remote machine.
      (unless (eql 0 (call-process-shell-command
                      (format "tar -C %s -cf - serve.py pages | %s %s %s"
                              (shell-quote-argument ladybird-live-directory)
                              (shell-quote-argument ladybird-live-ssh)
                              (shell-quote-argument ladybird-live-ssh-host)
                              (shell-quote-argument
                               (format "rm -rf %s && mkdir -p %s && tar -xf - -C %s"
                                       ladybird-live-remote-directory
                                       ladybird-live-remote-directory
                                       ladybird-live-remote-directory)))))
        (error "Cannot copy the pages to %s" ladybird-live-ssh-host)))
    (setq ladybird-live-port nil
          ladybird-live-http
          (make-process
           :name "ladybird-live-http" :buffer nil :noquery t
           :connection-type 'pipe
           :command (if (ladybird-live-remote-p)
                        (list ladybird-live-ssh ladybird-live-ssh-host
                              ladybird-live-remote-python
                              (concat ladybird-live-remote-directory "/serve.py")
                              "--exit-on-eof"
                              "--label" (concat "ladybird-live-" ladybird-live-id))
                      (list ladybird-live-python "-I"
                            (expand-file-name "serve.py" ladybird-live-directory)
                            "--label" (concat "ladybird-live-" ladybird-live-id)))
           :filter (lambda (_process output)
                     (when (string-match "ready \\([0-9]+\\)" output)
                       (setq ladybird-live-port
                             (string-to-number (match-string 1 output)))))))
    (ladybird-live--wait (lambda () ladybird-live-port) 20 "the page server"))
  ladybird-live-port)

(defun ladybird-live-url (page)
  "Return the URL of PAGE, a file name under pages/ with its query."
  (format "http://127.0.0.1:%d/%s" (ladybird-live--http) page))

(defun ladybird-live--serve ()
  "Start a local server that listens on `ladybird-live-socket'."
  (when (process-live-p ladybird-live-server)
    (delete-process ladybird-live-server))
  (when (file-exists-p ladybird-live-socket)
    (delete-file ladybird-live-socket))
  (setq ladybird-live-server
        (make-process :name "ladybird-live-server" :buffer nil :noquery t
                      :command (list ladybird-live-program "--headless=emacs"
                                     "--emacs-socket" ladybird-live-socket)))
  (ladybird-live--wait (lambda () (file-exists-p ladybird-live-socket)) 30
                       "the server's socket"))

(defun ladybird-live--serve-remote ()
  "Start a server on the remote machine on `ladybird-live-remote-socket'.
It runs on a terminal of its ssh, so it ends with that ssh."
  (when (process-live-p ladybird-live-server)
    (delete-process ladybird-live-server))
  (ladybird-live--remote "rm" "-f" ladybird-live-remote-socket)
  (setq ladybird-live-server
        (make-process :name "ladybird-live-server" :buffer nil :noquery t
                      :command (list ladybird-live-ssh "-tt"
                                     ladybird-live-ssh-host
                                     ladybird-live-remote-program
                                     "--headless=emacs" "--emacs-socket"
                                     ladybird-live-remote-socket)))
  (ladybird-live--wait
   (lambda () (eql 0 (ladybird-live--remote "test" "-S"
                                            ladybird-live-remote-socket)))
   60 "the remote server's socket"))

(defun ladybird-live--forward ()
  "Start the ssh that forwards `ladybird-live-socket' to the remote server."
  (when (process-live-p ladybird-live-tunnel)
    (delete-process ladybird-live-tunnel))
  (when (file-exists-p ladybird-live-socket)
    (delete-file ladybird-live-socket))
  (setq ladybird-live-tunnel
        (make-process
         :name "ladybird-live-tunnel" :buffer nil :noquery t
         :command (list ladybird-live-ssh "-N"
                        "-o" "ExitOnForwardFailure=yes"
                        "-o" "StreamLocalBindUnlink=yes"
                        "-L" (format "%s:%s" ladybird-live-socket
                                     ladybird-live-remote-socket)
                        ladybird-live-ssh-host)))
  (ladybird-live--wait (lambda () (file-exists-p ladybird-live-socket)) 30
                       "the forwarded socket"))

(defun ladybird-live-serve ()
  "Start the server of a socket variant, again after it was killed."
  (pcase ladybird-live-variant
    ("socket" (ladybird-live--serve))
    ("forward" (ladybird-live--serve-remote) (ladybird-live--forward))
    (_ (error "The %s variant has no server of its own" ladybird-live-variant))))

(defun ladybird-live-kill-server ()
  "Kill the server of a socket variant."
  (when (process-live-p ladybird-live-server)
    (delete-process ladybird-live-server))
  (when (equal ladybird-live-variant "forward")
    (ladybird-live--remote "pkill" "-f" ladybird-live-remote-socket)))

(defun ladybird-live-start (variant &optional page)
  "Start what VARIANT needs and open PAGE, by default index.html.
Return the page buffer."
  (setq ladybird-live-variant variant
        ladybird-live-sent nil
        ladybird-live-received nil
        ladybird-live-statuses nil
        ladybird-ssh-program ladybird-live-ssh)
  (when (and (ladybird-live-remote-p) (not ladybird-live-ssh-host))
    (error "LADYBIRD_LIVE_SSH_HOST is not set"))
  (ladybird-live--http)
  (pcase variant
    ("stdio"
     (setq ladybird-program ladybird-live-program
           ladybird-hosts nil
           ladybird-default-host nil))
    ("socket"
     (ladybird-live--serve)
     (setq ladybird-hosts (list (cons "live" ladybird-live-socket))
           ladybird-default-host "live"))
    ("ssh"
     (setq ladybird-hosts (list (list "live" :ssh ladybird-live-ssh-host
                                      :program ladybird-live-remote-program))
           ladybird-default-host "live"))
    ("forward"
     (ladybird-live--serve-remote)
     (ladybird-live--forward)
     (setq ladybird-hosts (list (cons "live" ladybird-live-socket))
           ladybird-default-host "live"))
    (_ (error "Unknown variant %S" variant)))
  (ladybird (ladybird-live-url (or page "index.html"))))

(defun ladybird-live-cleanup ()
  "Close every page, connection, server and forwarding of the scenario."
  (mapc #'kill-buffer (ladybird--buffers))
  (mapc #'ladybird--disconnect ladybird--conns)
  (dolist (process (list ladybird-live-intruder ladybird-live-tunnel
                         ladybird-live-http))
    (when (process-live-p process)
      (delete-process process)))
  (when ladybird-live-server
    (ladybird-live-kill-server))
  (if (and ladybird-live-ssh-host (ladybird-live-remote-p))
      (ladybird-live--remote
       "sh" "-c" (shell-quote-argument
                  (format "rm -rf /tmp/ladybird-live-%s-*" ladybird-live-id)))
    (dolist (file (file-expand-wildcards
                   (format "/tmp/ladybird-live-%s-*" ladybird-live-id)))
      (delete-file file)))
  (when (file-exists-p ladybird-live-socket)
    (delete-file ladybird-live-socket))
  t)


;;; The page

(defun ladybird-live-buffer ()
  "Return the page buffer used last, or the first one."
  (or (and (buffer-live-p ladybird--last-buffer) ladybird--last-buffer)
      (car (ladybird--buffers))))

(defmacro ladybird-live-in-page (&rest body)
  "Run BODY in the page buffer."
  (declare (indent 0))
  `(with-current-buffer (ladybird-live-buffer) ,@body))

(defun ladybird-live-conn ()
  "Return the page buffer's connection."
  (buffer-local-value 'ladybird--conn (ladybird-live-buffer)))

(defun ladybird-live-state (field)
  "Return FIELD of the page's state."
  (ladybird-live-in-page (alist-get field ladybird--state)))

(defun ladybird-live-field (key)
  "Return the value the page reports for KEY in its title, or nil."
  (when-let* ((title (ladybird-live-state 'title)))
    (cl-loop for part in (split-string title ";")
             when (string-prefix-p (concat key "=") part)
             return (substring part (1+ (length key))))))

(defun ladybird-live-number (key)
  "Return the number the page reports for KEY, or nil."
  (when-let* ((value (ladybird-live-field key)))
    (string-to-number value)))

(defun ladybird-live-page-p (page)
  "Return non-nil once the page named PAGE is loaded and has a frame."
  (and (ladybird-live-buffer)
       (equal (ladybird-live-field "page") page)
       (not (ladybird-live-state 'loading))
       (ladybird-live-in-page ladybird--canvas)
       t))

(defun ladybird-live-load (page)
  "Load PAGE, a file name under pages/, in the page buffer."
  (ladybird-live-in-page (ladybird-goto-url (ladybird-live-url page))))

(defun ladybird-live-header ()
  "Return the page buffer's header line as plain text."
  (ladybird-live-in-page (substring-no-properties (ladybird--header-line))))

(defun ladybird-live-color (x y)
  "Return the colour of the canvas at X, Y in Emacs pixels, as \"#rrggbb\"."
  (ladybird-live-in-page
    (format "#%06x"
            (logand #xffffff
                    (ladybird-module-canvas-pixel
                     ladybird--canvas
                     (round (* x ladybird--dpr)) (round (* y ladybird--dpr)))))))

(defun ladybird-live-messages-p (regexp)
  "Return non-nil if a line of *Messages* matches REGEXP."
  (with-current-buffer (messages-buffer)
    (save-excursion
      (goto-char (point-min))
      (re-search-forward regexp nil t))))

(defun ladybird-live-received (type &rest fields)
  "Return the last message of TYPE received whose FIELDS have these values.
FIELDS is a property list of field symbols and values."
  (seq-find (lambda (message)
              (and (equal (alist-get 'type message) type)
                   (cl-loop for (key value) on fields by #'cddr
                            always (equal (alist-get key message) value))))
            ladybird-live-received))

(defun ladybird-live-hint-values (field)
  "Return FIELD of every item of the hint session, in the page's order."
  (and ladybird--hint
       (mapcar (lambda (item) (alist-get field item))
               (ladybird--hint-items ladybird--hint))))

(defun ladybird-live-sent-count (type)
  "Return the number of messages of TYPE sent."
  (seq-count (lambda (sent) (equal sent type)) ladybird-live-sent))

(defun ladybird-live-stats (key)
  "Return the module's counter KEY of the page's connection."
  (plist-get (ladybird-module-stats (ladybird--conn-decoder (ladybird-live-conn)))
             key))

(defun ladybird-live-healthy-p ()
  "Return t if the page's connection lost no frame.
Signal an error that says what is wrong otherwise.  Every frame has to
be acknowledged, and none dropped but those a forwarded socket offers
in shared memory this machine cannot map."
  (let ((conn (ladybird-live-conn))
        (bad (seq-remove (lambda (status)
                           (or (memq status '(painted stored size-mismatch))
                               (and (eq status 'shm-error)
                                    (equal ladybird-live-variant "forward"))))
                         ladybird-live-statuses)))
    (unless (ladybird--ready-p conn)
      (error "The connection is %s" (ladybird--conn-state conn)))
    (unless (eq (ladybird-live-stats :state) 'ok)
      (error "The stream is %s" (ladybird-live-stats :state)))
    (when bad
      (error "Frames were dropped: %S" bad))
    (unless (memq 'painted ladybird-live-statuses)
      (error "No frame was painted"))
    (unless (= (ladybird-live-sent-count "frame_ack")
               (length ladybird-live-statuses))
      (error "%d frames, %d acknowledged" (length ladybird-live-statuses)
             (ladybird-live-sent-count "frame_ack")))
    (ladybird-live-in-page
      (unless (and ladybird--canvas
                   (equal ladybird--canvas-size
                          (ladybird-module-view-size (ladybird--conn-decoder conn)
                                                     ladybird--view)))
        (error "The canvas is %S, the last frame %S" ladybird--canvas-size
               (ladybird-module-view-size (ladybird--conn-decoder conn)
                                          ladybird--view))))
    t))

(defun ladybird-live-shm-p ()
  "Return non-nil if the page's frames come through shared memory."
  (and (eq (ladybird--conn-shm (ladybird-live-conn)) t)
       (not (ladybird--conn-shm-failed (ladybird-live-conn)))
       (> (ladybird-live-stats :shm-size) 0)))

(defun ladybird-live-shm-as-expected-p ()
  "Return t if shared memory is used as the variant should use it.
A local server hands frames over in shared memory.  A server reached
by ssh is not offered it.  Through a forwarded socket it is offered,
cannot be mapped, and the server is told so once.  Signal an error that
says what is wrong otherwise."
  (let ((conn (ladybird-live-conn)))
    (pcase ladybird-live-variant
      ((or "stdio" "socket")
       (unless (ladybird-live-shm-p)
         (error "Shared memory is not in use: welcome %S, failed %S, mapped %d"
                (ladybird--conn-shm conn) (ladybird--conn-shm-failed conn)
                (ladybird-live-stats :shm-size))))
      ("ssh"
       (when (or (ladybird--conn-shm conn) (> (ladybird-live-stats :shm-size) 0)
                 (> (ladybird-live-sent-count "shm_failed") 0))
         (error "Shared memory was negotiated over ssh")))
      ("forward"
       (unless (and (ladybird--conn-shm-failed conn)
                    (= (ladybird-live-sent-count "shm_failed") 1)
                    (= (ladybird-live-stats :shm-size) 0))
         (error "No fallback from shared memory: failed %S, shm_failed sent %d"
                (ladybird--conn-shm-failed conn)
                (ladybird-live-sent-count "shm_failed")))))
    t))

(defun ladybird-live-platform ()
  "Return the platform the server names: \"macos\", \"linux\" or \"unknown\"."
  (alist-get 'platform
             (alist-get 'host (ladybird--conn-server-info (ladybird-live-conn)))))

(defun ladybird-live-server-file (name &optional contents)
  "Return the name of a temporary file NAME on the server's machine.
With CONTENTS, a string, the file is written first."
  (let ((file (format "/tmp/ladybird-live-%s-%s" ladybird-live-id name)))
    (when contents
      (if (ladybird-live-remote-p)
          (unless (eql 0 (ladybird-live--remote
                          "sh" "-c"
                          (shell-quote-argument
                           (format "printf %%s %s > %s"
                                   (shell-quote-argument contents) file))))
            (error "Cannot write %s on %s" file ladybird-live-ssh-host))
        (with-temp-file file (insert contents))))
    file))

(defun ladybird-live-server-file-size (file)
  "Return the size of FILE on the server's machine, or nil if it is not there."
  (if (ladybird-live-remote-p)
      (with-temp-buffer
        (and (eql 0 (call-process ladybird-live-ssh nil t nil ladybird-live-ssh-host
                                  "wc" "-c" file))
             (progn (goto-char (point-min))
                    (re-search-forward "[0-9]+" nil t))
             (string-to-number (match-string 0))))
    (and (file-exists-p file)
         (file-attribute-size (file-attributes file)))))


;;; Input

(defun ladybird-live--posn (x y)
  "Return the mouse position at X, Y of the page window's canvas."
  (let ((window (get-buffer-window (ladybird-live-buffer))))
    (posn-at-x-y x (+ y (window-header-line-height window)) window)))

(defun ladybird-live--events (&rest events)
  "Queue EVENTS for the command loop."
  (setq unread-command-events (append unread-command-events events))
  nil)

(defun ladybird-live-click (x y &optional button)
  "Click mouse BUTTON, by default 1, at X, Y of the canvas."
  (let ((posn (ladybird-live--posn x y))
        (n (or button 1)))
    (ladybird-live--events
     (list (intern (format "down-mouse-%d" n)) posn)
     (list (intern (format "mouse-%d" n)) posn))))

(defun ladybird-live-double-click (x y)
  "Double click at X, Y of the canvas."
  (let ((posn (ladybird-live--posn x y)))
    (ladybird-live--events
     (list 'down-mouse-1 posn) (list 'mouse-1 posn)
     (list 'double-down-mouse-1 posn 2) (list 'double-mouse-1 posn 2))))

(defun ladybird-live-drag (x1 y1 x2 y2)
  "Press the mouse at X1, Y1 of the canvas, move to X2, Y2 and release."
  (let ((from (ladybird-live--posn x1 y1))
        (to (ladybird-live--posn x2 y2)))
    (ladybird-live--events
     (list 'down-mouse-1 from)
     (list 'mouse-movement (ladybird-live--posn (/ (+ x1 x2) 2) (/ (+ y1 y2) 2)))
     (list 'mouse-movement to)
     (list 'drag-mouse-1 from to))))

(defun ladybird-live-move (x y)
  "Move the mouse to X, Y of the canvas."
  (ladybird-live--events (list 'mouse-movement (ladybird-live--posn x y))))

(defun ladybird-live-wheel (x y dy)
  "Turn the wheel at X, Y of the canvas by DY pixels, down if positive."
  (ladybird-live--events
   (list (if (> dy 0) 'wheel-down 'wheel-up) (ladybird-live--posn x y) 1 1
         (cons 0.0 (float (- dy))))))


;;; Processes of the server

(defun ladybird-live-server-pid ()
  "Return the process id of the server, on its machine.
The name of its log file has it."
  (let ((log (alist-get 'log (ladybird--conn-server-info (ladybird-live-conn)))))
    (if (and log (string-match "\\([0-9]+\\)[^0-9/]*\\'" log))
        (string-to-number (match-string 1 log))
      (error "No process id in the log name %S" log))))

(defun ladybird-live-crash ()
  "Kill the server's WebContent processes."
  (let ((pid (number-to-string (ladybird-live-server-pid))))
    (if (ladybird-live-remote-p)
        (ladybird-live--remote "pkill" "-KILL" "-P" pid "WebContent")
      (call-process "pkill" nil nil nil "-KILL" "-P" pid "WebContent"))))

(defun ladybird-live-intrude ()
  "Connect a second client to the socket, which replaces the first."
  (let ((process (make-network-process
                  :name "ladybird-live-intruder" :family 'local
                  :service ladybird-live-socket :coding 'binary :noquery t)))
    (setq ladybird-live-intruder process)
    (process-send-string
     process
     (ladybird--encode-record
      1 (json-serialize '((type . "hello") (protocol . 1) (client . "intruder")
                          (viewport . ((width . 320) (height . 240) (dpr . 1.0)))
                          (encodings . ["raw"]) (shm . :false)))))))

(provide 'ladybird-live)

;;; ladybird-live.el ends here
