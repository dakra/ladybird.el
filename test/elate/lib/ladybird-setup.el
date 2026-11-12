;;; ladybird-setup.el --- Elate startup for ladybird sessions -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded with `elate start --eval-file'.  Puts ladybird from this checkout
;; on the load-path, loads the native module (the fake module of test/
;; when the native one does not load) and defines helpers that run
;; tools/mock-server.py as the server:
;;
;;   (ladybird-elate-start VARIANT ARG...)  start a mock server and open a page
;;   (ladybird-elate-ready-p)               non-nil once the page has a frame
;;   (ladybird-elate-log TYPE)              messages the mock server logged
;;   (ladybird-elate-log-has TYPE PRED)     whether one of them satisfies PRED
;;   (ladybird-elate-logged TYPE KEY VALUE...)  one with these field values
;;   (ladybird-elate-load URL)              load URL in the page buffer
;;   (ladybird-elate-kill-server), (ladybird-elate-serve VARIANT ARG...)
;;                                        take the server away, bring one back
;;   (ladybird-elate-intrude)               connect a second client
;;   (ladybird-elate-cleanup)               close pages, servers and files
;;
;; VARIANT is `stdio', `unix' or `tcp'.  LADYBIRD_ELATE_PYTHON names the
;; Python to run the mock server with.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst ladybird-elate-repo
  (expand-file-name "../../../"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The ladybird checkout.")

(add-to-list 'load-path (expand-file-name "lisp" ladybird-elate-repo))
(add-to-list 'load-path (expand-file-name "test" ladybird-elate-repo))

(setq load-prefer-newer t
      ring-bell-function 'ignore
      use-short-answers t)

(require 'ladybird)

;; The scenarios type into the page unless they turn command mode on.
(setq ladybird-initial-mode 'page)

(defconst ladybird-elate-native
  (and (fboundp 'ladybird-load-module)
       (let ((warning-minimum-log-level :emergency))
         (ignore-errors (ladybird-load-module)))
       (fboundp 'ladybird-module-feed))
  "Non-nil when the session runs with the native module.")

(unless ladybird-elate-native
  (require 'ladybird-fake-module))

(defvar ladybird-elate-python
  (or (getenv "LADYBIRD_ELATE_PYTHON")
      (seq-find #'file-executable-p
                '("/opt/homebrew/bin/python3" "/usr/local/bin/python3"
                  "/usr/bin/python3"))
      "python3")
  "The Python that runs the mock server.")

(defvar ladybird-elate-log
  (expand-file-name (format "ladybird-elate-%d.log" (emacs-pid))
                    temporary-file-directory)
  "Log file of the mock server.")

(defvar ladybird-elate-socket
  (format "/tmp/ladybird-elate-%d.sock" (emacs-pid))
  "Socket of the `unix' variant's mock server.")

(defvar ladybird-elate-port nil
  "Port of the `tcp' variant's mock server, chosen when it first starts.")

(defvar ladybird-elate-server nil
  "Process of the mock server of the `unix' and `tcp' variants.")

(defun ladybird-elate--command (&rest arguments)
  "Return the mock server's command line with ARGUMENTS."
  `(,ladybird-elate-python "-I"
    ,(expand-file-name "tools/mock-server.py" ladybird-elate-repo)
    "--log" ,ladybird-elate-log "--hostname" ,(system-name) ,@arguments))

(defun ladybird-elate--free-port ()
  "Return a TCP port nothing listens on."
  (let* ((server (make-network-process :name "ladybird-elate-port" :server t
                                       :host "127.0.0.1" :service t
                                       :family 'ipv4))
         (port (process-contact server :service)))
    (delete-process server)
    port))

(defun ladybird-elate-serve (variant &rest arguments)
  "Start the mock server for VARIANT with ARGUMENTS and return its endpoint.
A `stdio' server starts with the connection."
  (when (process-live-p ladybird-elate-server)
    (delete-process ladybird-elate-server))
  (pcase variant
    ('stdio (list :command (apply #'ladybird-elate--command arguments)))
    ((or 'unix 'tcp)
     (let ((listen (if (eq variant 'unix)
                       (list "--socket" ladybird-elate-socket)
                     (unless ladybird-elate-port
                       (setq ladybird-elate-port (ladybird-elate--free-port)))
                     (list "--tcp" (format "127.0.0.1:%d" ladybird-elate-port)))))
       ;; A killed server leaves its socket behind.
       (when (and (eq variant 'unix) (file-exists-p ladybird-elate-socket))
         (delete-file ladybird-elate-socket))
       (setq ladybird-elate-server
             (make-process :name "ladybird-elate-mock" :buffer nil :noquery t
                           :command (apply #'ladybird-elate--command
                                           (append listen arguments))))
       ;; The listener is up once its socket exists or takes a connection.
       (with-timeout (5 (error "The mock server did not start"))
         (while (not (if (eq variant 'unix)
                         (file-exists-p ladybird-elate-socket)
                       (ignore-errors
                         (delete-process
                          (make-network-process
                           :name "ladybird-elate-probe" :host "127.0.0.1"
                           :service ladybird-elate-port))
                         t)))
           (sleep-for 0.05)))
       (if (eq variant 'unix)
           ladybird-elate-socket
         (format "tcp://127.0.0.1:%d" ladybird-elate-port))))
    (_ (error "Unknown variant %S" variant))))

(defun ladybird-elate-start (&optional variant &rest arguments)
  "Start a mock server and open mock://start on it.
VARIANT is `stdio' (the default), `unix' or `tcp'; ARGUMENTS are further
options of the mock server.  Return the page buffer."
  (when (file-exists-p ladybird-elate-log)
    (delete-file ladybird-elate-log))
  (setq ladybird-hosts
        (list (cons "mock" (apply #'ladybird-elate-serve (or variant 'stdio)
                                  arguments)))
        ladybird-default-host "mock")
  (ladybird "mock://start"))

(defun ladybird-elate-buffer ()
  "Return the page buffer used last, or the first one."
  (or (and (buffer-live-p ladybird--last-buffer) ladybird--last-buffer)
      (car (ladybird--buffers))))

(defun ladybird-elate-ready-p ()
  "Return non-nil once the page buffer shows a frame."
  (when-let* ((buffer (ladybird-elate-buffer)))
    (with-current-buffer buffer
      (and ladybird--view ladybird--canvas (ladybird--ready-p ladybird--conn) t))))

(defun ladybird-elate-log (&optional type)
  "Return the messages in the mock server's log, oldest first.
With TYPE only those of that type."
  (when (file-exists-p ladybird-elate-log)
    (with-temp-buffer
      (insert-file-contents ladybird-elate-log)
      (let (messages)
        (while (not (eobp))
          (let ((message (ignore-errors
                           (ladybird--parse-json
                            (buffer-substring (point) (line-end-position))))))
            (when (and message
                       (or (null type) (equal (alist-get 'type message) type)))
              (push message messages)))
          (forward-line 1))
        (nreverse messages)))))

(defun ladybird-elate-log-has (type &optional predicate)
  "Return a logged message of TYPE that satisfies PREDICATE, or nil."
  (seq-find (or predicate #'identity) (ladybird-elate-log type)))

(defun ladybird-elate-logged (type &rest fields)
  "Return the last logged message of TYPE whose FIELDS have these values.
FIELDS is a property list of field symbols and values."
  (seq-find (lambda (message)
              (cl-loop for (key value) on fields by #'cddr
                       always (equal (alist-get key message) value)))
            (reverse (ladybird-elate-log type))))

(defun ladybird-elate-count (type &rest fields)
  "Return the number of logged messages of TYPE with these FIELDS."
  (seq-count (lambda (message)
               (cl-loop for (key value) on fields by #'cddr
                        always (equal (alist-get key message) value)))
             (ladybird-elate-log type)))

(defun ladybird-elate-keys ()
  "Return the names of the keys the mock server saw pressed, in order."
  (mapcar (lambda (message) (alist-get 'key message))
          (seq-filter (lambda (message) (equal (alist-get 'kind message) "down"))
                      (ladybird-elate-log "key"))))

(defmacro ladybird-elate-in-page (&rest body)
  "Run BODY in the page buffer."
  (declare (indent 0))
  `(with-current-buffer (ladybird-elate-buffer) ,@body))

(defun ladybird-elate-load (url)
  "Load URL in the page buffer."
  (ladybird-elate-in-page (ladybird-goto-url url)))

(defun ladybird-elate-state (field)
  "Return FIELD of the page's state."
  (ladybird-elate-in-page (alist-get field ladybird--state)))

(defun ladybird-elate-header ()
  "Return the page buffer's header line as plain text."
  (ladybird-elate-in-page (substring-no-properties (ladybird--header-line))))

(defun ladybird-elate-messages-p (regexp)
  "Return non-nil if a line of *Messages* matches REGEXP."
  (with-current-buffer (messages-buffer)
    (save-excursion
      (goto-char (point-min))
      (re-search-forward regexp nil t))))

(defun ladybird-elate-kill-server ()
  "Kill the mock server of the `unix' or `tcp' variant."
  (when (process-live-p ladybird-elate-server)
    (delete-process ladybird-elate-server)))

(defvar ladybird-elate-error nil "Scratch variable of the scenarios.")
(defvar ladybird-elate-binding nil "Scratch variable of the scenarios.")
(defvar ladybird-elate-canvas nil "Scratch variable of the scenarios.")
(defvar ladybird-elate-key-count nil "Scratch variable of the scenarios.")
(defvar ladybird-elate-viewports nil "Scratch variable of the scenarios.")

(defvar ladybird-elate-intruder nil
  "Connection of the second client.")

(defun ladybird-elate-intrude ()
  "Connect a second client to the mock server, which replaces the first."
  (let* ((endpoint (ladybird--parse-endpoint (cdar ladybird-hosts)))
         (process (pcase (plist-get endpoint :kind)
                    ('unix (make-network-process
                            :name "ladybird-elate-intruder" :family 'local
                            :service (plist-get endpoint :path)
                            :coding 'binary :noquery t))
                    ('tcp (make-network-process
                           :name "ladybird-elate-intruder"
                           :host (plist-get endpoint :host)
                           :service (plist-get endpoint :port)
                           :coding 'binary :noquery t))
                    (_ (error "The stdio server takes one client")))))
    (setq ladybird-elate-intruder process)
    (process-send-string
     process
     (ladybird--encode-record
      1 (json-serialize '((type . "hello") (protocol . 1) (client . "intruder")
                          (viewport . ((width . 80) (height . 24) (dpr . 1.0)))
                          (encodings . ["raw"]) (shm . :false)))))))

(defun ladybird-elate-cleanup ()
  "Close every page, the mock server and its files."
  (mapc #'kill-buffer (ladybird--buffers))
  (mapc #'ladybird--disconnect ladybird--conns)
  (when (process-live-p ladybird-elate-intruder)
    (delete-process ladybird-elate-intruder))
  (ladybird-elate-kill-server)
  (dolist (file (list ladybird-elate-log ladybird-elate-socket))
    (when (file-exists-p file)
      (delete-file file)))
  t)

(provide 'ladybird-setup)

;;; ladybird-setup.el ends here
