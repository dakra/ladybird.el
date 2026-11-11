;;; ladybird-conn.el --- Connections to a Ladybird server -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ladybird
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; The transport of ladybird: where servers are (`ladybird-hosts'), how they
;; are dialled (a local process, ssh, a Unix socket, TCP or TLS), the
;; record framing, the connection state machine with keepalive and
;; redial, and the dispatch of incoming records.
;;
;; A connection is a `ladybird--conn'.  Its state is one of
;;
;;   closed     nothing is open
;;   dialing    a process is opening
;;   hello      the hello is sent, the welcome is awaited
;;   ready      welcomed
;;   redialing  lost, a timer dials again
;;   replaced   another client took the server over
;;
;; Incoming bytes go to the native module, which returns control records
;; as JSON text and frame records as events.  Control records are
;; dispatched by type through `ladybird--handlers'; every frame event is
;; acknowledged and handed to `ladybird--frame-function'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)

(declare-function ladybird-module-create-session "ext:ladybird-module")
(declare-function ladybird-module-close "ext:ladybird-module" (session))
(declare-function ladybird-module-feed "ext:ladybird-module"
                  (session bytes &optional no-refresh))
(declare-function ladybird-module-reset "ext:ladybird-module" (session))
(declare-function ladybird-module-set-shm "ext:ladybird-module"
                  (session view name))

(defconst ladybird-version "0.1.0"
  "Version of the ladybird package.")

(defconst ladybird--protocol 1
  "Version of the wire protocol this client speaks.")

(defgroup ladybird nil
  "Ladybird pages in an Emacs canvas."
  :group 'web
  :prefix "ladybird-")

(defcustom ladybird-program "Ladybird"
  "Program of the local Ladybird server.
It runs as PROGRAM --headless=emacs and talks over its standard
input and output."
  :type 'string)

(defcustom ladybird-program-arguments nil
  "Additional arguments for a server started locally or over ssh."
  :type '(repeat string))

(defcustom ladybird-ssh-program "ssh"
  "Program that runs a server on another machine."
  :type 'string)

(defcustom ladybird-hosts nil
  "Servers to connect to, besides the local one.
An alist of (LABEL . ENDPOINT) or (LABEL ENDPOINT...); the endpoints of
a host are tried in order.  An endpoint is a string

  \"local\"                   the local `ladybird-program'
  \"ssh:HOST\", \"ssh://USER@HOST:PORT\"
                            `ladybird-program' on HOST, run by ssh
  \"/PATH\", \"unix:///PATH\"   a Unix socket
  \"tcp://HOST:PORT\"         a TCP port
  \"tls://HOST:PORT\"         a TCP port, with TLS

or a plist: (:ssh HOST :program PROGRAM :args LIST) names the remote
program, (:command (PROGRAM ARG...)) runs that command locally as the
server, and (:kind unix :path PATH :shm nil) keeps shared memory off
for a socket forwarded from another machine."
  :type '(alist :key-type string :value-type sexp))

(defcustom ladybird-keepalive-interval 30
  "Seconds a connection may stay silent before it is pinged."
  :type 'number)

(defcustom ladybird-ping-timeout 10
  "Seconds to wait for the answer to a ping."
  :type 'number)

(defcustom ladybird-connect-timeout 10
  "Seconds a server may take to accept a connection and welcome it."
  :type 'number)

(defcustom ladybird-reconnect t
  "Whether to dial a lost connection again.
With t a connection that has views is dialled again after 1, 2, 4 and
up to 30 seconds, unless its server process exited.  With `always' a
server that exited is started again too."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Lost connections" t)
                 (const :tag "Also servers that exited" always)))

(cl-defstruct (ladybird--conn (:constructor ladybird--make-conn) (:copier nil))
  "A connection to a server."
  host                           ; label, or nil for the local server
  endpoints                      ; plists from `ladybird--parse-endpoint'
  endpoint                       ; the one that last answered
  dialed                         ; the one PROCESS connects to
  untried                        ; endpoints left in this dial
  process
  (state 'closed)
  decoder                        ; module session
  encoding shm server-info       ; from the welcome
  server-id                      ; what tells this server process from another
  server-changed                 ; non-nil if the last welcome came from another
  (views (make-hash-table))      ; view id -> buffer
  creating                       ; (BUFFER . REQUEST) awaiting a view, oldest first
  closing                        ; ids of views to close with the next welcome
  view-limit                     ; number of views the server refused to exceed
  lingering                      ; timer that closes the connection left unused
  (pending (make-hash-table :test #'equal)) ; request id -> callback
  (next-request 0)
  on-ready                       ; functions of the connection, called when ready
  timer delay retry-at           ; redial timer, next delay, time it fires
  stable-timer                   ; timer that ends the backoff of a lasting connection
  hello-timer
  (ping-id 0) ping-timer
  (last-read 0.0)
  shm-failed                     ; non-nil once `shm_failed' was sent
  hints-ended                    ; (VIEW . ID) of the hint sessions that ended last
  stderr-start                   ; where the server's standard error begins
  input queue draining)          ; chunks not yet fed, events not yet handled

(defvar ladybird--conns nil
  "The connections, most recent first.")

(defvar ladybird--handlers (make-hash-table :test #'equal)
  "Hash table of message type strings to functions of CONN and MSG.")

(defvar ladybird--keepalive-timer nil
  "Timer that pings silent connections.")

(defvar ladybird--frame-function #'ignore
  "Function called with CONN and a frame event after its acknowledgement.
The event is (frame VIEW SEQ FRAME-W FRAME-H DPR DX DY DW DH FULL STATUS).")

(defvar ladybird--welcome-function #'ignore
  "Function called with CONN and the welcome message once CONN is ready.
It runs before the functions waiting for the connection.")

(defvar ladybird--change-function #'ignore
  "Function called with CONN when its state changes.")

(defconst ladybird--stable-seconds 10
  "Seconds a connection must last before a loss is redialled at once again.")

(defvar ladybird--viewport-function
  (lambda () (list (window-body-width nil t) (window-body-height nil t) 1.0))
  "Function returning (WIDTH HEIGHT DPR) for the hello, in device pixels.")

(defmacro ladybird--defhandler (type arglist &rest body)
  "Define the handler of control messages of TYPE.
ARGLIST names the connection and the message, an alist; BODY handles
the message."
  (declare (indent 2) (doc-string 3))
  (let ((name (intern (format "ladybird--recv-%s" (string-replace "_" "-" type)))))
    `(progn
       (defun ,name ,arglist ,@body)
       (puthash ,type #',name ladybird--handlers))))


;;; Framing

(defun ladybird--u32le (n)
  "Return N as four little-endian bytes."
  (unibyte-string (logand n 255) (logand (ash n -8) 255)
                  (logand (ash n -16) 255) (logand (ash n -24) 255)))

(defun ladybird--encode-record (kind payload)
  "Return the record of KIND with the unibyte string PAYLOAD.
The length field counts the kind byte and the payload."
  (concat (ladybird--u32le (1+ (length payload))) (unibyte-string kind) payload))

(defun ladybird--bool (value)
  "Return VALUE as a JSON boolean for `json-serialize'."
  (if value t :false))


;;; Hosts and endpoints

(defun ladybird--parse-network (kind rest)
  "Return the endpoint of KIND for REST, the HOST:PORT of a URL."
  (when (string-match "\\`\\(\\[[^]]+\\]\\|[^][:/]+\\):\\([0-9]+\\)/?\\'" rest)
    (let ((host (match-string 1 rest))
          (port (match-string 2 rest)))
      (list :kind kind
            :host (string-trim host "\\[" "\\]")
            :port (string-to-number port)))))

(defun ladybird--parse-endpoint (endpoint)
  "Return ENDPOINT as a plist (:kind KIND ...), or nil if it is malformed.
ENDPOINT is a string or plist as in `ladybird-hosts'."
  (pcase endpoint
    ((or 'nil "local") (list :kind 'local))
    ((and (pred stringp) (pred (string-prefix-p "/")))
     (list :kind 'unix :path endpoint))
    ((and (pred stringp) (pred (string-prefix-p "unix://")))
     (let ((path (url-unhex-string (substring endpoint (length "unix://")))))
       (and (string-prefix-p "/" path)
            (list :kind 'unix :path (decode-coding-string path 'utf-8)))))
    ((and (pred stringp) (pred (string-prefix-p "tcp://")))
     (ladybird--parse-network 'tcp (substring endpoint (length "tcp://"))))
    ((and (pred stringp) (pred (string-prefix-p "tls://")))
     (ladybird--parse-network 'tls (substring endpoint (length "tls://"))))
    ((and (pred stringp)
          (guard (string-match
                  "\\`ssh:\\(?://\\)?\\([^/:]+\\)\\(?::\\([0-9]+\\)\\)?/?\\'"
                  endpoint)))
     `(:kind ssh :host ,(match-string 1 endpoint)
             ,@(when-let* ((port (match-string 2 endpoint)))
                 (list :port (string-to-number port)))))
    ((and `(:ssh ,(and host (pred stringp)) . ,rest) (guard (plistp rest)))
     `(:kind ssh :host ,host ,@rest))
    ((and `(:command ,(and command `(,(pred stringp) . ,_)) . ,rest)
          (guard (plistp rest)))
     `(:kind local :command ,command ,@rest))
    ((and `(:kind ,kind . ,_) (guard (plistp endpoint)))
     (and (pcase kind
            ('local t)
            ('ssh (stringp (plist-get endpoint :host)))
            ('unix (stringp (plist-get endpoint :path)))
            ((or 'tcp 'tls) (and (stringp (plist-get endpoint :host))
                                 (integerp (plist-get endpoint :port)))))
          endpoint))))

(defun ladybird--host-endpoints (value)
  "Return the endpoint plists of VALUE, the cdr of a `ladybird-hosts' entry."
  (delq nil (mapcar #'ladybird--parse-endpoint
                    (if (or (stringp value) (keywordp (car-safe value)))
                        (list value)
                      value))))

(defun ladybird--hosts ()
  "Return the hosts as a list of (LABEL ENDPOINT...).
The local server has the label nil and comes first; it is left out
when `ladybird-program' is not found.  Hosts without a valid endpoint are
left out."
  (append (and (executable-find ladybird-program)
               (list (list nil (list :kind 'local))))
          (delq nil
                (mapcar (lambda (host)
                          (when-let* ((endpoints
                                       (ladybird--host-endpoints (cdr host))))
                            (cons (car host) endpoints)))
                        ladybird-hosts))))

(defvar ladybird--no-shm-endpoints nil
  "Endpoints whose server announced shared memory this Emacs could not map.
A Unix socket forwarded from another machine is one.")

(defun ladybird--shm-p (endpoint)
  "Return non-nil if a server at ENDPOINT may share memory with Emacs.
It may if it runs here or listens on a Unix socket, unless ENDPOINT
says :shm nil or a segment of a server there could not be mapped
before."
  (and (memq (plist-get endpoint :kind) '(local unix))
       (or (not (plist-member endpoint :shm))
           (plist-get endpoint :shm))
       (not (member endpoint ladybird--no-shm-endpoints))))

(defun ladybird--endpoint-name (endpoint)
  "Return a short description of ENDPOINT."
  (pcase (plist-get endpoint :kind)
    ('local (if-let* ((command (plist-get endpoint :command)))
                (file-name-nondirectory (car command))
              "local"))
    ('ssh (concat "ssh:" (plist-get endpoint :host)))
    ('unix (plist-get endpoint :path))
    (kind (format "%s://%s:%s" kind (plist-get endpoint :host)
                  (plist-get endpoint :port)))))

(defun ladybird--conn-name (conn)
  "Return CONN's host label or endpoint for messages."
  (or (ladybird--conn-host conn)
      (ladybird--endpoint-name (or (ladybird--conn-endpoint conn)
                                 (ladybird--conn-dialed conn)
                                 (car (ladybird--conn-endpoints conn))))))

(defun ladybird--ready-p (conn)
  "Return non-nil when CONN has been welcomed."
  (and conn (eq (ladybird--conn-state conn) 'ready)))

(defun ladybird--set-state (conn state)
  "Set CONN's STATE and announce the change."
  (setf (ladybird--conn-state conn) state)
  (funcall ladybird--change-function conn))


;;; Processes

(defconst ladybird--stderr-buffer " *ladybird-stderr*"
  "Name of the buffer that collects what servers write to standard error.")

(defun ladybird--stderr-process ()
  "Return a pipe that collects a server's standard error."
  (make-pipe-process :name "ladybird stderr"
                     :buffer (get-buffer-create ladybird--stderr-buffer)
                     :noquery t :sentinel #'ignore))

(defun ladybird--server-command (endpoint)
  "Return the command line of the server at the local or ssh ENDPOINT."
  (let ((arguments (append (list "--headless=emacs")
                           (or (plist-get endpoint :args)
                               ladybird-program-arguments))))
    (pcase (plist-get endpoint :kind)
      ('local
       (or (plist-get endpoint :command)
           (cons (or (executable-find ladybird-program)
                     (error "Program %s not found" ladybird-program))
                 arguments)))
      ('ssh
       `(,ladybird-ssh-program "-T"
         ,@(when-let* ((port (plist-get endpoint :port)))
             (list "-p" (number-to-string port)))
         ,(plist-get endpoint :host) "exec"
         ,@(mapcar #'shell-quote-argument
                   (cons (or (plist-get endpoint :program) ladybird-program)
                         arguments)))))))

(defun ladybird--open-process (endpoint)
  "Return a process connected, or connecting, to the server at ENDPOINT.
Signal an error if the connection fails at once."
  (let ((read-process-output-max (* 1024 1024))
        (process-adaptive-read-buffering nil)
        (name (format "ladybird %s" (ladybird--endpoint-name endpoint))))
    (pcase (plist-get endpoint :kind)
      ((or 'local 'ssh)
       (let* ((stderr (ladybird--stderr-process))
              (start (with-current-buffer (process-buffer stderr) (point-max)))
              (process (condition-case err
                           (make-process
                            :name name :buffer nil
                            :command (ladybird--server-command endpoint)
                            :connection-type 'pipe :coding 'binary
                            :noquery t :stderr stderr)
                         (error (delete-process stderr)
                                (signal (car err) (cdr err))))))
         (process-put process :ladybird-stderr stderr)
         (process-put process :ladybird-stderr-start start)
         process))
      ('unix
       (make-network-process :name name :buffer nil :family 'local
                             :service (plist-get endpoint :path)
                             :coding 'binary :noquery t))
      ((and kind (or 'tcp 'tls))
       (let ((process (open-network-stream
                       name nil (plist-get endpoint :host)
                       (plist-get endpoint :port)
                       :type (if (eq kind 'tls) 'tls 'plain)
                       :nowait t :coding 'binary)))
         (when (eq (process-status process) 'failed)
           (delete-process process)
           (error "Cannot connect to %s" (ladybird--endpoint-name endpoint)))
         (set-process-query-on-exit-flag process nil)
         process))
      (_ (error "Bad endpoint %S" endpoint)))))

(defun ladybird--delete-process (process)
  "Close the connection PROCESS for good.
A server process gets an end of file, on which it exits, and is killed
if it has not exited two seconds later."
  (if (not (and (eq (process-type process) 'real) (process-live-p process)))
      (delete-process process)
    (let ((stderr (process-get process :ladybird-stderr)))
      (set-process-filter process #'ignore)
      (set-process-sentinel
       process (lambda (process _change)
                 (when (and stderr (not (process-live-p process)))
                   (delete-process stderr))))
      (condition-case nil
          (progn
            (process-send-eof process)
            (run-at-time 2 nil (lambda ()
                                 (when (process-live-p process)
                                   (delete-process process)))))
        (error (delete-process process)
               (when stderr (delete-process stderr)))))))

(defun ladybird--write (conn bytes)
  "Write the unibyte string BYTES to CONN's process."
  (process-send-string (ladybird--conn-process conn) bytes))


;;; Sending

(defun ladybird--send (conn message)
  "Send the alist MESSAGE as a control record on CONN.
Return non-nil if it was written.  A connection that is not ready
takes only the handshake and frame acknowledgements; input is dropped
silently and anything else with a message.  A write that fails drops
the connection and returns nil."
  (let ((type (alist-get 'type message))
        (process (and conn (ladybird--conn-process conn))))
    (cond
     ((and (process-live-p process)
           (or (eq (ladybird--conn-state conn) 'ready)
               (member type '("hello" "frame_ack" "pong" "shm_failed"))))
      (condition-case nil
          (progn
            (ladybird--write conn (ladybird--encode-record
                                 1 (encode-coding-string
                                    (json-serialize message) 'utf-8 t)))
            t)
        ;; A broken pipe is a plain `error', not a `file-error'.
        (error
         (when (eq process (ladybird--conn-process conn))
           (ladybird--drop conn))
         nil)))
     ((member type '("mouse" "key" "text" "frame_ack" "pong" "shm_failed")) nil)
     (t (message "ladybird: not connected%s; %s dropped"
                 (if conn (concat " to " (ladybird--conn-name conn)) "")
                 type)
        nil))))

(defun ladybird--request (conn type fields callback)
  "Send a message of TYPE with the alist FIELDS and a request id on CONN.
CALLBACK is called once with the message that answers it."
  (let ((id (cl-incf (ladybird--conn-next-request conn))))
    (puthash id callback (ladybird--conn-pending conn))
    (unless (ladybird--send conn `((type . ,type) (request . ,id) ,@fields))
      (remhash id (ladybird--conn-pending conn)))
    id))

(defun ladybird--send-hello (conn)
  "Send the hello that opens CONN and await the welcome."
  (pcase-let ((`(,width ,height ,dpr) (funcall ladybird--viewport-function)))
    (setf (ladybird--conn-state conn) 'hello)
    (ladybird--send
     conn `((type . "hello")
            (protocol . ,ladybird--protocol)
            (client . ,(concat "ladybird " ladybird-version))
            (viewport . ((width . ,width) (height . ,height)
                         (dpr . ,(float dpr))))
            (encodings . ["zstd" "raw"])
            (shm . ,(ladybird--bool (ladybird--shm-p (ladybird--conn-dialed conn))))
            (token . :null)))))


;;; Dialling

(defun ladybird--module-available-p ()
  "Return non-nil when the native module's functions are defined."
  (fboundp 'ladybird-module-feed))

(defun ladybird--find-conn (host)
  "Return the connection to HOST, a (LABEL ENDPOINT...) list, or nil."
  (seq-find (lambda (conn) (equal (ladybird--conn-endpoints conn) (cdr host)))
            ladybird--conns))

(defun ladybird--connect (host callback)
  "Call CALLBACK with a ready connection to HOST, opening one if needed.
HOST is a (LABEL ENDPOINT...) list as `ladybird--hosts' returns them.
Return the connection."
  (unless (ladybird--module-available-p)
    (user-error "The ladybird-module is not loaded"))
  (let ((conn (ladybird--find-conn host)))
    (cond
     ((ladybird--ready-p conn) (funcall callback conn))
     ((and conn (process-live-p (ladybird--conn-process conn)))
      (push callback (ladybird--conn-on-ready conn)))
     (t
      (unless conn
        (setq conn (ladybird--make-conn :host (car host) :endpoints (cdr host)))
        (push conn ladybird--conns))
      (push callback (ladybird--conn-on-ready conn))
      (ladybird--cancel-redial conn)
      (setf (ladybird--conn-delay conn) nil)
      (condition-case err
          (ladybird--dial conn)
        (error
         (setf (ladybird--conn-on-ready conn) nil)
         (cond ((not (ladybird--conn-in-use-p conn)) (ladybird--disconnect conn))
               ((ladybird--redial-p conn nil) (ladybird--reconnect conn)))
         (signal (car err) (cdr err))))))
    conn))

(defun ladybird--dial (conn &optional endpoints)
  "Open CONN's connection and send the hello.
Try ENDPOINTS in order until one can be dialled; the others stay in
CONN for when that one does not answer with a welcome.  By default
these are all of CONN's, the one that last answered first.  Signal the
last error if none can be dialled."
  (let* ((last (ladybird--conn-endpoint conn))
         (endpoints (or endpoints
                        (append (and last (list last))
                                (remove last (ladybird--conn-endpoints conn)))))
         process err)
    (ladybird--cancel-timers conn)
    (while (and endpoints (not process))
      (let ((endpoint (pop endpoints)))
        (condition-case e
            (progn (setq process (ladybird--open-process endpoint))
                   (setf (ladybird--conn-dialed conn) endpoint))
          (error (setq err e)))))
    (setf (ladybird--conn-untried conn) endpoints)
    (unless process
      (ladybird--set-state conn 'closed)
      (signal (car err) (cdr err)))
    (if (ladybird--conn-decoder conn)
        (ladybird-module-reset (ladybird--conn-decoder conn))
      (setf (ladybird--conn-decoder conn) (ladybird-module-create-session)))
    (setf (ladybird--conn-process conn) process
          (ladybird--conn-stderr-start conn)
          (process-get process :ladybird-stderr-start)
          (ladybird--conn-queue conn) nil
          (ladybird--conn-input conn) nil
          (ladybird--conn-shm-failed conn) nil
          (ladybird--conn-last-read conn) (float-time)
          (ladybird--conn-hello-timer conn)
          (run-at-time ladybird-connect-timeout nil #'ladybird--hello-timeout
                       conn process))
    (process-put process :ladybird-conn conn)
    (set-process-filter process #'ladybird--filter)
    (set-process-sentinel process #'ladybird--sentinel)
    (ladybird--set-state conn 'dialing)
    ;; A network connection that is still opening gets its hello from
    ;; the sentinel.
    (unless (eq (process-status process) 'connect)
      (ladybird--send-hello conn))))

(defun ladybird--hello-timeout (conn process)
  "Give up on PROCESS if it has not brought CONN a welcome."
  (setf (ladybird--conn-hello-timer conn) nil)
  (when (and (eq process (ladybird--conn-process conn))
             (memq (ladybird--conn-state conn) '(dialing hello)))
    ;; Emacs waiting on something else leaves the answer unread.
    (when (process-live-p process)
      (accept-process-output process 0 nil 1))
    (when (and (eq process (ladybird--conn-process conn))
               (memq (ladybird--conn-state conn) '(dialing hello)))
      (ladybird--drop conn))))

(defun ladybird--cancel-timers (conn)
  "Cancel CONN's hello and ping timers."
  (when (ladybird--conn-hello-timer conn)
    (cancel-timer (ladybird--conn-hello-timer conn)))
  (when (ladybird--conn-ping-timer conn)
    (cancel-timer (ladybird--conn-ping-timer conn)))
  (setf (ladybird--conn-hello-timer conn) nil
        (ladybird--conn-ping-timer conn) nil))

(defun ladybird--cancel-redial (conn)
  "Cancel CONN's redial timer."
  (when (ladybird--conn-timer conn)
    (cancel-timer (ladybird--conn-timer conn)))
  (setf (ladybird--conn-timer conn) nil
        (ladybird--conn-retry-at conn) nil))

(defun ladybird--conn-in-use-p (conn)
  "Return non-nil if CONN has views or functions waiting for it."
  (or (> (hash-table-count (ladybird--conn-views conn)) 0)
      (ladybird--conn-creating conn)
      (ladybird--conn-closing conn)
      (ladybird--conn-on-ready conn)))

(defun ladybird--redial-p (conn server-exit)
  "Return non-nil if the lost CONN is to be dialled again.
It is while it has views, buffers waiting for one or views to close.
SERVER-EXIT is non-nil when the server's process exited by itself."
  (and ladybird-reconnect
       (or (> (hash-table-count (ladybird--conn-views conn)) 0)
           (ladybird--conn-creating conn)
           (ladybird--conn-closing conn))
       (or (not server-exit) (eq ladybird-reconnect 'always))))

(defun ladybird--reconnect (conn)
  "Dial CONN again after its delay, doubling it up to 30 seconds."
  (let ((delay (or (ladybird--conn-delay conn) 1)))
    (ladybird--cancel-redial conn)
    (setf (ladybird--conn-delay conn) (min 30 (* 2 delay))
          (ladybird--conn-retry-at conn) (+ (float-time) delay)
          (ladybird--conn-timer conn)
          (run-at-time delay nil #'ladybird--redial conn))
    (ladybird--set-state conn 'redialing)))

(defun ladybird--redial (conn)
  "Dial CONN again from its redial timer."
  (setf (ladybird--conn-timer conn) nil
        (ladybird--conn-retry-at conn) nil)
  (if (ladybird--redial-p conn nil)
      (condition-case nil
          (ladybird--dial conn)
        (error (ladybird--reconnect conn)))
    (ladybird--set-state conn 'closed)))

(defun ladybird--server-exit-p (conn process)
  "Return non-nil if PROCESS ended because CONN's server itself exited.
An ssh that exits with status 255 lost its connection instead."
  (let ((kind (plist-get (ladybird--conn-dialed conn) :kind)))
    (and (memq kind '(local ssh))
         (memq (process-status process) '(exit signal))
         (not (and (eq kind 'ssh) (eql (process-exit-status process) 255))))))

(defun ladybird--stderr-summary (conn)
  "Return what CONN's server last wrote to its standard error, for a message.
This is the last line that is not empty, cut to a length that fits the
echo area, with the name of the buffer that has all of it; or the
empty string if the server of this dial wrote nothing."
  (let ((line (when-let* ((buffer (get-buffer ladybird--stderr-buffer)))
                (with-current-buffer buffer
                  (let ((lines (split-string
                                (buffer-substring-no-properties
                                 (min (point-max)
                                      (or (ladybird--conn-stderr-start conn)
                                          (point-max)))
                                 (point-max))
                                "[\n\r]+" t "[ \t]+")))
                    (car (last lines)))))))
    (if line
        (format ": %s (see buffer%s)"
                (truncate-string-to-width line 200 nil nil t)
                ladybird--stderr-buffer)
      "")))

(defun ladybird--on-close (conn &optional process)
  "Handle the loss of CONN's connection.
PROCESS is the process that ended by itself, if one did.  Before a
welcome the endpoints not yet tried are dialled.  A connection that has
views, or buffers waiting for one, is dialled again as
`ladybird-reconnect' says, whether it was ready or still opening."
  (let ((state (ladybird--conn-state conn))
        (server-exit (and process (ladybird--server-exit-p conn process))))
    (ladybird--cancel-timers conn)
    (setf (ladybird--conn-process conn) nil
          (ladybird--conn-queue conn) nil
          (ladybird--conn-input conn) nil)
    (clrhash (ladybird--conn-pending conn))
    (when (ladybird--conn-stable-timer conn)
      (cancel-timer (ladybird--conn-stable-timer conn))
      (setf (ladybird--conn-stable-timer conn) nil))
    (when-let* ((decoder (ladybird--conn-decoder conn)))
      (maphash (lambda (view _buffer)
                 (ignore-errors (ladybird-module-set-shm decoder view nil)))
               (ladybird--conn-views conn)))
    (when (and server-exit (memq state '(dialing hello ready)))
      (message "ladybird: the server on %s exited with status %s%s"
               (ladybird--conn-name conn) (process-exit-status process)
               (ladybird--stderr-summary conn)))
    (pcase state
      ((or 'dialing 'hello)
       (let ((untried (ladybird--conn-untried conn)))
         (unless (and untried
                      (condition-case nil
                          (progn (ladybird--dial conn untried) t)
                        (error nil)))
           (if (ladybird--redial-p conn server-exit)
               (ladybird--reconnect conn)
             (when (ladybird--conn-on-ready conn)
               (message "ladybird: cannot reach %s%s" (ladybird--conn-name conn)
                        (ladybird--stderr-summary conn)))
             (setf (ladybird--conn-on-ready conn) nil
                   (ladybird--conn-delay conn) nil)
             (ladybird--set-state conn 'closed)))))
      ('ready
       (if (ladybird--redial-p conn server-exit)
           (ladybird--reconnect conn)
         (ladybird--set-state conn 'closed))))))

(defun ladybird--drop (conn)
  "Delete CONN's process and handle the loss of the connection."
  (when-let* ((process (ladybird--conn-process conn)))
    (setf (ladybird--conn-process conn) nil)
    (ladybird--delete-process process))
  (ladybird--on-close conn))

(defun ladybird--disconnect (conn)
  "Close CONN for good and forget it."
  (ladybird--cancel-timers conn)
  (ladybird--cancel-redial conn)
  (dolist (timer (list (ladybird--conn-stable-timer conn)
                       (ladybird--conn-lingering conn)))
    (when (timerp timer)
      (cancel-timer timer)))
  (setf (ladybird--conn-stable-timer conn) nil
        (ladybird--conn-lingering conn) nil)
  (when-let* ((process (ladybird--conn-process conn)))
    (setf (ladybird--conn-process conn) nil)
    (ladybird--delete-process process))
  (when-let* ((decoder (ladybird--conn-decoder conn)))
    (setf (ladybird--conn-decoder conn) nil)
    (ignore-errors (ladybird-module-close decoder)))
  (clrhash (ladybird--conn-pending conn))
  (setf (ladybird--conn-on-ready conn) nil
        (ladybird--conn-creating conn) nil
        (ladybird--conn-closing conn) nil
        (ladybird--conn-delay conn) nil
        (ladybird--conn-queue conn) nil
        (ladybird--conn-input conn) nil)
  (setq ladybird--conns (delq conn ladybird--conns))
  (ladybird--set-state conn 'closed))

(defun ladybird--sentinel (process _change)
  "Follow the status of PROCESS, the process of a connection."
  (when-let* ((conn (process-get process :ladybird-conn))
              ((eq process (ladybird--conn-process conn))))
    (pcase (process-status process)
      ('open
       (when (eq (ladybird--conn-state conn) 'dialing)
         (ladybird--send-hello conn)))
      ((or 'exit 'signal 'failed 'closed)
       (when-let* ((stderr (process-get process :ladybird-stderr)))
         ;; Read what the server said before the pipe goes away.
         (when (process-live-p stderr)
           (accept-process-output stderr 0 nil 1))
         (delete-process stderr))
       (ladybird--on-close conn process)))))


;;; Reading

(defun ladybird--filter (process chunk)
  "Handle CHUNK, bytes PROCESS received from its server.
A send can run this filter again before the events of an earlier chunk
are all handled; the later chunk then waits its turn."
  (when-let* ((conn (process-get process :ladybird-conn))
              ((eq process (ladybird--conn-process conn))))
    (setf (ladybird--conn-last-read conn) (float-time)
          (ladybird--conn-input conn) (nconc (ladybird--conn-input conn)
                                           (list chunk)))
    (unless (ladybird--conn-draining conn)
      (setf (ladybird--conn-draining conn) t)
      (unwind-protect
          ;; The module stops after a control record that has bytes
          ;; behind it, so that record is handled before the next one is
          ;; decoded; feeding the empty string continues.
          (let ((more t))
            (while (and (eq process (ladybird--conn-process conn))
                        (or (ladybird--conn-queue conn) (ladybird--conn-input conn)
                            more))
              (if (ladybird--conn-queue conn)
                  (ladybird--handle-item conn (pop (ladybird--conn-queue conn)))
                (setf (ladybird--conn-queue conn)
                      (ladybird-module-feed (ladybird--conn-decoder conn)
                                          (or (pop (ladybird--conn-input conn))
                                              "")))
                (setq more (and (ladybird--conn-queue conn) t)))))
        (setf (ladybird--conn-draining conn) nil)))))

(defun ladybird--parse-json (text)
  "Parse the JSON TEXT into alists with symbol keys."
  (json-parse-string text :object-type 'alist
                     :null-object nil :false-object nil))

(defun ladybird--handle-item (conn item)
  "Handle ITEM, an event the module returned for CONN.
An error in a handler is reported and does not stop the events after
it."
  (condition-case err
      (pcase item
        ((pred stringp) (ladybird--handle-control conn (ladybird--parse-json item)))
        (`(frame . ,_) (ladybird--handle-frame conn item))
        (`(desync ,reason ,offset)
         (message "ladybird: %s sent a broken stream (%s at byte %s)"
                  (ladybird--conn-name conn) reason offset)
         (ladybird--drop conn)))
    (error
     (message "ladybird: %s: %S"
              (cond ((stringp item)
                     (if (string-match "\"type\" *: *\"\\([^\"]*\\)\"" item)
                         (match-string 1 item)
                       "message"))
                    (t (car-safe item)))
              err))))

(defun ladybird--handle-control (conn msg)
  "Dispatch the control message MSG received on CONN.
The answer to a request goes to the request's callback; other messages
go to the handler of their type, and unknown types are ignored."
  (let* ((request (alist-get 'request msg))
         (callback (and request (gethash request (ladybird--conn-pending conn)))))
    (if callback
        (progn (remhash request (ladybird--conn-pending conn))
               (funcall callback msg))
      (when-let* ((handler (gethash (alist-get 'type msg) ladybird--handlers)))
        (funcall handler conn msg)))))

(defun ladybird--handle-frame (conn event)
  "Acknowledge the frame EVENT received on CONN and pass it on.
A frame the module could not read from shared memory makes the server
fall back to sending pixels in the stream.  A frame record too short
to name its view cannot be acknowledged, and the server would wait for
that for good: the connection is dropped like a broken stream."
  (pcase-let ((`(frame ,view ,seq . ,_) event))
    (if (not (and (integerp view) (integerp seq)))
        (progn
          (message "ladybird: %s sent a broken stream (a frame without a header)"
                   (ladybird--conn-name conn))
          (ladybird--drop conn))
      (ladybird--send conn `((type . "frame_ack") (view . ,view) (seq . ,seq)))
      (when (eq (car (last event)) 'shm-error)
        (ladybird--shm-failed conn view))
      (funcall ladybird--frame-function conn event))))

(defun ladybird--server-id (welcome)
  "Return what tells the server process that sent WELCOME from another.
The name of its log file has its process id."
  (list (alist-get 'server welcome) (alist-get 'log welcome)))

(defun ladybird--stable (conn process)
  "End the redial backoff of CONN if PROCESS is still its connection."
  (setf (ladybird--conn-stable-timer conn) nil)
  (when (and (eq process (ladybird--conn-process conn)) (ladybird--ready-p conn))
    (setf (ladybird--conn-delay conn) nil)))

(ladybird--defhandler "welcome" (conn msg)
  "Make CONN ready and call what waits for it."
  (when (eq (ladybird--conn-state conn) 'hello)
    (if (not (eql (alist-get 'protocol msg) ladybird--protocol))
        (progn
          (message "ladybird: %s speaks protocol %s, ladybird needs %s"
                   (ladybird--conn-name conn) (alist-get 'protocol msg)
                   ladybird--protocol)
          (setf (ladybird--conn-on-ready conn) nil)
          (ladybird--set-state conn 'closed)
          (ladybird--drop conn))
      (when (ladybird--conn-hello-timer conn)
        (cancel-timer (ladybird--conn-hello-timer conn)))
      (let ((id (ladybird--server-id msg)))
        (setf (ladybird--conn-hello-timer conn) nil
              (ladybird--conn-endpoint conn) (ladybird--conn-dialed conn)
              (ladybird--conn-untried conn) nil
              (ladybird--conn-encoding conn) (alist-get 'encoding msg)
              (ladybird--conn-shm conn) (alist-get 'shm msg)
              (ladybird--conn-server-info conn) msg
              (ladybird--conn-server-changed conn)
              (and (ladybird--conn-server-id conn)
                   (not (equal id (ladybird--conn-server-id conn))))
              (ladybird--conn-server-id conn) id
              ;; A server that welcomes and then goes away is not dialled
              ;; again at once: the backoff ends when the connection lasts.
              (ladybird--conn-stable-timer conn)
              (run-at-time ladybird--stable-seconds nil #'ladybird--stable conn
                           (ladybird--conn-process conn))))
      (ladybird--set-state conn 'ready)
      (ladybird--keepalive)
      (funcall ladybird--welcome-function conn msg)
      (let ((callbacks (nreverse (ladybird--conn-on-ready conn))))
        (setf (ladybird--conn-on-ready conn) nil)
        (dolist (callback callbacks)
          (funcall callback conn))))))

(ladybird--defhandler "reject" (conn msg)
  "Close CONN, which the server refused."
  (message "ladybird: %s refused the connection: %s"
           (ladybird--conn-name conn) (alist-get 'reason msg))
  (setf (ladybird--conn-on-ready conn) nil
        (ladybird--conn-untried conn) nil
        (ladybird--conn-delay conn) nil)
  (ladybird--set-state conn 'closed)
  (ladybird--drop conn))

(ladybird--defhandler "replaced" (conn _msg)
  "Leave CONN detached; another client has the server."
  (message "ladybird: another client took over %s" (ladybird--conn-name conn))
  (ladybird--set-state conn 'replaced)
  (ladybird--drop conn))

(ladybird--defhandler "ping" (conn msg)
  "Answer the server's ping on CONN."
  (ladybird--send conn `((type . "pong") (id . ,(or (alist-get 'id msg) 0)))))

(ladybird--defhandler "pong" (conn _msg)
  "End the probe of CONN."
  (when (ladybird--conn-ping-timer conn)
    (cancel-timer (ladybird--conn-ping-timer conn))
    (setf (ladybird--conn-ping-timer conn) nil)))

(defun ladybird--shm-failed (conn view)
  "Tell CONN's server once that its shared memory cannot be used.
VIEW is the view whose segment or frame failed.  The endpoint is
remembered, so that later connections to it do not offer shared memory."
  (unless (ladybird--conn-shm-failed conn)
    (setf (ladybird--conn-shm-failed conn) t)
    (cl-pushnew (ladybird--conn-dialed conn) ladybird--no-shm-endpoints
                :test #'equal)
    (ladybird--send conn `((type . "shm_failed") (view . ,view)))))

(ladybird--defhandler "shm" (conn msg)
  "Map the shared memory segment the server announces for a view on CONN.
A segment that cannot be mapped, or is smaller than announced, is
answered with `shm_failed'.  A segment for a view without a buffer is
left alone; the frames of such a view are not kept."
  (let ((decoder (ladybird--conn-decoder conn))
        (view (alist-get 'view msg)))
    (when (gethash view (ladybird--conn-views conn))
      (unless (and (ladybird--shm-p (ladybird--conn-dialed conn))
                   (condition-case nil
                       (>= (ladybird-module-set-shm decoder view
                                                    (alist-get 'name msg))
                           (alist-get 'size msg))
                     (error nil)))
        (ignore-errors (ladybird-module-set-shm decoder view nil))
        (ladybird--shm-failed conn view)))))


;;; Keepalive

(defun ladybird--keepalive ()
  "Probe every ready connection silent for `ladybird-keepalive-interval'.
Run again when the next connection falls due, until none is ready."
  (let ((now (float-time))
        next)
    (dolist (conn ladybird--conns)
      (when (ladybird--ready-p conn)
        (let ((due (+ (ladybird--conn-last-read conn) ladybird-keepalive-interval)))
          (when (<= due now)
            ;; One connection that fails does not end the timer of the
            ;; others.
            (condition-case err
                (ladybird--probe conn)
              (error (message "ladybird: probing %s: %S"
                              (ladybird--conn-name conn) err)))
            (setq due (+ now ladybird-keepalive-interval)))
          (setq next (min due (or next due))))))
    (when ladybird--keepalive-timer
      (cancel-timer ladybird--keepalive-timer))
    (setq ladybird--keepalive-timer
          (and next (run-at-time (max 1 (- next now)) nil #'ladybird--keepalive)))))

(defun ladybird--probe (conn)
  "Ping CONN and drop its connection if the server stays silent.
A connection has one probe at a time."
  (unless (ladybird--conn-ping-timer conn)
    (let ((sent (float-time)))
      (when (ladybird--send conn `((type . "ping")
                                 (id . ,(cl-incf (ladybird--conn-ping-id conn)))))
        (setf (ladybird--conn-ping-timer conn)
              (run-at-time ladybird-ping-timeout nil #'ladybird--probe-timeout
                           conn sent))))))

(defun ladybird--probe-timeout (conn sent)
  "Drop CONN's connection if nothing arrived since the ping at SENT."
  (setf (ladybird--conn-ping-timer conn) nil)
  (let ((process (ladybird--conn-process conn)))
    ;; Emacs waiting on another process leaves the answer unread.
    (when (and (process-live-p process) (< (ladybird--conn-last-read conn) sent))
      (accept-process-output process 0 nil 1))
    (when (and process (eq process (ladybird--conn-process conn))
               (< (ladybird--conn-last-read conn) sent))
      (ladybird--drop conn))))


;;; Prompting

(defvar ladybird--prompt nil
  "Key of the prompt being read, while one opened by `ladybird--later' is.")

(defvar ladybird--prompt-answered nil
  "Non-nil once the request of the prompt being read has its answer.")

(defvar ladybird--queued-prompts nil
  "Prompts not yet opened: a list of (KEY FUNCTION ON-QUIT).")

(defun ladybird--call-prompt (function &optional on-quit key)
  "Call FUNCTION, which prompts and answers a request of the server.
ON-QUIT sends the answer that declines.  It is called when FUNCTION
ends without `ladybird--prompt-answered' set, however it ends: by a
quit, an error or any other exit from the prompt.  The page that asked
waits for the answer.  KEY names the prompt for
`ladybird--cancel-prompt', which ends it without an answer."
  (let ((ladybird--prompt-answered nil)
        (cancelled nil))
    (unwind-protect
        (condition-case err
            (when (eq (catch 'ladybird--cancelled
                        (let ((ladybird--prompt key))
                          (funcall function))
                        nil)
                      'cancelled)
              (setq cancelled t))
          (quit nil)
          (error (message "ladybird: a prompt failed: %S" err)))
      (unless (or cancelled ladybird--prompt-answered (null on-quit))
        (condition-case err
            (funcall on-quit)
          (error (message "ladybird: declining a request: %S" err)))))))

(defun ladybird--minibuffer-busy-p ()
  "Return non-nil if a prompt cannot use the minibuffer now."
  (and (> (minibuffer-depth) 0) (not enable-recursive-minibuffers)))

(defun ladybird--run-prompt (entry)
  "Open the queued prompt ENTRY, or wait while the minibuffer is in use."
  (when (memq entry ladybird--queued-prompts)
    (if (ladybird--minibuffer-busy-p)
        (run-at-time 0.2 nil #'ladybird--run-prompt entry)
      (setq ladybird--queued-prompts (delq entry ladybird--queued-prompts))
      (pcase-let ((`(,key ,function ,on-quit) entry))
        (ladybird--call-prompt function on-quit key)))))

(defun ladybird--later (function &optional on-quit key)
  "Call FUNCTION, which prompts, from a timer; see `ladybird--call-prompt'.
A prompt inside the process filter would hold up the records after it,
and a quit out of it would drop them.  While the minibuffer is in use
the prompt waits for it.  ON-QUIT declines the request; KEY names the
prompt for `ladybird--cancel-prompt'."
  (let ((entry (list key function on-quit)))
    (setq ladybird--queued-prompts
          (nconc ladybird--queued-prompts (list entry)))
    (run-at-time 0 nil #'ladybird--run-prompt entry)))

(defun ladybird--cancel-prompt (key)
  "End the prompt named KEY without an answer.
A prompt that waits to be opened is forgotten; the one being read is
closed."
  (when key
    (setq ladybird--queued-prompts
          (seq-remove (lambda (entry) (equal (car entry) key))
                      ladybird--queued-prompts))
    (when (equal key ladybird--prompt)
      (throw 'ladybird--cancelled 'cancelled))))

(defun ladybird--cancel-prompt-later (key)
  "End the prompt named KEY without an answer, from a timer.
The process filter cannot leave the prompt it interrupts."
  (setq ladybird--queued-prompts
        (seq-remove (lambda (entry) (equal (car entry) key))
                    ladybird--queued-prompts))
  (run-at-time 0 nil #'ladybird--cancel-prompt key))

(provide 'ladybird-conn)

;;; ladybird-conn.el ends here
