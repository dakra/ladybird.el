;;; ladybird-conn-test.el --- Tests for ladybird-conn -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests of the framing, the endpoints, the fake module and the
;; connection state machine.  The connection tests replace
;; `ladybird--open-process' by a pipe process and `ladybird--write' by a
;; recorder, and run timers by hand.  The tests tagged `mock' start
;; tools/mock-server.py.
;;
;; The tests use the fake module of test/ladybird-fake-module.el.  With
;; LADYBIRD_TEST_MODULE set in the environment the `mock' tests use the
;; native module instead, when it loads.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ladybird-conn)

(declare-function ladybird-load-module "ladybird-module-load")
(declare-function ladybird-module-attach-canvas "ext:ladybird-module")
(declare-function ladybird-module-repaint "ext:ladybird-module")
(declare-function ladybird-module-stats "ext:ladybird-module")
(declare-function ladybird-module-canvas-pixel "ext:ladybird-module")

(defconst ladybird-test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of the tests.")

(defvar ladybird-module-directory)
(defvar ladybird--update-timer)

(defconst ladybird-test-native
  (and (getenv "LADYBIRD_TEST_MODULE")
       (require 'ladybird-module-load nil t)
       (fboundp 'ladybird-load-module)
       (let ((ladybird-module-directory (or (getenv "LADYBIRD_MODULE_DIR")
                                          ladybird-module-directory)))
         (ignore-errors (ladybird-load-module)))
       (fboundp 'ladybird-module-feed))
  "Non-nil when the tests run with the native module.")

(unless ladybird-test-native
  (require 'ladybird-fake-module))

(defvar ladybird-fake-module-shm-size)
(defvar ladybird-fake-module-frames)


;;; Harness

(defvar ladybird-test-sent nil
  "The messages written to connections, newest first.")

(defvar ladybird-test-processes nil
  "The processes `ladybird-test-open' made.")

(defvar ladybird-test-open-error nil
  "Non-nil makes `ladybird-test-open' signal an error.")

(defvar ladybird-test-opened nil
  "The endpoints `ladybird-test-open' was asked for, newest first.")

(defconst ladybird-test-host '("test" (:kind unix :path "/nonexistent/ladybird"))
  "A host for connection tests.")

(defun ladybird-test-open (endpoint)
  "Return a pipe process standing in for a connection to ENDPOINT."
  (push endpoint ladybird-test-opened)
  (when ladybird-test-open-error
    (error "Cannot connect"))
  (let ((process (make-pipe-process :name "ladybird-test" :buffer nil
                                    :noquery t)))
    (push process ladybird-test-processes)
    process))

(defun ladybird-test-decode (bytes)
  "Return the message of the control record BYTES."
  (should (= (ladybird-fake-u32 bytes 0) (- (length bytes) 4)))
  (should (= (aref bytes 4) 1))
  (ladybird--parse-json (decode-coding-string (substring bytes 5) 'utf-8)))

(defun ladybird-fake-u32 (string position)
  "Return the little-endian u32 of STRING at POSITION."
  (logior (aref string position)
          (ash (aref string (+ position 1)) 8)
          (ash (aref string (+ position 2)) 16)
          (ash (aref string (+ position 3)) 24)))

(defconst ladybird-test-runtime-directory "/nonexistent/ladybird-runtime"
  "XDG_RUNTIME_DIR of the tests, where no server listens.")

(defmacro ladybird-test-with-env (&rest body)
  "Run BODY with connections isolated from Emacs and from each other."
  (declare (indent 0) (debug t))
  `(let ((ladybird--conns nil)
         (process-environment
          (cons (concat "XDG_RUNTIME_DIR=" ladybird-test-runtime-directory)
                process-environment))
         (ladybird-test-sent nil)
         (ladybird-test-processes nil)
         (ladybird-test-open-error nil)
         (ladybird-test-opened nil)
         (ladybird--keepalive-timer nil)
         (ladybird--update-timer nil)
         (ladybird-reconnect t)
         (ladybird-fake-module-shm-size nil)
         (ladybird--no-shm-endpoints nil)
         (ladybird--handlers (copy-hash-table ladybird--handlers))
         (ladybird--frame-function #'ignore)
         (ladybird--welcome-function #'ignore)
         (ladybird--change-function #'ignore)
         (inhibit-message t))
     (cl-letf (((symbol-function 'ladybird--open-process) #'ladybird-test-open)
               ((symbol-function 'ladybird--write)
                (lambda (_conn bytes)
                  (push (ladybird-test-decode bytes) ladybird-test-sent))))
       (unwind-protect
           (progn ,@body)
         (dolist (conn ladybird--conns)
           (ladybird--disconnect conn))
         (when ladybird--keepalive-timer
           (cancel-timer ladybird--keepalive-timer))
         ;; Page buffers killed by BODY schedule an update.
         (when (timerp ladybird--update-timer)
           (cancel-timer ladybird--update-timer))
         (dolist (process ladybird-test-processes)
           (when (process-live-p process)
             (delete-process process)))))))

(defun ladybird-test-record (object)
  "Return the control record of the alist OBJECT."
  (ladybird--encode-record
   1 (encode-coding-string (json-serialize object) 'utf-8 t)))

(defun ladybird-test-pixel (x y seed fw fh)
  "Return the ARGB value of pixel X, Y of the FW x FH frame with SEED."
  (logior #xff000000
          (ash (/ (* x 255) (max (1- fw) 1)) 16)
          (ash (/ (* y 255) (max (1- fh) 1)) 8)
          (logand (+ (* seed 37) (logxor x y)) #xff)))

(defun ladybird-test-frame (seq view fw fh &optional rect seed full dpr)
  "Return a raw frame record SEQ of VIEW for an FW x FH frame.
RECT is the damage (X Y W H), by default the whole frame; the pixels
follow the formula with SEED.  FULL sets the full flag.  DPR is 1.0 or
2.0."
  (pcase-let ((`(,x ,y ,w ,h) (or rect (list 0 0 fw fh)))
              (pixels nil))
    (dotimes (row h)
      (dotimes (column w)
        (push (ladybird--u32le (ladybird-test-pixel (+ x column) (+ y row)
                                                (or seed 0) fw fh))
              pixels)))
    (ladybird--encode-record
     2 (concat (ladybird--u32le seq) (ladybird--u32le view)
               (ladybird--u32le fw) (ladybird--u32le fh)
               (if (eql dpr 2.0)
                   (unibyte-string 0 0 0 0 0 0 0 #x40)
                 (unibyte-string 0 0 0 0 0 0 #xf0 #x3f))
               (ladybird--u32le x) (ladybird--u32le y)
               (ladybird--u32le w) (ladybird--u32le h)
               (unibyte-string 0 (if full 1 0) 0 0)
               (apply #'concat (nreverse pixels))))))

(defun ladybird-test-receive (conn &rest records)
  "Feed RECORDS to CONN as one read; an alist is made a control record."
  (ladybird--filter (ladybird--conn-process conn)
                  (mapconcat (lambda (record)
                               (if (stringp record)
                                   record
                                 (ladybird-test-record record)))
                             records "")))

(defun ladybird-test-sent (&optional type)
  "Return the messages sent, oldest first, or only those of TYPE."
  (let ((sent (reverse ladybird-test-sent)))
    (if type
        (seq-filter (lambda (m) (equal (alist-get 'type m) type)) sent)
      sent)))

(defun ladybird-test-welcome (&optional views shm)
  "Return a welcome message with VIEWS; SHM is its shm field.
The server holds up to 16 views."
  `((type . "welcome") (protocol . 1) (server . "test") (encoding . "raw")
    (shm . ,(ladybird--bool shm)) (log . "/dev/null") (max_views . 16)
    (host . ((hostname . ,(system-name)) (platform . "test")))
    (views . ,(vconcat views))))

(defun ladybird-test-connect (&optional host)
  "Return a ready connection to HOST or `ladybird-test-host'."
  (let ((conn (ladybird--connect (or host ladybird-test-host) #'ignore)))
    (ladybird-test-receive conn (ladybird-test-welcome))
    (should (ladybird--ready-p conn))
    (setq ladybird-test-sent nil)
    conn))

(defun ladybird-test-register (conn view &optional buffer)
  "Make VIEW a view of CONN shown by BUFFER, by default the current one."
  (puthash view (or buffer (current-buffer)) (ladybird--conn-views conn))
  (ladybird-module-register-view (ladybird--conn-decoder conn) view))

(defun ladybird-test-close-timer ()
  "Return the timer that closes a dropped prompt, or nil."
  (seq-find (lambda (timer)
              (eq (timer--function timer) #'ladybird--close-dropped))
            timer-list))

(defun ladybird-test-run-timer (timer)
  "Run TIMER now, as if its time had come."
  (should (timerp timer))
  (timer-event-handler timer))

(defun ladybird-test-drain (session bytes)
  "Feed BYTES to SESSION and return the events of every complete record."
  (let ((events (ladybird-module-feed session bytes))
        more)
    (while (setq more (ladybird-module-feed session ""))
      (setq events (nconc events more)))
    events))

(defun ladybird-test-file (name)
  "Return the contents of the fixture file NAME as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally
     (expand-file-name (concat "fixtures/" name) ladybird-test-directory))
    (buffer-string)))


;;; A1: framing, endpoints, hosts

(ert-deftest ladybird-conn-test-record ()
  (should (equal (ladybird--u32le #x12345678) (unibyte-string #x78 #x56 #x34 #x12)))
  (let ((record (ladybird--encode-record 1 "{\"type\":\"ping\",\"id\":1}")))
    (should (equal record
                   (concat (unibyte-string #x17 0 0 0 1)
                           "{\"type\":\"ping\",\"id\":1}")))
    (should-not (multibyte-string-p record)))
  (should (equal (ladybird--encode-record 2 "") (unibyte-string 1 0 0 0 2)))
  (let* ((message '((type . "text") (view . 1) (text . "héllo ✓")))
         (record (ladybird-test-record message)))
    (should (equal (ladybird-test-decode record) message))))

(ert-deftest ladybird-conn-test-parse-endpoint ()
  (should (equal (ladybird--parse-endpoint "local") '(:kind local)))
  (should (equal (ladybird--parse-endpoint nil) '(:kind local)))
  (should (equal (ladybird--parse-endpoint "ssh:devbox") '(:kind ssh :host "devbox")))
  (should (equal (ladybird--parse-endpoint "ssh://me@devbox")
                 '(:kind ssh :host "me@devbox")))
  (should (equal (ladybird--parse-endpoint "ssh://me@devbox:2222")
                 '(:kind ssh :host "me@devbox" :port 2222)))
  (should (equal (ladybird--parse-endpoint '(:ssh "devbox" :program "/opt/Ladybird"
                                                :args ("--x")))
                 '(:kind ssh :host "devbox" :program "/opt/Ladybird"
                         :args ("--x"))))
  (should (equal (ladybird--parse-endpoint "/tmp/ladybird.sock")
                 '(:kind unix :path "/tmp/ladybird.sock")))
  (should (equal (ladybird--parse-endpoint "/ssh:devbox:/run/user/1000/lb.sock")
                 '(:kind ssh :host "devbox" :path "/run/user/1000/lb.sock")))
  (should (equal (ladybird--parse-endpoint "/ssh:me@devbox#2222:/a b:c")
                 '(:kind ssh :host "me@devbox" :port 2222 :path "/a b:c")))
  (should (equal (ladybird--parse-endpoint "unix:///a%20b")
                 '(:kind unix :path "/a b")))
  (should (equal (ladybird--parse-endpoint "tcp://devbox:9000")
                 '(:kind tcp :host "devbox" :port 9000)))
  (should (equal (ladybird--parse-endpoint "tls://[::1]:9000")
                 '(:kind tls :host "::1" :port 9000)))
  (should (equal (ladybird--parse-endpoint '(:command ("python3" "mock.py")))
                 '(:kind local :command ("python3" "mock.py"))))
  (should (equal (ladybird--parse-endpoint '(:kind unix :path "/s" :shm nil))
                 '(:kind unix :path "/s" :shm nil)))
  (dolist (bad '("" "devbox" "relative/path" "tcp://devbox" "tcp://:9000"
                 "tls://devbox:port" "http://devbox:80" "unix://relative"
                 "ssh:" "ssh://" "/ssh:devbox" "/ssh:devbox:" "/ssh::/s"
                 "/ssh:devbox:relative" "/ssh:devbox#x:/s" "/ssh:-oX=y:/s"
                 "/ssh:a|sudo:b:/s" "/ssh:a b:/s" "/ssh:a\n:/s" "/ssh:[::1]:/s"
                 (:kind ssh :host "h" :path 42) (:kind ssh :host "h" :path "rel")
                 (:ssh "h" :path "") (:kind tcp :host "x") (:kind bogus)
                 (:ssh) (:command "python3") 42))
    (should-not (ladybird--parse-endpoint bad))))

(ert-deftest ladybird-conn-test-hosts ()
  (ladybird-test-with-env
    (let ((ladybird-hosts '(("one" . "ssh:one")
                          ("two" "/tmp/two.sock" "tcp://two:9000")
                          ("three" :ssh "three" :program "lb")
                          ("four" (:kind unix :path "/tmp/four" :shm nil)
                           "bogus")
                          ("none" . "bogus")))
          (ladybird-program "ladybird-no-such-program"))
      (should (equal (ladybird--hosts)
                     '(("one" (:kind ssh :host "one"))
                       ("two" (:kind unix :path "/tmp/two.sock")
                        (:kind tcp :host "two" :port 9000))
                       ("three" (:kind ssh :host "three" :program "lb"))
                       ("four" (:kind unix :path "/tmp/four" :shm nil)))))
      (let ((ladybird-program "sh"))
        (should (equal (car (ladybird--hosts)) '(nil (:kind local))))
        (should (equal (car (ladybird--hosts t)) '("one" (:kind ssh :host "one"))))))))

(defun ladybird-test-default-socket (runtime temporary)
  "Return the default socket with RUNTIME and TEMPORARY in the environment.
They are the values of XDG_RUNTIME_DIR and TMPDIR, nil for unset."
  (let ((process-environment
         (append (list (if runtime (concat "XDG_RUNTIME_DIR=" runtime) "XDG_RUNTIME_DIR")
                       (if temporary (concat "TMPDIR=" temporary) "TMPDIR"))
                 process-environment)))
    (ladybird-default-socket)))

(ert-deftest ladybird-conn-test-default-socket ()
  (let ((name (format "ladybird-emacs-%d/ladybird-emacs.sock" (user-real-uid))))
    (should (equal (ladybird-test-default-socket "/run/user/1000" "/var/tmp")
                   "/run/user/1000/ladybird-emacs.sock"))
    (should (equal (ladybird-test-default-socket "/run/user/1000/" nil)
                   "/run/user/1000/ladybird-emacs.sock"))
    (should (equal (ladybird-test-default-socket "/run/user/1000//" nil)
                   "/run/user/1000/ladybird-emacs.sock"))
    (should (equal (ladybird-test-default-socket "/" nil) "/ladybird-emacs.sock"))
    (should (equal (ladybird-test-default-socket "" "/var/tmp")
                   (concat "/var/tmp/" name)))
    (should (equal (ladybird-test-default-socket nil "/var/tmp/")
                   (concat "/var/tmp/" name)))
    (should (equal (ladybird-test-default-socket nil "")
                   (concat "/tmp/" name)))
    (should (equal (ladybird-test-default-socket "" nil)
                   (concat "/tmp/" name)))
    ;; A relative directory counts as unset.
    (should (equal (ladybird-test-default-socket "run/user" "/var/tmp")
                   (concat "/var/tmp/" name)))
    (should (equal (ladybird-test-default-socket nil "tmp")
                   (concat "/tmp/" name)))
    (should (equal (ladybird-test-default-socket nil "~/tmp")
                   (concat "/tmp/" name)))))

(defmacro ladybird-test-with-runtime (&rest body)
  "Run BODY with XDG_RUNTIME_DIR naming a new directory.
`socket' is the endpoint of the default socket there and `listen' a
function that makes a server listen on it."
  (declare (indent 0) (debug t))
  `(let* ((runtime (make-temp-file "ladybird-runtime" t))
          (process-environment (cons (concat "XDG_RUNTIME_DIR=" runtime)
                                     process-environment))
          (socket (list :kind 'unix :path (ladybird-default-socket)))
          (listen (lambda ()
                    (make-network-process
                     :name "ladybird-test-listener" :server t :family 'local
                     :service (plist-get socket :path) :noquery t))))
     (ignore listen)
     (unwind-protect
         (progn ,@body)
       (dolist (process (process-list))
         (when (string-prefix-p "ladybird-test-listener" (process-name process))
           (delete-process process)))
       (delete-directory runtime t))))

(ert-deftest ladybird-conn-test-hosts-default-socket ()
  ;; The local server is the one on the default socket when something
  ;; of this user accepts connections there, else the program over stdio.
  (ladybird-test-with-env
    (ladybird-test-with-runtime
      (let ((ladybird-hosts '(("one" . "ssh:one")))
            (ladybird-program "ladybird-no-such-program"))
        (should (equal (ladybird--hosts) '(("one" (:kind ssh :host "one")))))
        (let ((ladybird-program "sh"))
          (should (equal (car (ladybird--hosts)) '(nil (:kind local)))))
        (let ((listener (funcall listen)))
          (should (equal (ladybird--hosts)
                         `((nil ,socket) ("one" (:kind ssh :host "one")))))
          (let ((ladybird-program "sh"))
            (should (equal (car (ladybird--hosts)) (list nil socket))))
          (should (ladybird--shm-p socket))
          ;; A socket of another user is not the local server.
          (let ((uid (user-real-uid)))
            (cl-letf (((symbol-function 'user-real-uid) (lambda () (1+ uid))))
              (should (equal (ladybird--hosts) '(("one" (:kind ssh :host "one")))))))
          ;; Nor is a socket file that nothing listens on.
          (delete-process listener))
        (should (file-exists-p (plist-get socket :path)))
        (should (equal (ladybird--hosts) '(("one" (:kind ssh :host "one")))))
        (let ((ladybird-program "sh"))
          (should (equal (car (ladybird--hosts)) '(nil (:kind local)))))))))

(defun ladybird-test-file-attributes (file n value)
  "Return a `file-attributes' that gives FILE VALUE as its attribute N."
  (let ((file-attributes (symbol-function 'file-attributes)))
    (lambda (name &optional id-format)
      (let ((attributes (funcall file-attributes name id-format)))
        (if (equal name file)
            (append (take n attributes) (list value) (nthcdr (1+ n) attributes))
          attributes)))))

(defun ladybird-test-owned-by-other (file)
  "Return a `file-attributes' that makes FILE owned by another user."
  (ladybird-test-file-attributes file 2 (1+ (user-real-uid))))

(ert-deftest ladybird-conn-test-hosts-private-directory ()
  ;; Outside XDG_RUNTIME_DIR the default socket counts only in a
  ;; directory that this user owns and nobody else may enter, in a
  ;; directory where nobody else can rename it.  TMPDIR is in /tmp, as
  ;; the socket path under a long TMPDIR such as that of macOS would not
  ;; fit a Unix socket address.
  (ladybird-test-with-env
    (let* ((temporary (make-temp-file "/tmp/ladybird-test" t))
           (process-environment (append (list "XDG_RUNTIME_DIR=run"
                                              (concat "TMPDIR=" temporary))
                                        process-environment))
           (path (ladybird-default-socket))
           (directory (directory-file-name (file-name-directory path)))
           (moved (concat temporary "/moved"))
           (socket (list :kind 'unix :path path))
           (ladybird-hosts nil)
           (ladybird-program "ladybird-no-such-program"))
      (unwind-protect
          (progn
            (should (equal directory (format "%s/ladybird-emacs-%d"
                                             temporary (user-real-uid))))
            (make-directory directory)
            (set-file-modes directory #o700)
            ;; The listener accepts no connection, so few probes reach it.
            (make-network-process :name "ladybird-test-listener" :server t
                                  :family 'local :service path :noquery t)
            (should (equal (ladybird--hosts) `((nil ,socket))))
            (set-file-modes directory #o750)
            (should-not (ladybird--hosts))
            (dolist (modes '(#o750 #o720 #o710 #o740 #o701 #o702 #o704))
              (set-file-modes directory modes)
              (should-not (ladybird--private-directory-p directory)))
            (set-file-modes directory #o700)
            (should (ladybird--private-directory-p directory))
            (cl-letf (((symbol-function 'file-attributes)
                       (ladybird-test-owned-by-other directory)))
              (should-not (ladybird--private-directory-p directory)))
            ;; The parent may be written to by its group or others only
            ;; when sticky.
            (dolist (modes '(#o777 #o770 #o730 #o703))
              (set-file-modes temporary modes)
              (should-not (ladybird--private-directory-p directory)))
            (dolist (modes '(#o1777 #o755 #o700))
              (set-file-modes temporary modes)
              (should (ladybird--private-directory-p directory)))
            (let ((parent (file-truename (file-name-as-directory temporary))))
              (cl-letf (((symbol-function 'file-attributes)
                         (ladybird-test-owned-by-other parent)))
                (should-not (ladybird--private-directory-p directory)))
              ;; A parent of root, such as /tmp, is fine.
              (cl-letf (((symbol-function 'file-attributes)
                         (ladybird-test-file-attributes parent 2 0)))
                (should (ladybird--private-directory-p directory))))
            ;; S and T are the setgid and sticky bits without x, s and t
            ;; with it.
            (dolist (modes '("drwx--S---" "drwx-----T" "drwx--S--T"))
              (cl-letf (((symbol-function 'file-attributes)
                         (ladybird-test-file-attributes directory 8 modes)))
                (should (ladybird--private-directory-p directory))))
            (dolist (modes '("drwx--s---" "drwx-----t" "lrwx------" "-rwx------"))
              (cl-letf (((symbol-function 'file-attributes)
                         (ladybird-test-file-attributes directory 8 modes)))
                (should-not (ladybird--private-directory-p directory))))
            ;; A link to a private directory is not one.
            (rename-file directory moved)
            (make-symbolic-link moved directory)
            (should (file-exists-p path))
            (should-not (ladybird--private-directory-p directory))
            (should-not (ladybird--hosts))
            (delete-file directory)
            ;; Nor is a file.
            (write-region "" nil directory nil 'silent)
            (set-file-modes directory #o600)
            (should-not (ladybird--private-directory-p directory)))
        (dolist (process (process-list))
          (when (string-prefix-p "ladybird-test-listener" (process-name process))
            (delete-process process)))
        (set-file-modes temporary #o700)
        (delete-directory temporary t)))))

(ert-deftest ladybird-conn-test-hosts-local-conn ()
  ;; A connection to the local server keeps it, also while it is
  ;; dialled again, and whichever server it found.
  (ladybird-test-with-env
    (ladybird-test-with-runtime
      (let ((ladybird-program "sh"))
        (funcall listen)
        (let ((conn (ladybird--connect (car (ladybird--hosts)) #'ignore)))
          (should (equal (ladybird--conn-endpoints conn) (list socket)))
          (puthash 1 (current-buffer) (ladybird--conn-views conn))
          (ladybird--drop conn)
          (should (eq (ladybird--conn-state conn) 'redialing))
          (dolist (process (process-list))
            (when (string-prefix-p "ladybird-test-listener" (process-name process))
              (delete-process process)))
          (should (equal (car (ladybird--hosts)) (list nil socket)))
          (should (eq (ladybird--find-conn (car (ladybird--hosts))) conn))
          (ladybird--disconnect conn))
        ;; A server over stdio stays the local one until a socket server
        ;; appears; then new pages go to that, and a connection to it
        ;; comes before the one over stdio.
        (delete-file (plist-get socket :path))
        (let ((conn (ladybird--connect (car (ladybird--hosts)) #'ignore)))
          (should (equal (ladybird--conn-endpoints conn) '((:kind local))))
          (should (equal (car (ladybird--hosts)) '(nil (:kind local))))
          (should (eq (ladybird--find-conn (car (ladybird--hosts))) conn))
          (should (= (length ladybird--conns) 1))
          (let ((listener (funcall listen)))
            (should (equal (car (ladybird--hosts)) (list nil socket)))
            (let ((other (ladybird--connect (car (ladybird--hosts)) #'ignore)))
              (should-not (eq other conn))
              (should (eq (ladybird--local-conn) other))
              (delete-process listener)
              (should (equal (car (ladybird--hosts)) (list nil socket)))
              (ladybird--disconnect other)))
          (should (equal (car (ladybird--hosts)) '(nil (:kind local))))
          (ladybird--disconnect conn)
          (should (equal (car (ladybird--hosts)) '(nil (:kind local)))))
        ;; The connection to the socket comes first also when the one
        ;; over stdio is newer.
        (delete-file (plist-get socket :path))
        (let* ((listener (funcall listen))
               (other (ladybird--connect (car (ladybird--hosts)) #'ignore))
               (conn (ladybird--connect '(nil (:kind local)) #'ignore)))
          (should (eq (car ladybird--conns) conn))
          (should (eq (ladybird--local-conn) other))
          (should (equal (car (ladybird--hosts)) (list nil socket)))
          (delete-process listener)
          (ladybird--disconnect other)
          (should (eq (ladybird--local-conn) conn))
          (ladybird--disconnect conn))))))

(ert-deftest ladybird-conn-test-hosts-configured-default-socket ()
  ;; A host of `ladybird-hosts' connected to the default socket is the
  ;; local server; one that reached another of its endpoints is not.
  (ladybird-test-with-env
    (ladybird-test-with-runtime
      (let* ((path (plist-get socket :path))
             (ladybird-program "sh")
             (ladybird-hosts `(("p" ,path "local")
                               ("q" (:kind unix :path ,path :shm nil)))))
        (let ((conn (cl-letf (((symbol-function 'ladybird--open-process)
                               (lambda (endpoint)
                                 (if (eq (plist-get endpoint :kind) 'unix)
                                     (error "Cannot connect")
                                   (ladybird-test-open endpoint)))))
                      (ladybird--connect (assoc "p" (ladybird--hosts t)) #'ignore))))
          (should (equal (ladybird--conn-dialed conn) '(:kind local)))
          (should (equal (car (ladybird--hosts)) '(nil (:kind local))))
          (should-not (eq (ladybird--find-conn (car (ladybird--hosts))) conn))
          (ladybird--disconnect conn))
        (dolist (label '("p" "q"))
          (let ((conn (ladybird--connect (assoc label (ladybird--hosts t)) #'ignore)))
            (should (equal (plist-get (ladybird--conn-dialed conn) :path) path))
            (should (eq (ladybird--find-conn (car (ladybird--hosts))) conn))
            (ladybird--disconnect conn)))))))

(ert-deftest ladybird-conn-test-shm-p ()
  (should (ladybird--shm-p '(:kind local)))
  (should (ladybird--shm-p '(:kind unix :path "/s")))
  (should-not (ladybird--shm-p '(:kind unix :path "/s" :shm nil)))
  (should-not (ladybird--shm-p '(:kind ssh :host "h")))
  (should-not (ladybird--shm-p '(:kind ssh :host "h" :path "/s")))
  (should-not (ladybird--shm-p '(:kind tcp :host "h" :port 1)))
  (should-not (ladybird--shm-p '(:kind tls :host "h" :port 1))))

(ert-deftest ladybird-conn-test-server-command ()
  (let ((ladybird-program "sh")
        (ladybird-program-arguments '("--a b"))
        (ladybird-ssh-program "ssh"))
    (should (equal (cdr (ladybird--server-command '(:kind local)))
                   '("--headless=emacs" "--a b")))
    (should (equal (ladybird--server-command '(:kind local :command ("x" "y")))
                   '("x" "y")))
    (should (equal (ladybird--server-command
                    '(:kind ssh :host "me@box" :port 22 :path "/a b"))
                   '("ssh" "-T" "-p" "22" "-W" "/a b" "me@box")))
    (should (equal (ladybird--server-command
                    '(:kind ssh :host "box" :path "/a:b\\c"))
                   '("ssh" "-T" "-W" "/a\\:b\\\\c" "box")))
    (should (equal (ladybird--server-command '(:kind ssh :host "me@box" :port 22))
                   '("ssh" "-T" "-p" "22" "me@box" "exec" "sh"
                     "--headless\\=emacs" "--a\\ b")))
    (should (equal (ladybird--server-command
                    '(:kind ssh :host "box" :program "/opt/lb" :args ("-v")))
                   '("ssh" "-T" "box" "exec" "/opt/lb" "--headless\\=emacs"
                     "-v")))))


;;; A3: fake module

(defun ladybird-test-canvas (width height)
  "Return a canvas image spec of WIDTH x HEIGHT."
  (list 'image :type 'canvas :id (gensym "ladybird-test-")
        :data-width width :data-height height))

(ert-deftest ladybird-conn-test-fake-split-control ()
  (skip-unless (not ladybird-test-native))
  (let* ((session (ladybird-module-create-session))
         (record (ladybird-test-record '((type . "state") (title . "héllo"))))
         (cut1 3) (cut2 9))
    (should-not (ladybird-module-feed session (substring record 0 cut1)))
    (should-not (ladybird-module-feed session (substring record cut1 cut2)))
    (let ((events (ladybird-module-feed session (substring record cut2))))
      (should (equal (length events) 1))
      (should (multibyte-string-p (car events)))
      (should (equal (ladybird--parse-json (car events))
                     '((type . "state") (title . "héllo")))))
    (should (= (plist-get (ladybird-module-stats session) :buffered) 0))))

(ert-deftest ladybird-conn-test-fake-order ()
  (skip-unless (not ladybird-test-native))
  (let* ((session (ladybird-module-create-session))
         (events (progn
                   (ladybird-module-register-view session 7)
                   (ladybird-module-feed
                    session (concat (ladybird-test-frame 1 7 4 3 nil 1 t)
                                    (ladybird-test-record '((type . "pong"))))))))
    (should (equal (car events) '(frame 7 1 4 3 1.0 0 0 4 3 t stored)))
    (should (equal (ladybird--parse-json (cadr events)) '((type . "pong"))))
    (should (= (length events) 2))))

(ert-deftest ladybird-conn-test-fake-canvas ()
  (skip-unless (not ladybird-test-native))
  (let ((session (ladybird-module-create-session))
        (small (ladybird-test-canvas 4 3))
        (large (ladybird-test-canvas 6 5))
        (status (lambda (events) (car (last (car events))))))
    (should (eq (ladybird-module-repaint session 1) 'no-canvas))
    (ladybird-module-attach-canvas session 1 small)
    (should (eq (ladybird-module-repaint session 1) 'no-frame))
    (should (eq (funcall status (ladybird-module-feed
                                 session (ladybird-test-frame 1 1 4 3 nil 1 t)))
                'painted))
    (should (= (ladybird-module-canvas-pixel small 3 2)
               (ladybird-test-pixel 3 2 1 4 3)))
    (should (eq (funcall status (ladybird-module-feed
                                 session (ladybird-test-frame 2 1 6 5 nil 2 t)))
                'size-mismatch))
    (should (equal (ladybird-module-view-size session 1) '(6 . 5)))
    (should (eq (ladybird-module-repaint session 1) 'size-mismatch))
    (ladybird-module-attach-canvas session 1 large)
    (should (eq (ladybird-module-repaint session 1) 'painted))
    (should (= (ladybird-module-canvas-pixel large 5 4)
               (ladybird-test-pixel 5 4 2 6 5)))
    ;; A damage rectangle of another frame size is stale.
    (should (eq (funcall status (ladybird-module-feed
                                 session
                                 (ladybird-test-frame 3 1 4 3 '(0 0 1 1) 3)))
                'stale))
    (should (eq (funcall status (ladybird-module-feed
                                 session
                                 (ladybird-test-frame 4 1 6 5 '(1 1 2 2) 4)))
                'painted))
    (should (= (ladybird-module-canvas-pixel large 2 2)
               (ladybird-test-pixel 2 2 4 6 5)))
    (should (= (ladybird-module-canvas-pixel large 3 3)
               (ladybird-test-pixel 3 3 2 6 5)))
    (ladybird-module-close session)
    (should-error (ladybird-module-feed session "") :type 'ladybird-module-error)))

(ert-deftest ladybird-conn-test-fake-stops-after-control ()
  (skip-unless (not ladybird-test-native))
  (let ((session (ladybird-module-create-session))
        (one (ladybird-test-record '((n . 1))))
        (two (ladybird-test-record '((n . 2))))
        (frame (ladybird-test-frame 1 1 4 3 nil 1 t)))
    (ladybird-module-register-view session 1)
    (should (equal (ladybird-module-feed session (concat frame one two frame
                                                       (substring frame 0 9)))
                   '((frame 1 1 4 3 1.0 0 0 4 3 t stored) "{\"n\":1}")))
    (should (equal (ladybird-module-feed session "") '("{\"n\":2}")))
    (should (equal (ladybird-module-feed session "")
                   '((frame 1 1 4 3 1.0 0 0 4 3 t stored))))
    (should-not (ladybird-module-feed session ""))
    ;; A control record at the end of the input does not stop the feed.
    (should (equal (ladybird-module-feed session (concat (substring frame 9) one))
                   '((frame 1 1 4 3 1.0 0 0 4 3 t stored) "{\"n\":1}")))
    (should-not (ladybird-module-feed session ""))))

(ert-deftest ladybird-conn-test-fake-desync ()
  (skip-unless (not ladybird-test-native))
  (let* ((session (ladybird-module-create-session))
         (good (ladybird-test-record '((type . "ping"))))
         (events (ladybird-test-drain
                  session (concat good (unibyte-string 4 0 0 0 9) "abc"))))
    (should (equal (cadr events) `(desync bad-kind ,(length good))))
    (should-not (ladybird-module-feed session good))
    (ladybird-module-reset session)
    (should (= (length (ladybird-module-feed session good)) 1))
    (should-error (ladybird-module-feed session "é")
                  :type 'ladybird-module-error)))

(defun ladybird-test-fixture (name &optional chunk-size)
  "Feed fixture NAME to a fake session in chunks of CHUNK-SIZE bytes.
Check the events against the fixture's description and return the
session.  A canvas of the first frame's size is attached to view 1."
  (let* ((data (ladybird-test-file (concat name ".ladybird")))
         (spec (ladybird--parse-json
                (decode-coding-string (ladybird-test-file (concat name ".json"))
                                      'utf-8)))
         (records (append (alist-get 'records spec) nil))
         (first (seq-find (lambda (r) (alist-get 'frame_width r)) records))
         (session (ladybird-module-create-session))
         (size (or chunk-size (length data)))
         (position 0)
         events)
    (when first
      (ladybird-module-attach-canvas
       session 1 (ladybird-test-canvas (alist-get 'frame_width first)
                                     (alist-get 'frame_height first))))
    (while (< position (length data))
      (setq events (nconc events
                          (ladybird-test-drain
                           session (substring data position
                                              (min (length data)
                                                   (+ position size)))))
            position (+ position size)))
    (when-let* ((desync (alist-get 'desync spec)))
      (should (equal (car (last events))
                     (list 'desync (intern (alist-get 'reason desync))
                           (alist-get 'offset desync))))
      (setq events (butlast events)))
    (should (= (length events) (length records)))
    (cl-mapc (lambda (event record)
               (if (equal (alist-get 'kind record) "control")
                   (should (stringp event))
                 (should (eq (car event) 'frame))
                 (should (equal (symbol-name (car (last event)))
                                (alist-get 'status record)))
                 (should (equal (nth 2 event) (alist-get 'seq record)))))
             events records)
    session))

(defun ladybird-test-fixture-pixels (name session)
  "Check the store of view 1 in SESSION against fixture NAME's formula."
  (let* ((spec (ladybird--parse-json
                (decode-coding-string (ladybird-test-file (concat name ".json"))
                                      'utf-8)))
         (final (alist-get 'final spec))
         (fw (alist-get 'frame_width final))
         (fh (alist-get 'frame_height final))
         (canvas (ladybird-test-canvas fw fh))
         (applied (seq-filter
                   (lambda (r)
                     (member (alist-get 'status r)
                             '("painted" "stored" "size-mismatch")))
                   (alist-get 'records spec))))
    (should (equal (ladybird-module-view-size session 1) (cons fw fh)))
    (ladybird-module-attach-canvas session 1 canvas)
    (should (eq (ladybird-module-repaint session 1) 'painted))
    (dolist (point (list (cons 0 0) (cons (1- fw) (1- fh)) (cons (/ fw 2) (/ fh 2))
                         (cons 45 55) (cons 61 71) (cons 0 15) (cons (1- fw) 3)
                         (cons 5 (- fh 5))))
      (let* ((x (car point)) (y (cdr point))
             (last (car (last (seq-filter
                               (lambda (r)
                                 (and (<= (alist-get 'x r) x)
                                      (< x (+ (alist-get 'x r)
                                              (alist-get 'width r)))
                                      (<= (alist-get 'y r) y)
                                      (< y (+ (alist-get 'y r)
                                              (alist-get 'height r)))))
                               applied)))))
        (when (and (< x fw) (< y fh))
          (should (= (ladybird-module-canvas-pixel canvas x y)
                     (ladybird-test-pixel x y (alist-get 'seed last) fw fh))))))))

(ert-deftest ladybird-conn-test-fake-fixtures ()
  (skip-unless (not ladybird-test-native))
  (dolist (size '(nil 1 7 4096))
    (ladybird-test-fixture-pixels
     "basic-raw-full" (ladybird-test-fixture "basic-raw-full" size)))
  (dolist (size '(nil 65536))
    (ladybird-test-fixture-pixels "resize" (ladybird-test-fixture "resize" size)))
  (dolist (size '(nil 3))
    (let ((stats (ladybird-module-stats (ladybird-test-fixture "bad" size))))
      (should (eq (plist-get stats :state) 'desynced))
      (should (= (plist-get stats :frames-dropped) 9))))
  (ladybird-test-fixture "control-utf8" 65536)
  (let ((ladybird-fake-module-shm-size (+ 4096 (* 64 48 4)))
        (data (ladybird-test-file "shm.ladybird"))
        (session (ladybird-module-create-session)))
    (ladybird-module-attach-canvas session 1 (ladybird-test-canvas 64 48))
    (ladybird-module-set-shm session 1 "/ladybird-fixture")
    (should (eq (car (last (cadr (ladybird-test-drain session data)))) 'painted))))

(ert-deftest ladybird-conn-test-fake-fixtures-zstd ()
  (skip-unless (and (not ladybird-test-native) (executable-find "zstd")))
  (ladybird-test-fixture-pixels "damage-mix" (ladybird-test-fixture "damage-mix"))
  (ladybird-test-fixture-pixels "zstd" (ladybird-test-fixture "zstd" 65536)))


;;; B1: connection state machine

(ert-deftest ladybird-conn-test-hello ()
  (ladybird-test-with-env
    (let* ((ladybird--viewport-function (lambda () (list 1600 1000 2)))
           (written nil)
           (conn (cl-letf (((symbol-function 'ladybird--write)
                            (lambda (_conn bytes) (push bytes written))))
                   (ladybird--connect ladybird-test-host #'ignore)))
           (hello (ladybird-test-decode (car (last written)))))
      (should (eq (ladybird--conn-state conn) 'hello))
      (should (equal (alist-get 'type hello) "hello"))
      (should (equal (alist-get 'protocol hello) 1))
      (should (equal (alist-get 'client hello) "ladybird 0.1.0"))
      (should (equal (alist-get 'viewport hello)
                     '((width . 1600) (height . 1000) (dpr . 2.0))))
      (should (equal (alist-get 'encodings hello) ["zstd" "raw"]))
      (should (eq (alist-get 'shm hello) t))
      (should (eq (alist-get 'popups hello) t))
      (should (string-search "\"token\":null" (car (last written))))
      (should (timerp (ladybird--conn-hello-timer conn))))))

(ert-deftest ladybird-conn-test-hello-shm ()
  (ladybird-test-with-env
    (dolist (case '(((:kind ssh :host "h") . nil)
                    ((:kind tcp :host "h" :port 1) . nil)
                    ((:kind unix :path "/s" :shm nil) . nil)
                    ((:kind unix :path "/s") . t)
                    ((:kind local :command ("x")) . t)))
      (setq ladybird-test-sent nil)
      (ladybird--connect (list (format "%S" (car case)) (car case)) #'ignore)
      (should (eq (alist-get 'shm (car (ladybird-test-sent "hello")))
                  (cdr case))))))

(ert-deftest ladybird-conn-test-welcome ()
  (ladybird-test-with-env
    (let* ((calls nil)
           (welcomed nil)
           (ladybird--welcome-function
            (lambda (conn msg)
              (should (ladybird--ready-p conn))
              (should-not calls)
              (setq welcomed (alist-get 'server msg))))
           (conn (ladybird--connect ladybird-test-host
                                  (lambda (c) (push (list 1 c) calls)))))
      (should (eq (ladybird--connect ladybird-test-host
                                   (lambda (c) (push (list 2 c) calls)))
                  conn))
      (should (= (length ladybird-test-processes) 1))
      (should-not calls)
      (ladybird-test-receive conn (ladybird-test-welcome))
      (should (eq (ladybird--conn-state conn) 'ready))
      (should (equal welcomed "test"))
      (should (equal (reverse calls) `((1 ,conn) (2 ,conn))))
      (should-not (ladybird--conn-hello-timer conn))
      (should (equal (ladybird--conn-encoding conn) "raw"))
      (should (equal (ladybird--conn-endpoint conn) (cadr ladybird-test-host)))
      (should (timerp ladybird--keepalive-timer))
      ;; A ready connection calls back at once.
      (ladybird--connect ladybird-test-host (lambda (c) (push (list 3 c) calls)))
      (should (equal (car calls) `(3 ,conn)))
      (should (= (length ladybird-test-processes) 1)))))

(ert-deftest ladybird-conn-test-reject ()
  (ladybird-test-with-env
    (let* ((called nil)
           (conn (ladybird--connect ladybird-test-host (lambda (_) (setq called t)))))
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (ladybird-test-receive conn '((type . "reject") (reason . "no")))
      (should (eq (ladybird--conn-state conn) 'closed))
      (should-not called)
      (should-not (ladybird--conn-on-ready conn))
      (should-not (ladybird--conn-timer conn))
      (should-not (process-live-p (car ladybird-test-processes))))))

(ert-deftest ladybird-conn-test-protocol-mismatch ()
  (ladybird-test-with-env
    (let ((conn (ladybird--connect ladybird-test-host #'ignore)))
      (ladybird-test-receive conn '((type . "welcome") (protocol . 2)))
      (should (eq (ladybird--conn-state conn) 'closed))
      (should-not (ladybird--conn-process conn)))))

(ert-deftest ladybird-conn-test-endpoints ()
  (ladybird-test-with-env
    (let* ((first '(:kind unix :path "/a"))
           (second '(:kind tcp :host "b" :port 1))
           (conn (ladybird--connect (list "two" first second) #'ignore)))
      (should (equal ladybird-test-opened (list first)))
      ;; The first endpoint closes without a welcome.
      (ladybird--drop conn)
      (should (equal ladybird-test-opened (list second first)))
      (should (eq (ladybird--conn-state conn) 'hello))
      (ladybird-test-receive conn (ladybird-test-welcome))
      (should (equal (ladybird--conn-endpoint conn) second))
      ;; The endpoint that answered is dialled first the next time.
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (ladybird--drop conn)
      (should (eq (ladybird--conn-state conn) 'redialing))
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (should (equal (car ladybird-test-opened) second)))))

(ert-deftest ladybird-conn-test-hello-timeout ()
  (ladybird-test-with-env
    (let* ((called nil)
           (conn (ladybird--connect ladybird-test-host (lambda (_) (setq called t))))
           (process (ladybird--conn-process conn)))
      (ladybird-test-run-timer (ladybird--conn-hello-timer conn))
      (should-not (process-live-p process))
      (should (eq (ladybird--conn-state conn) 'closed))
      (should-not (ladybird--conn-on-ready conn))
      (should-not called))))

(ert-deftest ladybird-conn-test-dial-error ()
  (ladybird-test-with-env
    (setq ladybird-test-open-error t)
    (should-error (ladybird--connect ladybird-test-host #'ignore))
    (should-not ladybird--conns)))

(ert-deftest ladybird-conn-test-ping-pong ()
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect)))
      (ladybird-test-receive conn '((type . "ping") (id . 5)))
      (should (equal (ladybird-test-sent) '(((type . "pong") (id . 5)))))
      (setq ladybird-test-sent nil)
      (ladybird--probe conn)
      (should (equal (ladybird-test-sent) '(((type . "ping") (id . 1)))))
      (should (timerp (ladybird--conn-ping-timer conn)))
      ;; One probe at a time.
      (ladybird--probe conn)
      (should (= (length (ladybird-test-sent "ping")) 1))
      (ladybird-test-receive conn '((type . "pong") (id . 1)))
      (should-not (ladybird--conn-ping-timer conn))
      (should (ladybird--ready-p conn)))))

(ert-deftest ladybird-conn-test-probe-timeout ()
  (ladybird-test-with-env
    (let* ((conn (ladybird-test-connect))
           (process (ladybird--conn-process conn)))
      (setf (ladybird--conn-last-read conn) 0.0)
      (ladybird--probe conn)
      (ladybird-test-run-timer (ladybird--conn-ping-timer conn))
      (should-not (process-live-p process))
      ;; Without views nothing redials.
      (should (eq (ladybird--conn-state conn) 'closed)))
    (let ((conn (ladybird-test-connect '("other" (:kind unix :path "/o")))))
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (setf (ladybird--conn-last-read conn) 0.0)
      (ladybird--probe conn)
      (ladybird-test-run-timer (ladybird--conn-ping-timer conn))
      (should (eq (ladybird--conn-state conn) 'redialing)))))

(ert-deftest ladybird-conn-test-probe-answered-by-data ()
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect)))
      (setf (ladybird--conn-last-read conn) 0.0)
      (ladybird--probe conn)
      (let ((timer (ladybird--conn-ping-timer conn)))
        (ladybird-test-receive conn '((type . "state") (view . 1)))
        (ladybird-test-run-timer timer))
      (should (ladybird--ready-p conn)))))

(ert-deftest ladybird-conn-test-keepalive ()
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect))
          (ladybird-keepalive-interval 30))
      (ladybird--keepalive)
      (should-not (ladybird-test-sent "ping"))
      (setf (ladybird--conn-last-read conn) (- (float-time) 31))
      (ladybird--keepalive)
      (should (= (length (ladybird-test-sent "ping")) 1))
      (should (timerp ladybird--keepalive-timer))
      (ladybird--disconnect conn)
      (ladybird--keepalive)
      (should-not ladybird--keepalive-timer))))

(ert-deftest ladybird-conn-test-backoff ()
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect))
          (delays nil))
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (setq ladybird-test-open-error t)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (delay _repeat &rest _)
                   (push delay delays)
                   (timer-create))))
        (ladybird--drop conn)
        (dotimes (_ 6)
          (should (eq (ladybird--conn-state conn) 'redialing))
          (ladybird--redial conn)))
      (should (equal (reverse delays) '(1 2 4 8 16 30 30)))
      (should (numberp (ladybird--conn-retry-at conn)))
      ;; A connection that lasts ends the backoff; the welcome alone does
      ;; not.
      (setq ladybird-test-open-error nil)
      (ladybird--redial conn)
      (ladybird-test-receive conn (ladybird-test-welcome))
      (should (ladybird--ready-p conn))
      (should (= (ladybird--conn-delay conn) 30))
      (should-not (ladybird--conn-timer conn))
      (ladybird-test-run-timer (ladybird--conn-stable-timer conn))
      (should-not (ladybird--conn-delay conn))
      (should-not (ladybird--conn-stable-timer conn)))))

(ert-deftest ladybird-conn-test-backoff-welcome-then-death ()
  ;; A server that welcomes and goes away at once is not dialled again
  ;; every second.
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect))
          (delays nil))
      (ladybird-test-register conn 1)
      (dotimes (_ 4)
        (ladybird--drop conn)
        (should (eq (ladybird--conn-state conn) 'redialing))
        (push (round (- (ladybird--conn-retry-at conn) (float-time))) delays)
        (ladybird-test-run-timer (ladybird--conn-timer conn))
        (ladybird-test-receive conn (ladybird-test-welcome))
        (should (ladybird--ready-p conn)))
      (should (equal (reverse delays) '(1 2 4 8)))
      ;; The timer of a connection that is gone changes nothing.
      (let ((timer (ladybird--conn-stable-timer conn)))
        (ladybird--drop conn)
        (should-not (ladybird--conn-stable-timer conn))
        (timer-event-handler timer)
        (should (= (ladybird--conn-delay conn) 30))))))

(ert-deftest ladybird-conn-test-connect-during-redial ()
  ;; Connecting by hand while a redial waits does not end the redialling
  ;; when that attempt fails after the process opened.
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect))
          (called nil))
      (ladybird-test-register conn 1)
      (ladybird--drop conn)
      (should (eq (ladybird--conn-state conn) 'redialing))
      (ladybird--connect ladybird-test-host (lambda (_) (setq called t)))
      (should (eq (ladybird--conn-state conn) 'hello))
      (should-not (ladybird--conn-timer conn))
      ;; The server goes away before the welcome.
      (ladybird--drop conn)
      (should (eq (ladybird--conn-state conn) 'redialing))
      (should (timerp (ladybird--conn-timer conn)))
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (ladybird-test-receive conn (ladybird-test-welcome))
      (should called))))

(ert-deftest ladybird-conn-test-server-id ()
  (ladybird-test-with-env
    (let* ((conn (ladybird-test-connect))
           (welcome (lambda (log)
                      `((log . ,log)
                        ,@(assq-delete-all 'log (ladybird-test-welcome))))))
      (ladybird-test-register conn 1)
      (should-not (ladybird--conn-server-changed conn))
      ;; The same server after a lost connection.
      (ladybird--drop conn)
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (ladybird-test-receive conn (ladybird-test-welcome))
      (should-not (ladybird--conn-server-changed conn))
      ;; Another server process: its log file has another name.
      (ladybird--drop conn)
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (ladybird-test-receive conn (funcall welcome "/tmp/ladybird-emacs-4242.log"))
      (should (ladybird--conn-server-changed conn))
      (ladybird--drop conn)
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (ladybird-test-receive conn (funcall welcome "/tmp/ladybird-emacs-4242.log"))
      (should-not (ladybird--conn-server-changed conn)))))

(ert-deftest ladybird-conn-test-redial-unanswered ()
  ;; A redial that opens but is never welcomed backs off further.
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect)))
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (ladybird--drop conn)
      (should (= (ladybird--conn-delay conn) 2))
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (should (eq (ladybird--conn-state conn) 'hello))
      (ladybird--drop conn)
      (should (eq (ladybird--conn-state conn) 'redialing))
      (should (= (ladybird--conn-delay conn) 4)))))

(ert-deftest ladybird-conn-test-no-reconnect ()
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect))
          (ladybird-reconnect nil))
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (ladybird--drop conn)
      (should (eq (ladybird--conn-state conn) 'closed))
      (should-not (ladybird--conn-timer conn)))))

(ert-deftest ladybird-conn-test-replaced ()
  (ladybird-test-with-env
    (let* ((conn (ladybird-test-connect))
           (process (ladybird--conn-process conn)))
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (ladybird-test-receive conn '((type . "replaced")))
      (should (eq (ladybird--conn-state conn) 'replaced))
      (should-not (ladybird--conn-timer conn))
      (should-not (process-live-p process))
      ;; Connecting again dials.
      (ladybird--connect ladybird-test-host #'ignore)
      (should (eq (ladybird--conn-state conn) 'hello)))))

(ert-deftest ladybird-conn-test-endpoint-keeps-pages ()
  (dolist (case '(((:kind local) . nil)
                  ((:kind ssh :host "h") . nil)
                  ((:kind ssh :host "h" :path "/s") . t)
                  ((:kind unix :path "/s") . t)))
    (should (eq (ladybird--endpoint-keeps-pages-p (car case)) (cdr case))))
  (should (equal (ladybird--endpoint-name
                  '(:kind ssh :host "me@h" :port 22 :path "/s"))
                 "/ssh:me@h#22:/s")))

(ert-deftest ladybird-conn-test-socket-p ()
  (ladybird-test-with-env
    (should (ladybird--conn-socket-p
             (ladybird-test-connect '("a" (:kind ssh :host "h" :path "/s")))))
    (should-not (ladybird--conn-socket-p
                 (ladybird-test-connect '("b" (:kind ssh :host "h")))))
    (cl-letf (((symbol-function 'process-type) (lambda (_) 'network)))
      (should (ladybird--conn-socket-p (ladybird-test-connect))))))

(ert-deftest ladybird-conn-test-server-exit ()
  (ladybird-test-with-env
    (dolist (case '((t "exit 3" local closed)
                    (always "exit 3" local redialing)
                    (t "exit 255" ssh redialing)
                    (t "exit 1" ssh closed)
                    (t "exit 0" ssh redialing :path "/s")
                    (t "exit 255" ssh redialing :path "/s")
                    (nil "exit 255" ssh closed :path "/s")))
      (pcase-let* ((`(,ladybird-reconnect ,script ,kind ,state . ,rest) case)
                   (host (list (format "%S" case)
                               `(:kind ,kind :host "h" ,@rest)))
                   (conn nil))
        (cl-letf (((symbol-function 'ladybird--open-process)
                   (lambda (_endpoint)
                     (make-process :name "ladybird-test-exit" :buffer nil
                                   :command (list "sh" "-c"
                                                  (concat "read x; " script))
                                   :connection-type 'pipe :noquery t))))
          (setq conn (ladybird--connect host #'ignore))
          (ladybird-test-receive conn (ladybird-test-welcome))
          (puthash 1 (current-buffer) (ladybird--conn-views conn))
          (let ((process (ladybird--conn-process conn)))
            (process-send-string process "\n")
            (with-timeout (5 (ert-fail "the process did not exit"))
              (while (ladybird--conn-process conn)
                (accept-process-output process 0.05)))))
        (should (eq (ladybird--conn-state conn) state))))))

(ert-deftest ladybird-conn-test-frame-ack ()
  (ladybird-test-with-env
    (let* ((events nil)
           (ladybird--frame-function (lambda (_conn event) (push event events)))
           (conn (ladybird-test-connect)))
      ;; A frame of a view nobody registered is acknowledged and dropped.
      (ladybird-test-receive conn (ladybird-test-frame 41 99 4 3 nil 0 t))
      (should (equal (ladybird-test-sent)
                     '(((type . "frame_ack") (view . 99) (seq . 41)))))
      (should (equal events '((frame 99 41 4 3 1.0 0 0 4 3 t unknown-view))))
      (should-not (plist-get (ladybird-module-stats (ladybird--conn-decoder conn))
                             :views))
      ;; Frames that cannot be used are acknowledged too.
      (ladybird-test-register conn 99)
      (setq ladybird-test-sent nil)
      (ladybird-test-receive conn (ladybird-test-frame 42 99 8 8 '(0 0 1 1)))
      (should (eq (car (last (car events))) 'stale))
      (should (equal (ladybird-test-sent)
                     '(((type . "frame_ack") (view . 99) (seq . 42))))))))

(ert-deftest ladybird-conn-test-frame-without-header ()
  ;; A frame record too short to name its view cannot be acknowledged:
  ;; the connection is dropped and dialled again, like a broken stream.
  (ladybird-test-with-env
    (let* ((events nil)
           (ladybird--frame-function (lambda (_conn event) (push event events)))
           (conn (ladybird-test-connect))
           (process (ladybird--conn-process conn)))
      (ladybird-test-register conn 1)
      (ladybird--filter process (concat (ladybird--encode-record 2 "short")
                                        (ladybird-test-record '((type . "pong")))))
      (should-not (process-live-p process))
      (should (eq (ladybird--conn-state conn) 'redialing))
      (should-not (ladybird-test-sent))
      (should-not events))))

(ert-deftest ladybird-conn-test-handler-error ()
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect))
          (seen nil)
          (messages nil))
      (puthash "boom" (lambda (_conn _msg) (error "Boom")) ladybird--handlers)
      (puthash "after" (lambda (_conn msg) (push msg seen)) ladybird--handlers)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format format args) messages))))
        (ladybird-test-receive conn '((type . "boom")) '((type . "unknown"))
                             '((type . "after") (n . 1))))
      (should (equal seen '(((type . "after") (n . 1)))))
      (should (equal messages '("ladybird: boom: (error \"Boom\")"))))))

(ert-deftest ladybird-conn-test-nested-filter ()
  ;; A handler whose send lets the filter run again does not reorder.
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect))
          (seen nil))
      (puthash "a" (lambda (conn _msg)
                     (ladybird-test-receive conn '((type . "c")))
                     (push "a" seen))
               ladybird--handlers)
      (puthash "b" (lambda (_conn _msg) (push "b" seen)) ladybird--handlers)
      (puthash "c" (lambda (_conn _msg) (push "c" seen)) ladybird--handlers)
      (ladybird-test-receive conn '((type . "a")) '((type . "b")))
      (should (equal (reverse seen) '("a" "b" "c"))))))

(ert-deftest ladybird-conn-test-request ()
  (ladybird-test-with-env
    (let* ((conn (ladybird-test-connect))
           (answers nil)
           (id (ladybird--request conn "request_selection" '((view . 1))
                                (lambda (msg) (push msg answers))))
           (answer `((type . "selection") (view . 1) (request . ,id)
                     (text . "x"))))
      (should (equal (ladybird-test-sent)
                     `(((type . "request_selection") (request . ,id)
                        (view . 1)))))
      (ladybird-test-receive conn answer)
      (ladybird-test-receive conn answer)
      (should (equal answers (list answer)))
      (should (= (hash-table-count (ladybird--conn-pending conn)) 0))
      (should (/= id (ladybird--request conn "screenshot" nil #'ignore))))))

(ert-deftest ladybird-conn-test-send-states ()
  (ladybird-test-with-env
    (let ((conn (ladybird--connect ladybird-test-host #'ignore))
          (messages nil))
      (setq ladybird-test-sent nil)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format format args) messages))))
        ;; Before the welcome only the handshake and acks pass.
        (should-not (ladybird--send conn '((type . "mouse") (view . 1))))
        (should-not messages)
        (should-not (ladybird--send conn '((type . "load") (view . 1))))
        (should (equal messages '("ladybird: not connected to test; load dropped")))
        (should (ladybird--send conn '((type . "frame_ack") (view . 1) (seq . 1)))))
      (should (equal (mapcar (lambda (m) (alist-get 'type m)) (ladybird-test-sent))
                     '("frame_ack"))))))

(ert-deftest ladybird-conn-test-send-error ()
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect)))
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (cl-letf (((symbol-function 'ladybird--write)
                 (lambda (&rest _) (signal 'file-error '("Broken pipe")))))
        (should-not (ladybird--send conn '((type . "load") (view . 1)))))
      (should (eq (ladybird--conn-state conn) 'redialing)))))

(ert-deftest ladybird-conn-test-desync ()
  (ladybird-test-with-env
    (let* ((conn (ladybird-test-connect))
           (process (ladybird--conn-process conn)))
      (puthash 1 (current-buffer) (ladybird--conn-views conn))
      (ladybird--filter process (unibyte-string 0 0 0 0 1))
      (should-not (process-live-p process))
      (should (eq (ladybird--conn-state conn) 'redialing))
      ;; The redial starts with a clean decoder.
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (ladybird-test-receive conn (ladybird-test-welcome))
      (should (ladybird--ready-p conn)))))

(ert-deftest ladybird-conn-test-shm ()
  (skip-unless (not ladybird-test-native))
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect))
          (shm '((type . "shm") (view . 1) (name . "/ladybird-1-1")
                 (size . 4096))))
      ;; A segment for a view without a buffer is left alone.
      (ladybird-test-receive conn shm)
      (should-not (ladybird-test-sent))
      (ladybird-test-register conn 1)
      ;; The segment cannot be mapped.
      (ladybird-test-receive conn shm)
      (should (equal (ladybird-test-sent)
                     '(((type . "shm_failed") (view . 1)))))
      ;; The failure is reported once per connection.
      (setq ladybird-test-sent nil)
      (ladybird-test-receive conn shm)
      (should-not (ladybird-test-sent))
      ;; It maps smaller than announced.
      (setf (ladybird--conn-shm-failed conn) nil
            ladybird--no-shm-endpoints nil)
      (setq ladybird-fake-module-shm-size 2048)
      (ladybird-test-receive conn shm)
      (should (equal (ladybird-test-sent)
                     '(((type . "shm_failed") (view . 1)))))
      (should (= (plist-get (ladybird-module-stats (ladybird--conn-decoder conn))
                            :shm-size)
                 0))
      ;; It maps, rounded up to whole pages.
      (setf (ladybird--conn-shm-failed conn) nil
            ladybird--no-shm-endpoints nil)
      (setq ladybird-test-sent nil
            ladybird-fake-module-shm-size 16384)
      (ladybird-test-receive conn shm)
      (should-not (ladybird-test-sent))
      (should (= (plist-get (ladybird-module-stats (ladybird--conn-decoder conn))
                            :shm-size)
                 16384))
      ;; Each view has its own segment.
      (ladybird-test-register conn 2)
      (setq ladybird-fake-module-shm-size 8192)
      (ladybird-test-receive conn '((type . "shm") (view . 2)
                                    (name . "/ladybird-1-2") (size . 8192)))
      (should-not (ladybird-test-sent))
      (should (equal (sort (mapcar (lambda (view) (list (car view) (nth 4 view)))
                                   (plist-get (ladybird-module-stats
                                               (ladybird--conn-decoder conn))
                                              :views))
                           (lambda (a b) (< (car a) (car b))))
                     '((1 16384) (2 8192))))
      ;; A lost connection unmaps them.
      (ladybird--drop conn)
      (should (= (plist-get (ladybird-module-stats (ladybird--conn-decoder conn))
                            :shm-size)
                 0)))))

(ert-deftest ladybird-conn-test-shm-failure-remembered ()
  ;; A socket forwarded from another machine announces shared memory
  ;; that cannot be mapped.  That costs one frame; later connections to
  ;; the endpoint do not offer shared memory.
  (skip-unless (not ladybird-test-native))
  (ladybird-test-with-env
    (let* ((endpoint (cadr ladybird-test-host))
           (conn (ladybird-test-connect)))
      (ladybird-test-register conn 1)
      (should (ladybird--shm-p endpoint))
      (ladybird-test-receive conn '((type . "shm") (view . 1)
                                    (name . "/ladybird-1-1") (size . 4096)))
      (should (equal (ladybird-test-sent) '(((type . "shm_failed") (view . 1)))))
      (should (equal ladybird--no-shm-endpoints (list endpoint)))
      (should-not (ladybird--shm-p endpoint))
      ;; The redial says so in its hello.
      (ladybird--drop conn)
      (setq ladybird-test-sent nil)
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (should (eq (alist-get 'shm (car (ladybird-test-sent "hello")) 'missing)
                  nil))
      ;; So does a new connection to the same endpoint; another endpoint
      ;; still offers it.
      (ladybird--disconnect conn)
      (setq ladybird-test-sent nil)
      (ladybird--connect ladybird-test-host #'ignore)
      (should (eq (alist-get 'shm (car (ladybird-test-sent "hello")) 'missing)
                  nil))
      (setq ladybird-test-sent nil)
      (ladybird--connect '("other" (:kind unix :path "/other")) #'ignore)
      (should (eq (alist-get 'shm (car (ladybird-test-sent "hello"))) t)))))

(defconst ladybird-test-real-open (symbol-function 'ladybird--open-process)
  "The function that opens real processes, which the tests replace.")

(ert-deftest ladybird-conn-test-stderr-in-message ()
  ;; A server that cannot start says why on its standard error; the last
  ;; line of that is in the message, on one line.
  (ladybird-test-with-env
    (let ((messages nil)
          (stale (get-buffer-create ladybird--stderr-buffer)))
      (with-current-buffer stale
        (goto-char (point-max))
        (insert "an old line of another server\n"))
      (cl-letf (((symbol-function 'ladybird--open-process) ladybird-test-real-open)
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (when format
                     (push (apply #'format format args) messages)))))
        (let ((conn (ladybird--connect
                     `("far" (:kind local
                              :command ("sh" "-c"
                                        ,(concat "echo 'first line' >&2; "
                                                 "echo 'ssh: Could not resolve"
                                                 " hostname far' >&2; echo >&2;"
                                                 " exit 255"))))
                     #'ignore)))
          (with-timeout (5 (ert-fail "the process did not exit"))
            (while (not (eq (ladybird--conn-state conn) 'closed))
              (accept-process-output nil 0.05)))))
      (should (equal (reverse messages)
                     (list (concat "ladybird: the server on far exited with status 255"
                                   ": ssh: Could not resolve hostname far"
                                   " (see buffer \" *ladybird-stderr*\")")
                           (concat "ladybird: cannot reach far"
                                   ": ssh: Could not resolve hostname far"
                                   " (see buffer \" *ladybird-stderr*\")"))))
      (should-not (string-search "\n" (car messages))))
    ;; A server that wrote nothing: the old line of another one is not
    ;; taken for its message, and a long line is cut.
    (let ((conn (ladybird-test-connect)))
      (should (equal (ladybird--stderr-summary (ladybird--conn-stderr-start conn))
                     ""))
      (with-current-buffer ladybird--stderr-buffer
        (setf (ladybird--conn-stderr-start conn) (point-max))
        (goto-char (point-max))
        (insert (make-string 500 ?x) "\n"))
      (should (< (length (ladybird--stderr-summary
                          (ladybird--conn-stderr-start conn)))
                 260)))))

(ert-deftest ladybird-conn-test-shm-frames ()
  (skip-unless (not ladybird-test-native))
  (ladybird-test-with-env
    (let* ((statuses nil)
           (ladybird--frame-function
            (lambda (_conn event) (push (car (last event)) statuses)))
           (conn (ladybird-test-connect))
           (data (ladybird-test-file "shm.ladybird"))
           (shm-length (+ 4 (ladybird-fake-u32 data 0))))
      (setq ladybird-fake-module-shm-size (+ 4096 (* 64 48 4)))
      ;; The announcement and its first frame in one read: the segment is
      ;; mapped before the frame is decoded.
      (ladybird-test-register conn 1)
      (ladybird-module-attach-canvas (ladybird--conn-decoder conn) 1
                                   (ladybird-test-canvas 64 48))
      (ladybird--filter (ladybird--conn-process conn) data)
      (should (equal statuses '(painted)))
      (should (equal (ladybird-test-sent)
                     '(((type . "frame_ack") (view . 1) (seq . 1)))))
      ;; And in separate reads.
      (setq ladybird-test-sent nil
            statuses nil)
      (ladybird--filter (ladybird--conn-process conn) (substring data 0 shm-length))
      (ladybird--filter (ladybird--conn-process conn) (substring data shm-length))
      (should (equal statuses '(painted)))
      (should (equal (ladybird-test-sent)
                     '(((type . "frame_ack") (view . 1) (seq . 1)))))
      ;; A frame the module could not read from the segment makes the
      ;; server fall back to the stream.
      (setq ladybird-test-sent nil
            statuses nil)
      (ladybird-module-set-shm (ladybird--conn-decoder conn) 1 nil)
      (ladybird--filter (ladybird--conn-process conn) (substring data shm-length))
      (should (equal statuses '(shm-error)))
      (should (equal (ladybird-test-sent)
                     '(((type . "frame_ack") (view . 1) (seq . 1))
                       ((type . "shm_failed") (view . 1))))))))

(ert-deftest ladybird-conn-test-disconnect ()
  (ladybird-test-with-env
    (let* ((conn (ladybird-test-connect))
           (process (ladybird--conn-process conn))
           (decoder (ladybird--conn-decoder conn)))
      (ladybird--disconnect conn)
      (should-not (process-live-p process))
      (should-not ladybird--conns)
      (should (eq (ladybird--conn-state conn) 'closed))
      (should-error (ladybird-module-feed decoder "")))))

(ert-deftest ladybird-conn-test-call-prompt ()
  ;; The request of a prompt is declined however the prompt ends, unless
  ;; it was answered or withdrawn.
  (let* ((log nil)
         (decline (lambda () (push 'declined log)))
         (inhibit-message t))
    ;; Answered.
    (ladybird--call-prompt (lambda () (ladybird--note-answer nil)) decline)
    (should-not log)
    ;; A quit.
    (ladybird--call-prompt (lambda () (signal 'quit nil)) decline)
    (should (equal log '(declined)))
    ;; An error, such as a minibuffer that is in use.
    (setq log nil)
    (ladybird--call-prompt (lambda () (error "Command attempted to use minibuffer"))
                           decline)
    (should (equal log '(declined)))
    ;; Any other exit, such as `abort-recursive-edit' in another prompt.
    (setq log nil)
    (catch 'exit
      (ladybird--call-prompt (lambda () (throw 'exit t)) decline))
    (should (equal log '(declined)))
    ;; A function that ends without answering.
    (setq log nil)
    (ladybird--call-prompt #'ignore decline)
    (should (equal log '(declined)))
    ;; Answered, and an error after that: no second answer.
    (setq log nil)
    (ladybird--call-prompt (lambda ()
                             (ladybird--note-answer nil)
                             (error "Later"))
                           decline)
    (should-not log)
    ;; Withdrawn by the server: closed from a timer without an answer.
    (ladybird--call-prompt (lambda ()
                             (ladybird--cancel-prompt-later 'other)
                             (push (ladybird-test-close-timer) log)
                             (push 'kept log))
                           decline 'mine)
    (should (equal log '(declined kept nil)))
    (setq log nil)
    (ladybird--call-prompt (lambda ()
                             (ladybird--cancel-prompt-later 'mine)
                             (let ((timer (ladybird-test-close-timer)))
                               (push (and timer t) log)
                               (when timer
                                 (timer-event-handler timer)))
                             (push 'not log))
                           decline 'mine)
    (should (equal log '(t)))
    ;; An error in the declining answer does not escape.
    (ladybird--call-prompt #'ignore (lambda () (error "Broken pipe")))))

(ert-deftest ladybird-conn-test-later ()
  (let ((log nil)
        (ladybird--queued-prompts nil))
    (let ((timer (ladybird--later (lambda ()
                                    (ladybird--note-answer nil)
                                    (push 'timer log)))))
      (should (timerp timer))
      (ladybird-test-run-timer timer)
      (should (equal log '(timer)))
      (should-not ladybird--queued-prompts))
    ;; A prompt withdrawn before it opened never opens.
    (let ((timer (ladybird--later (lambda () (push 'opened log))
                                  (lambda () (push 'declined log)) 'key)))
      (ladybird--cancel-prompt-later 'key)
      (ladybird-test-run-timer timer)
      (should (equal log '(timer))))))

(ert-deftest ladybird-conn-test-later-waits-for-minibuffer ()
  ;; A prompt waits while the minibuffer is in use and opens once it is
  ;; free; its request is not declined meanwhile.
  (let* ((log nil)
         (ladybird--queued-prompts nil)
         (depth 1)
         (later nil))
    (cl-letf (((symbol-function 'minibuffer-depth) (lambda () depth))
              ((symbol-function 'run-at-time)
               (lambda (delay _repeat function &rest args)
                 (push (list delay function args) later)
                 (timer-create))))
      (let ((enable-recursive-minibuffers nil))
        (ladybird--later (lambda ()
                           (ladybird--note-answer 'key)
                           (push 'opened log))
                         (lambda () (push 'declined log)) 'key)
        (pcase-let ((`(,delay ,function ,args) (pop later)))
          (should (= delay 0))
          (apply function args))
        ;; Still waiting: it asks again shortly.
        (should-not log)
        (should (= (length ladybird--queued-prompts) 1))
        (pcase-let ((`(,delay ,function ,args) (pop later)))
          (should (> delay 0))
          (setq depth 0)
          (apply function args))
        (should (equal log '(opened)))
        (should-not ladybird--queued-prompts)
        (should-not later)))))

(ert-deftest ladybird-conn-test-send-plain-error ()
  ;; A broken pipe is a plain `error': the connection is dropped, the
  ;; error does not reach the caller.
  (ladybird-test-with-env
    (let ((conn (ladybird-test-connect)))
      (ladybird-test-register conn 1)
      (cl-letf (((symbol-function 'ladybird--write)
                 (lambda (&rest _) (error "Process ladybird not running"))))
        (should-not (ladybird--send conn '((type . "load") (view . 1)))))
      (should (eq (ladybird--conn-state conn) 'redialing))
      (should-not (ladybird--conn-process conn)))))

(ert-deftest ladybird-conn-test-keepalive-survives-error ()
  ;; A connection whose probe fails does not end the timer of the others.
  (ladybird-test-with-env
    (let ((one (ladybird-test-connect))
          (two (ladybird-test-connect '("two" (:kind unix :path "/two"))))
          (probed nil))
      (dolist (conn (list one two))
        (setf (ladybird--conn-last-read conn) (- (float-time) 1000)))
      (cl-letf (((symbol-function 'ladybird--probe)
                 (lambda (conn)
                   (push conn probed)
                   (when (eq conn two) (error "Boom")))))
        (ladybird--keepalive))
      (should (equal (length probed) 2))
      (should (timerp ladybird--keepalive-timer)))))

(ert-deftest ladybird-conn-test-loader ()
  ;; A sidecar that is no version, or a module older than required, makes
  ;; the loader warn and return nil.
  (require 'ladybird-module-load)
  (let* ((directory (make-temp-file "ladybird-loader" t))
         (ladybird-module-directory directory)
         (features (remq 'ladybird-module features))
         (warnings nil)
         (loaded nil)
         (version "0.0.1"))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings)))
                  ((symbol-function 'module-load)
                   (lambda (file) (push file loaded)))
                  ((symbol-function 'ladybird-module-version)
                   (lambda () version)))
          (with-temp-file (expand-file-name (ladybird--module-file-name) directory))
          (dolist (sidecar '("not a version" "v1..2" "0.0.1"))
            (with-temp-file (expand-file-name "ladybird-module.version" directory)
              (insert sidecar "\n"))
            (should-not (ladybird-load-module))
            (should-not loaded)
            (should (= (length warnings) 1))
            (setq warnings nil))
          ;; The sidecar is fine, the module that loads is too old.
          (with-temp-file (expand-file-name "ladybird-module.version" directory)
            (insert ladybird--minimum-module-version "\n"))
          (should-not (ladybird-load-module))
          (should (= (length loaded) 1))
          (should (string-match-p "older than required" (car warnings)))
          ;; One that is new enough.
          (setq version ladybird--minimum-module-version
                warnings nil)
          (should (ladybird-load-module))
          (should-not warnings)
          ;; A loaded module that is too old stays unusable.
          (let ((features (cons 'ladybird-module features)))
            (should (ladybird-load-module))
            (setq version "0.0.1")
            (should-not (ladybird-load-module))))
      (delete-directory directory t))))

(ert-deftest ladybird-conn-test-fake-views ()
  ;; The fake module follows the native one: frames of views nobody
  ;; registered are dropped, a forgotten view leaves nothing.
  (skip-unless (not ladybird-test-native))
  (let ((session (ladybird-module-create-session))
        (canvas (ladybird-test-canvas 4 3))
        (frame (ladybird-test-frame 1 1 4 3 nil 1 t))
        (status (lambda (events) (car (last (car events))))))
    (should (eq (funcall status (ladybird-module-feed session frame))
                'unknown-view))
    (should-not (plist-get (ladybird-module-stats session) :views))
    (should (eq (ladybird-module-register-view session 1) t))
    (should (eq (funcall status (ladybird-module-feed session frame)) 'stored))
    (should (equal (plist-get (ladybird-module-stats session) :views)
                   '((1 4 3 nil 0))))
    ;; A frame that cannot be decoded leaves the stored one.
    (should (eq (funcall status
                         (ladybird-module-feed
                          session
                          (ladybird--encode-record
                           2 (concat (ladybird--u32le 2) (ladybird--u32le 1)
                                     (ladybird--u32le 9) (ladybird--u32le 9)
                                     (unibyte-string 0 0 0 0 0 0 #xf0 #x3f)
                                     (ladybird--u32le 0) (ladybird--u32le 0)
                                     (ladybird--u32le 9) (ladybird--u32le 9)
                                     (unibyte-string 2 1 0 0)
                                     (make-string 8 0)))))
                'shm-error))
    (should (equal (ladybird-module-view-size session 1) '(4 . 3)))
    ;; A canvas spec that is broken is reported, the frame kept.
    (ladybird-module-attach-canvas session 1 canvas)
    (plist-put (cdr canvas) :data-width 'broken)
    (should (eq (funcall status (ladybird-module-feed session frame))
                'canvas-error))
    (should (eq (ladybird-module-forget-view session 1) t))
    (should-not (ladybird-module-forget-view session 1))
    (should-not (ladybird-module-view-size session 1))
    (should (eq (funcall status (ladybird-module-feed session frame))
                'unknown-view))
    (should-error (ladybird-module-set-shm session 1 "/x")
                  :type 'ladybird-module-error)))


;;; Mock server

(defconst ladybird-test-mock
  (expand-file-name "../tools/mock-server.py" ladybird-test-directory)
  "The mock server.")

(defun ladybird-test-mock-host (log &rest arguments)
  "Return a host that runs the mock server with ARGUMENTS, logging to LOG."
  (list "mock" (list :kind 'local
                     :command `("python3" "-I" ,ladybird-test-mock "--fps" "0"
                                "--log" ,log ,@arguments))))

(defun ladybird-test-wait (conn predicate)
  "Read from CONN's process until PREDICATE returns non-nil."
  (with-timeout (10 (ert-fail "timed out waiting for the mock server"))
    (while (not (funcall predicate))
      (if-let* ((process (ladybird--conn-process conn)))
          (accept-process-output process 0.05)
        (sleep-for 0.05)))))

(defun ladybird-test-log (log)
  "Return the messages in the mock server's LOG file, oldest first."
  (with-temp-buffer
    (insert-file-contents log)
    (let (messages)
      (while (not (eobp))
        (push (ladybird--parse-json
               (buffer-substring (point) (line-end-position)))
              messages)
        (forward-line 1))
      (nreverse messages))))

(defun ladybird-test-mock-register (conn msg)
  "Register the views the welcome or `view_created' MSG names on CONN."
  (dolist (view (or (append (alist-get 'views msg) nil) (list msg)))
    (ladybird-test-register conn (alist-get 'view view)
                            (get-buffer-create " *ladybird-test*"))))

(defvar ladybird-test-mock-welcome #'ladybird-test-mock-register
  "Function `ladybird-test-with-mock' calls with CONN and the welcome.")

(defmacro ladybird-test-with-mock (arguments &rest body)
  "Run BODY with `conn' ready on a mock server started with ARGUMENTS.
`log' is the server's log file, `frames' the frame events and `states'
the state messages received, newest first."
  (declare (indent 1) (debug t))
  `(let* ((log (make-temp-file "ladybird-mock" nil ".log"))
          (frames nil)
          (states nil)
          (ladybird--conns nil)
          (ladybird--keepalive-timer nil)
          (ladybird--no-shm-endpoints nil)
          (ladybird--handlers (copy-hash-table ladybird--handlers))
          (ladybird--frame-function (lambda (_conn event) (push event frames)))
          (ladybird--welcome-function ladybird-test-mock-welcome)
          (ladybird--change-function #'ignore)
          (ladybird--viewport-function (lambda () (list 64 48 1.0)))
          (inhibit-message t)
          (conn nil))
     (ignore frames states)
     (puthash "state" (lambda (_conn msg) (push msg states)) ladybird--handlers)
     (puthash "view_created" #'ladybird-test-mock-register ladybird--handlers)
     (unwind-protect
         (progn
           (setq conn (ladybird--connect
                       (ladybird-test-mock-host log ,@arguments) #'ignore))
           (ladybird-test-wait conn (lambda () (not (eq (ladybird--conn-state conn)
                                                      'hello))))
           ,@body)
       (dolist (conn ladybird--conns)
         (ladybird--disconnect conn))
       (when ladybird--keepalive-timer
         (cancel-timer ladybird--keepalive-timer))
       (delete-file log))))

(ert-deftest ladybird-mock-test-frames ()
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (ladybird-test-with-mock ()
    (should (ladybird--ready-p conn))
    (should (equal (alist-get 'server (ladybird--conn-server-info conn))
                   (format "ladybird mock server (%d)"
                           (process-id (ladybird--conn-process conn)))))
    (ladybird--send conn '((type . "create_view") (url . "mock://one")
                         (width . 64) (height . 48) (dpr . 1.0)))
    (ladybird-test-wait conn (lambda () (and states frames)))
    (should (equal (alist-get 'title (car states)) "Mock: mock://one"))
    (should (equal (car frames) '(frame 1 1 64 48 1.0 0 0 64 48 t stored)))
    (let ((canvas (ladybird-test-canvas 64 48))
          (decoder (ladybird--conn-decoder conn)))
      (ladybird-module-attach-canvas decoder 1 canvas)
      (should (eq (ladybird-module-repaint decoder 1) 'painted))
      (should (= (ladybird-module-canvas-pixel canvas 63 47)
                 (ladybird-test-pixel 63 47 0 64 48)))
      ;; The acknowledgement lets the next frame through.
      (ladybird--send conn '((type . "mouse") (view . 1) (kind . "down")
                           (x . 30) (y . 20) (button . "left")
                           (buttons . ["left"]) (modifiers . 0) (clicks . 1)))
      (ladybird-test-wait conn (lambda () (cdr frames)))
      (should (equal (car frames) '(frame 1 2 64 48 1.0 18 8 24 24 nil painted)))
      (should (= (ladybird-module-canvas-pixel canvas 30 20) #xffffffff))
      (should (= (ladybird-module-canvas-pixel canvas 17 20)
                 (ladybird-test-pixel 17 20 0 64 48))))
    (ladybird--probe conn)
    (ladybird-test-wait conn (lambda () (not (ladybird--conn-ping-timer conn))))
    (let ((types (mapcar (lambda (m) (alist-get 'type m)) (ladybird-test-log log))))
      (should (equal (seq-take types 3) '("_connected" "hello" "create_view")))
      (should (= (seq-count (lambda (type) (equal type "frame_ack")) types) 2)))))

(ert-deftest ladybird-mock-test-zstd ()
  :tags '(mock)
  (skip-unless (and (executable-find "python3") (executable-find "zstd")))
  (ladybird-test-with-mock ("--zstd" "--views" "1")
    (should (equal (ladybird--conn-encoding conn) "zstd"))
    (should (equal (alist-get 'width
                              (aref (alist-get 'views
                                               (ladybird--conn-server-info conn))
                                    0))
                   800))
    (ladybird-test-wait conn (lambda () frames))
    (should (equal (car frames) '(frame 1 1 800 600 1.0 0 0 800 600 t stored)))
    (let ((canvas (ladybird-test-canvas 800 600))
          (decoder (ladybird--conn-decoder conn)))
      (ladybird-module-attach-canvas decoder 1 canvas)
      (should (eq (ladybird-module-repaint decoder 1) 'painted))
      (should (= (ladybird-module-canvas-pixel canvas 799 300)
                 (ladybird-test-pixel 799 300 0 800 600))))))

(ert-deftest ladybird-mock-test-shm-fallback ()
  :tags '(mock)
  (skip-unless (and (executable-find "python3") (not ladybird-test-native)))
  ;; The fake module maps nothing, as over a forwarded socket.
  (ladybird-test-with-mock ("--shm" "--views" "1")
    (should (eq (ladybird--conn-shm conn) t))
    (ladybird-test-wait conn (lambda () (cdr frames)))
    (should (equal (mapcar (lambda (event) (car (last event))) frames)
                   '(stored shm-error)))
    (let ((sent (seq-filter (lambda (m) (string-prefix-p "_frame" (alist-get 'type m)))
                            (ladybird-test-log log))))
      (should (equal (mapcar (lambda (m) (alist-get 'encoding m)) sent)
                     '("shm" "raw"))))
    (should (seq-find (lambda (m) (equal (alist-get 'type m) "shm_failed"))
                      (ladybird-test-log log)))))

(ert-deftest ladybird-mock-test-shm-fallback-two-views ()
  ;; One shm_failed, sent once, brings every view whole frames in the stream.
  :tags '(mock)
  (skip-unless (and (executable-find "python3") (not ladybird-test-native)))
  (ladybird-test-with-mock ("--shm" "--views" "2")
    (should (eq (ladybird--conn-shm conn) t))
    (let ((raw (lambda ()
                 (seq-filter (lambda (m) (and (equal (alist-get 'type m) "_frame_sent")
                                              (equal (alist-get 'encoding m) "raw")))
                             (ladybird-test-log log)))))
      (ladybird-test-wait conn (lambda ()
                                 (equal (sort (delete-dups
                                               (mapcar (lambda (m) (alist-get 'view m))
                                                       (funcall raw)))
                                              #'<)
                                        '(1 2))))
      (dolist (m (funcall raw))
        (should (eq (alist-get 'full m) t)))
      ;; Every view's frames get through: the shared memory ones fail,
      ;; the stream ones are stored.
      (ladybird-test-wait
       conn (lambda ()
              (seq-every-p
               (lambda (view)
                 (memq 'stored (mapcar (lambda (event) (car (last event)))
                                       (seq-filter (lambda (event) (eql (nth 1 event) view))
                                                   frames))))
               '(1 2))))
      (should (= 1 (seq-count (lambda (m) (equal (alist-get 'type m) "shm_failed"))
                              (ladybird-test-log log)))))))

(ert-deftest ladybird-mock-test-shm ()
  ;; The mock writes the announcement of a segment and the first frame
  ;; in it with one write.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((canvas (ladybird-test-canvas 800 600))
         (ladybird-fake-module-shm-size (* 1024 1024 1024))
         (ladybird-test-mock-welcome
          (lambda (conn msg)
            (ladybird-test-mock-register conn msg)
            (ladybird-module-attach-canvas (ladybird--conn-decoder conn) 1 canvas))))
    (ladybird-test-with-mock ("--shm" "--views" "1")
      (should (eq (ladybird--conn-shm conn) t))
      (ladybird-test-wait conn (lambda () frames))
      (should (equal (car frames) '(frame 1 1 800 600 1.0 0 0 800 600 t painted)))
      (should (>= (plist-get (ladybird-module-stats (ladybird--conn-decoder conn))
                             :shm-size)
                  (* 800 600 4)))
      (when ladybird-test-native
        (should (= (ladybird-module-canvas-pixel canvas 799 599)
                   (ladybird-test-pixel 799 599 0 800 600))))
      ;; A later frame is read from the segment too.
      (ladybird--send conn '((type . "mouse") (view . 1) (kind . "down")
                           (x . 30) (y . 20) (button . "left")
                           (buttons . ["left"]) (modifiers . 0) (clicks . 1)))
      (ladybird-test-wait conn (lambda () (cdr frames)))
      (should (eq (car (last (car frames))) 'painted))
      (when ladybird-test-native
        (should (= (ladybird-module-canvas-pixel canvas 30 20) #xffffffff)))
      (let ((log (ladybird-test-log log)))
        (should-not (seq-find (lambda (m) (equal (alist-get 'type m) "shm_failed"))
                              log))
        (should (equal (mapcar (lambda (m) (alist-get 'encoding m))
                               (seq-filter (lambda (m)
                                             (equal (alist-get 'type m)
                                                    "_frame_sent"))
                                           log))
                       '("shm" "shm")))))))

(ert-deftest ladybird-mock-test-shm-two-views ()
  ;; Each view has its own segment.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let ((ladybird-fake-module-shm-size (* 1024 1024 1024)))
    (ladybird-test-with-mock ("--shm" "--views" "2")
      (ladybird-test-wait conn (lambda () (cdr frames)))
      (should (equal (sort (mapcar (lambda (event) (list (nth 1 event)
                                                         (car (last event))))
                                   frames)
                           (lambda (a b) (< (car a) (car b))))
                     '((1 stored) (2 stored))))
      (let ((views (plist-get (ladybird-module-stats (ladybird--conn-decoder conn))
                              :views)))
        (should (= (length views) 2))
        (dolist (view views)
          (should (equal (take 3 (cdr view)) '(800 600 nil)))
          (should (>= (nth 4 view) (* 800 600 4)))))
      (should-not (seq-find (lambda (m) (equal (alist-get 'type m) "shm_failed"))
                            (ladybird-test-log log))))))

(ert-deftest ladybird-mock-test-reject ()
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (ladybird-test-with-mock ("--reject")
    (should (eq (ladybird--conn-state conn) 'closed))))

(ert-deftest ladybird-mock-test-takeover ()
  ;; A connection that closes or says no valid hello first leaves the
  ;; client of a server on a socket alone; a hello takes over.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((runtime (make-temp-file "ladybird-runtime" t))
         (process-environment (cons (concat "XDG_RUNTIME_DIR=" runtime)
                                    process-environment))
         (socket (expand-file-name "mock.sock" runtime))
         (log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird--frame-function #'ignore)
         (ladybird--welcome-function #'ignore)
         (ladybird--change-function #'ignore)
         (ladybird--viewport-function (lambda () (list 64 48 1.0)))
         (inhibit-message t)
         (server (make-process
                  :name "ladybird-test-mock" :buffer nil :noquery t
                  :command (list "python3" "-I" ladybird-test-mock "--fps" "0"
                                 "--log" log "--socket" socket)))
         (count (lambda (type)
                  (seq-count (lambda (m) (equal (alist-get 'type m) type))
                             (ladybird-test-log log))))
         (others nil)
         (other (lambda (message)
                  ;; A connection that sends MESSAGE, an alist or the
                  ;; bytes of records, and returns what it read once the
                  ;; server has closed it.
                  (let* ((output "")
                         (process (make-network-process
                                   :name "ladybird-test-other" :family 'local
                                   :service socket :coding 'binary :noquery t
                                   :filter (lambda (_ string)
                                             (setq output (concat output string))))))
                    (push process others)
                    (process-send-string
                     process (if (stringp message)
                                 message
                               (ladybird--encode-record 1 (json-serialize message))))
                    (with-timeout (10 (ert-fail "the server keeps the connection"))
                      (while (process-live-p process)
                        (accept-process-output process 0.05)))
                    output)))
         conn)
    (unwind-protect
        (progn
          (with-timeout (10 (ert-fail "the mock server does not listen"))
            (while (not (ladybird--socket-live-p socket))
              (sleep-for 0.05)))
          (setq conn (ladybird--connect
                      (list "mock" (list :kind 'unix :path socket)) #'ignore))
          (ladybird-test-wait conn (lambda () (ladybird--ready-p conn)))
          (dotimes (_ 3)
            (should (ladybird--socket-live-p socket)))
          (should (string-search "the first message must be hello"
                                 (funcall other '((type . "ping") (id . 1)))))
          (should (string-search "unsupported protocol version"
                                 (funcall other '((type . "hello") (protocol . 2)))))
          ;; A framing error behind a record.
          (should (string-search "framing error"
                                 (funcall other (concat (ladybird--encode-record 2 "xx")
                                                        (unibyte-string 0 0 0 0 1)))))
          (ladybird--probe conn)
          (ladybird-test-wait conn (lambda () (not (ladybird--conn-ping-timer conn))))
          (should (ladybird--ready-p conn))
          (should (= (funcall count "_connected") 1))
          (should (= (funcall count "_disconnected") 0))
          ;; A second client takes over.
          (let ((second (make-network-process
                         :name "ladybird-test-other" :family 'local
                         :service socket :coding 'binary :noquery t
                         :filter #'ignore)))
            (push second others)
            (process-send-string
             second
             (ladybird--encode-record
              1 (json-serialize '((type . "hello") (protocol . 1)
                                  (viewport . ((width . 80) (height . 24)
                                               (dpr . 1.0)))
                                  (encodings . ["raw"]) (shm . :false))))))
          (ladybird-test-wait conn (lambda () (eq (ladybird--conn-state conn)
                                                  'replaced)))
          (ladybird-test-wait conn (lambda () (= (funcall count "_connected") 2)))
          (should (= (funcall count "_disconnected") 1)))
      (mapc #'delete-process others)
      (mapc #'ladybird--disconnect ladybird--conns)
      (delete-process server)
      (delete-file log)
      (delete-directory runtime t))))

(ert-deftest ladybird-mock-test-exit ()
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (ladybird-test-with-mock ("--views" "1" "--exit-after" "0.3" "--exit-code" "3")
    (should (ladybird--ready-p conn))
    (puthash 1 (current-buffer) (ladybird--conn-views conn))
    (ladybird-test-wait conn (lambda () (not (ladybird--ready-p conn))))
    (should (eq (ladybird--conn-state conn) 'closed))))

(provide 'ladybird-conn-test)

;;; ladybird-conn-test.el ends here
