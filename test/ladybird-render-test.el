;;; ladybird-render-test.el --- Tests for ladybird.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests of the page buffers: canvas and sizing, mouse and wheel,
;; keys and insert mode, dialogs and the other page events.  They use
;; the harness of ladybird-conn-test.el: a pipe process for the connection,
;; a recorder for what is sent, and the fake module.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'map)
(require 'ladybird-conn-test)
(require 'ladybird)

(defvar browse-url-secondary-browser-function)

(defvar ladybird-render-test-size nil
  "The size a test's stand-in for `ladybird--desired-size' returns.")

(defmacro ladybird-render-test-with-view (&rest body)
  "Run BODY in a page buffer with view 1 on a ready test connection.
`conn' is the connection and `buffer' the buffer."
  (declare (indent 0) (debug t))
  `(ladybird-test-with-env
     (let* ((ladybird--frame-function #'ladybird--on-frame)
            (ladybird--welcome-function #'ladybird--on-welcome)
            (ladybird--change-function #'ladybird--on-conn-change)
            (ladybird--viewport-function #'ladybird--hello-viewport)
            (ladybird-device-pixel-ratio 1.0)
            (ladybird--update-timer nil)
            (ladybird--saved-tracking nil)
            (ladybird--dragging nil)
            (ladybird--queued-prompts nil)
            (ladybird--last-buffer nil)
            (kill-ring nil)
            (kill-ring-yank-pointer nil)
            (interprogram-cut-function nil)
            (interprogram-paste-function nil)
            (conn (ladybird-test-connect))
            (buffer (ladybird--make-view-buffer conn 1 "mock://one")))
       (ignore conn)
       (unwind-protect
           (with-current-buffer buffer
             (setq ladybird-test-sent nil)
             ,@body)
         (when (timerp ladybird--update-timer)
           (cancel-timer ladybird--update-timer))
         (dolist (buffer (ladybird--buffers))
           (kill-buffer buffer))))))

(defmacro ladybird-render-test-messages (&rest body)
  "Run BODY and return the messages it showed, oldest first."
  (declare (indent 0) (debug t))
  (let ((messages (make-symbol "messages")))
    `(let ((,messages nil))
       (cl-letf (((symbol-function 'message)
                  (lambda (format &rest args)
                    (when format
                      (push (apply #'format format args) ,messages))
                    nil)))
         ,@body)
       (nreverse ,messages))))

(defmacro ladybird-render-test-prompting (&rest body)
  "Run BODY with prompts opened at once instead of from a timer."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ladybird--later) #'ladybird--call-prompt))
     ,@body))

(defun ladybird-render-test-state (&rest fields)
  "Return a state message for view 1 with the alist FIELDS overriding."
  `((type . "state") (view . 1) ,@fields (url . "mock://one")
    (title . "One") (loading . :false) (can_go_back . :false)
    (can_go_forward . :false) (zoom . 1.0)))

(defun ladybird-render-test-posn (x y &optional window area)
  "Return a mouse position at X, Y of the canvas shown in WINDOW.
AREA is a window area such as `mode-line'; the position is then off
the canvas."
  (list (or window (selected-window)) (or area 1) (cons x y) 0 nil 1
        (cons 0 0) (and (not area) ladybird--canvas) (cons x y)
        (cons 10 10)))

(defun ladybird-render-test-show (&optional dpr)
  "Show the current page buffer and give it a 40 x 30 frame at DPR."
  (set-window-buffer (selected-window) (current-buffer))
  (ladybird-test-receive ladybird--conn
                       (ladybird-test-frame 1 1 40 30 nil 0 t (or dpr 1.0)))
  (setq ladybird-test-sent nil))


;;; C1: buffers, canvas, sizing

(ert-deftest ladybird-render-test-buffer ()
  (ladybird-render-test-with-view
    (should (derived-mode-p 'ladybird-mode))
    (should buffer-read-only)
    (should (equal (buffer-string) " \n"))
    (should-not (get-text-property 1 'display))
    (should (eq (gethash 1 (ladybird--conn-views conn)) buffer))
    (should (equal (buffer-name) "*ladybird: mock://one*"))
    (should (memq #'ladybird--kill kill-buffer-hook))))

(ert-deftest ladybird-render-test-canvas ()
  (ladybird-render-test-with-view
    (ladybird-test-receive conn (ladybird-test-frame 1 1 4 3 nil 1 t))
    (let ((first ladybird--canvas))
      (should (equal (ladybird-test-sent)
                     '(((type . "frame_ack") (view . 1) (seq . 1)))))
      (should (eq (get-text-property 1 'display) first))
      (should (eq (plist-get (cdr first) :type) 'canvas))
      (should (symbolp (plist-get (cdr first) :id)))
      (should (equal (list (plist-get (cdr first) :data-width)
                           (plist-get (cdr first) :data-height))
                     '(4 3)))
      (should (equal ladybird--canvas-size '(4 . 3)))
      (should-not (plist-member (cdr first) :scale))
      (should-not (plist-member (cdr first) :transform-smoothing))
      (should (= (ladybird-module-canvas-pixel first 3 2)
                 (ladybird-test-pixel 3 2 1 4 3)))
      ;; A frame of the same size is painted into the same canvas.
      (ladybird-test-receive conn (ladybird-test-frame 2 1 4 3 '(1 1 2 1) 2))
      (should (eq ladybird--canvas first))
      (should (= (ladybird-module-canvas-pixel first 2 1)
                 (ladybird-test-pixel 2 1 2 4 3)))
      ;; A frame of another size gets a new canvas.
      (setq ladybird-test-sent nil)
      (ladybird-test-receive conn (ladybird-test-frame 3 1 6 5 nil 3 t 2.0))
      (should-not (eq ladybird--canvas first))
      (should (eq (get-text-property 1 'display) ladybird--canvas))
      (should (equal ladybird--canvas-size '(6 . 5)))
      (should (= ladybird--dpr 2.0))
      (should (= (plist-get (cdr ladybird--canvas) :scale) 0.5))
      (should-not (plist-member (cdr ladybird--canvas) :transform-smoothing))
      (should-not (eq (plist-get (cdr ladybird--canvas) :id)
                      (plist-get (cdr first) :id)))
      (should (= (ladybird-module-canvas-pixel ladybird--canvas 5 4)
                 (ladybird-test-pixel 5 4 3 6 5)))
      (should (equal (ladybird-test-sent)
                     '(((type . "frame_ack") (view . 1) (seq . 3)))))
      ;; Frames that cannot be used are counted.
      (ladybird-test-receive conn (ladybird-test-frame 4 1 9 9 '(0 0 1 1)))
      (should (= ladybird--dropped-frames 1)))))

(ert-deftest ladybird-render-test-frame-unknown-view ()
  (ladybird-render-test-with-view
    (ladybird-test-receive conn (ladybird-test-frame 5 77 4 3 nil 1 t))
    (should (equal (ladybird-test-sent)
                   '(((type . "frame_ack") (view . 77) (seq . 5)))))
    (should-not ladybird--canvas)))

(ert-deftest ladybird-render-test-desired-size ()
  (ladybird-render-test-with-view
    (should-not (ladybird--desired-size))
    (save-window-excursion
      (delete-other-windows)
      (let* ((one (selected-window))
             (two (split-window one nil t))
             (three (split-window one 4))
             (ladybird-device-pixel-ratio 2.0))
        (set-window-buffer one buffer)
        (should (equal (ladybird--desired-size)
                       (list (* 2 (window-body-width one t))
                             (* 2 (window-body-height one t))
                             2.0)))
        (set-window-buffer two buffer)
        (set-window-buffer three buffer)
        (should (/= (window-body-height one t) (window-body-height two t)))
        (should (equal (ladybird--desired-size)
                       (list (* 2 (min (window-body-width one t)
                                       (window-body-width two t)
                                       (window-body-width three t)))
                             (* 2 (min (window-body-height one t)
                                       (window-body-height two t)
                                       (window-body-height three t)))
                             2.0)))
        (let ((ladybird-device-pixel-ratio nil))
          (should (= (nth 2 (ladybird--desired-size))
                     (frame-scale-factor))))))))

(ert-deftest ladybird-render-test-sync-viewport ()
  (ladybird-render-test-with-view
    (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) t)))
     (save-window-excursion
      (delete-other-windows)
      (ladybird--sync-viewport buffer)
      (should (equal (ladybird-test-sent)
                     '(((type . "set_visibility") (view . 1) (visible)))))
      (setq ladybird-test-sent nil)
      (set-window-buffer (selected-window) buffer)
      (ladybird--update)
      (should (equal (ladybird-test-sent)
                     `(((type . "set_viewport") (view . 1)
                        (width . ,(window-body-width nil t))
                        (height . ,(window-body-height nil t))
                        (dpr . 1.0))
                       ((type . "set_visibility") (view . 1) (visible . t))
                       ((type . "set_focus") (view . 1) (focused . t)))))
      ;; Nothing changed: nothing is sent.
      (setq ladybird-test-sent nil)
      (ladybird--update)
      (should-not (ladybird-test-sent))
      ;; A smaller window is a new viewport.
      (split-window nil 5)
      (ladybird--update)
      (should (equal (ladybird-test-sent)
                     `(((type . "set_viewport") (view . 1)
                        (width . ,(window-body-width nil t))
                        (height . ,(window-body-height nil t))
                        (dpr . 1.0)))))
      (should (timerp (ladybird--schedule-update)))
      (should (eq (ladybird--schedule-update) ladybird--update-timer))))))

(ert-deftest ladybird-render-test-mini-window ()
  ;; A grown mini-window does not resize the page.
  (ladybird-render-test-with-view
    (let ((excess 0))
      (cl-letf (((symbol-function 'ladybird--mini-window-excess)
                 (lambda (_frame) excess))
                ((symbol-function 'ladybird--desired-size)
                 (lambda (&rest _) ladybird-render-test-size)))
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (let ((sizes (lambda ()
                         (mapcar (lambda (m) (list (alist-get 'width m)
                                                   (alist-get 'height m)))
                                 (ladybird-test-sent "set_viewport")))))
            (setq ladybird-render-test-size '(800 600 1.0))
            (ladybird--sync-viewport buffer)
            (should (equal (funcall sizes) '((800 600))))
            ;; The mini-window takes 40 pixels: nothing is sent.
            (setq excess 40
                  ladybird-render-test-size '(800 560 1.0))
            (ladybird--sync-viewport buffer)
            (setq ladybird-render-test-size '(800 580 1.0))
            (ladybird--sync-viewport buffer)
            (should (equal (funcall sizes) '((800 600))))
            (should (equal ladybird--requested-size '(800 600 1.0)))
            ;; It gives them back: still nothing.
            (setq excess 0
                  ladybird-render-test-size '(800 600 1.0))
            (ladybird--sync-viewport buffer)
            (should (equal (funcall sizes) '((800 600))))
            ;; A change larger than what it took, in width, or a gain in
            ;; height is a resize of the window.
            (setq excess 40
                  ladybird-render-test-size '(800 500 1.0))
            (ladybird--sync-viewport buffer)
            (setq ladybird-render-test-size '(700 480 1.0))
            (ladybird--sync-viewport buffer)
            (setq ladybird-render-test-size '(700 520 1.0))
            (ladybird--sync-viewport buffer)
            (should (equal (funcall sizes)
                           '((800 600) (800 500) (700 480) (700 520))))
            ;; So is any change while the mini-window has one line.
            (setq excess 0
                  ladybird-render-test-size '(700 519 1.0))
            (ladybird--sync-viewport buffer)
            (should (equal (car (last (funcall sizes))) '(700 519)))
            ;; Device pixels count at a higher ratio.
            (setq ladybird-render-test-size '(1400 1000 2.0))
            (ladybird--sync-viewport buffer)
            (setq excess 40
                  ladybird-render-test-size '(1400 920 2.0))
            (ladybird--sync-viewport buffer)
            (should (equal (car (last (funcall sizes))) '(1400 1000)))
            (setq ladybird-render-test-size '(1400 918 2.0))
            (ladybird--sync-viewport buffer)
            (should (equal (car (last (funcall sizes))) '(1400 918)))))))))

(ert-deftest ladybird-render-test-mini-window-excess ()
  (should (= (ladybird--mini-window-excess (selected-frame)) 0))
  (let ((mini (minibuffer-window)))
    (cl-letf (((symbol-function 'window-pixel-height)
               (lambda (&optional window)
                 (if (eq window mini) (* 3 (frame-char-height)) 100))))
      (should (= (ladybird--mini-window-excess (selected-frame))
                 (* 2 (frame-char-height)))))))

(ert-deftest ladybird-render-test-connect-command ()
  (ladybird-test-with-env
    (let* ((ladybird--frame-function #'ladybird--on-frame)
           (ladybird--welcome-function #'ladybird--on-welcome)
           (ladybird--change-function #'ladybird--on-conn-change)
           (ladybird-device-pixel-ratio 1.0)
           (ladybird--last-buffer nil)
           (messages nil)
           (conn nil))
      (save-window-excursion
        (unwind-protect
            (progn
              ;; The server has two pages: the first is shown.
              (setq conn (ladybird-connect ladybird-test-host))
              (ladybird-test-receive
               conn (ladybird-test-welcome '(((view . 4) (url . "mock://four"))
                                           ((view . 2) (url . "mock://two")))))
              (should (= (length (ladybird--buffers conn)) 2))
              (should (eq (window-buffer) (gethash 2 (ladybird--conn-views conn))))
              (should (eq ladybird--last-buffer (window-buffer)))
              ;; A connection that is ready shows it again.
              (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
              (ladybird-connect ladybird-test-host)
              (should (eq (window-buffer) (gethash 2 (ladybird--conn-views conn))))
              ;; A server without pages is only reported.
              (let ((inhibit-message nil))
                (setq messages
                      (ladybird-render-test-messages
                        (let ((empty (ladybird-connect '("empty" (:kind unix
                                                                :path "/e")))))
                          (ladybird-test-receive empty (ladybird-test-welcome)))))))
          (mapc #'kill-buffer (ladybird--buffers))))
      (should (equal messages
                     '("ladybird: connected to empty, which has no page open"))))))

(ert-deftest ladybird-render-test-state ()
  (ladybird-render-test-with-view
    (ladybird-test-receive conn (ladybird-render-test-state))
    (should (equal (buffer-name) "*ladybird: One*"))
    (should (equal (alist-get 'url ladybird--state) "mock://one"))
    (let ((ladybird-buffer-name-format "%h|%u|%t"))
      (ladybird-test-receive conn (ladybird-render-test-state '(title . "")))
      (should (equal (buffer-name) "test|mock://one|mock://one")))
    ;; Another buffer of the same title keeps the name it got.
    (let ((other (ladybird--make-view-buffer conn 2 "mock://two")))
      (ladybird-test-receive conn `((type . "state") (view . 2) (title . "One")
                                  (url . "mock://two")))
      (should (equal (buffer-name other) "*ladybird: One*"))
      (ladybird-test-receive conn (ladybird-render-test-state))
      (should (equal (buffer-name) "*ladybird: One*<2>"))
      (ladybird-test-receive conn (ladybird-render-test-state))
      (should (equal (buffer-name) "*ladybird: One*<2>")))))

(ert-deftest ladybird-render-test-header-line ()
  (ladybird-render-test-with-view
    (ladybird-test-receive
     conn (ladybird-render-test-state '(url . "mock://a%20b") '(loading . t)))
    (should (equal (substring-no-properties (ladybird--header-line))
                   " mock://a%%20b — One [loading]"))
    (should (equal (ladybird--mode-line-process) ":Loading"))
    ;; A long URL is cut so that the tags stay in the window.
    (ladybird-test-receive
     conn (ladybird-render-test-state
           `(url . ,(concat "mock://" (make-string 500 ?a))) '(loading . t)))
    (let ((header (ladybird--header-line)))
      (should (string-prefix-p " mock://aaa" header))
      (should (string-suffix-p " [loading]" header))
      (should (<= (string-width header) (window-width))))
    ;; A long title cannot push the URL's scheme and host out of the
    ;; window, nor stand where the URL is read.
    (ladybird-test-receive
     conn (ladybird-render-test-state
           '(url . "https://evil.example/login?next=/a/long/path/of/the/page")
           `(title . ,(concat "https://bank.example/ " (make-string 300 ?x)))
           '(loading . t)))
    (let ((header (substring-no-properties (ladybird--header-line))))
      (should (string-prefix-p " https://evil.example" header))
      (should (string-match-p " — https://bank.example/ x+…? \\[loading\\]\\'"
                              header))
      (should (<= (string-width header) (window-width))))
    ;; A title with line breaks stays on the line.
    (ladybird-test-receive
     conn (ladybird-render-test-state '(title . "two\nlines\there")))
    (should (equal (substring-no-properties (ladybird--header-line))
                   " mock://one — two lines here"))
    (should (equal (ladybird--url-origin "https://user@host.example:8080/p?q#f")
                   "https://user@host.example:8080"))
    (should (equal (ladybird--url-origin "about:blank") "about:"))
    (should (equal (ladybird--url-origin "no scheme") "no scheme"))
    (ladybird-test-receive
     conn (ladybird-render-test-state '(url . "mock://a%20b") '(loading . t)))
    (ladybird-test-receive conn (ladybird-render-test-state))
    (should (equal (ladybird--mode-line-process) ""))
    (ladybird-insert-mode 1)
    (should (equal (substring-no-properties (ladybird--mode-line-process))
                   ":Insert"))
    (ladybird-test-receive conn '((type . "replaced")))
    (should (string-suffix-p " [detached]" (ladybird--header-line)))
    (ladybird--connect ladybird-test-host #'ignore)
    (should (string-suffix-p " [connecting]" (ladybird--header-line)))
    (ladybird-test-receive conn (ladybird-test-welcome))
    (ladybird--drop conn)
    (should (string-match-p " \\[reconnecting in [01]s\\]\\'"
                            (ladybird--header-line)))))

(ert-deftest ladybird-render-test-welcome-views ()
  (ladybird-render-test-with-view
    (ladybird-test-receive conn (ladybird-test-frame 1 1 4 3 nil 1 t))
    (ladybird-test-receive conn (ladybird-render-test-state '(url . "mock://now")))
    (let ((canvas ladybird--canvas))
      (ladybird--drop conn)
      (should (eq (ladybird--conn-state conn) 'redialing))
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (setq ladybird-test-sent nil)
      ;; The server lists view 7 and no longer has view 1.
      (ladybird-test-receive
       conn (ladybird-test-welcome
             '(((view . 7) (url . "mock://seven") (title . "Seven")
                (loading . :false) (width . 800) (height . 600) (dpr . 1.0)))))
      (let ((seven (gethash 7 (ladybird--conn-views conn))))
        (should (buffer-live-p seven))
        (should-not (eq seven buffer))
        (should (equal (buffer-name seven) "*ladybird: Seven*"))
        (should (eq (buffer-local-value 'ladybird--conn seven) conn))
        (should (= (length (ladybird--buffers conn)) 2)))
      (should-not ladybird--view)
      (should-not (gethash 1 (ladybird--conn-views conn)))
      (let ((create (car (ladybird-test-sent "create_view"))))
        (should (equal (alist-get 'url create) "mock://now"))
        (should (integerp (alist-get 'width create)))
        (should (= (alist-get 'dpr create) 1.0)))
      (should (= (length (ladybird-test-sent "create_view")) 1))
      ;; An undisplayed view is reported hidden.
      (should (equal (ladybird-test-sent "set_visibility")
                     '(((type . "set_visibility") (view . 7) (visible)))))
      (ladybird-test-receive conn '((type . "view_created") (view . 8)
                                  (url . "mock://now") (title . "Now")
                                  (width . 80) (height . 25) (dpr . 1.0)))
      (should (= ladybird--view 8))
      (should (eq (gethash 8 (ladybird--conn-views conn)) buffer))
      (should (equal (buffer-name) "*ladybird: Now*"))
      ;; The canvas shows the new view's frames.
      (ladybird-test-receive conn (ladybird-test-frame 1 8 4 3 nil 5 t))
      (should (eq ladybird--canvas canvas))
      (should (= (ladybird-module-canvas-pixel canvas 1 1)
                 (ladybird-test-pixel 1 1 5 4 3)))
      ;; A second welcome that lists both views makes no buffer.
      (ladybird--drop conn)
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (setq ladybird-test-sent nil)
      (ladybird-test-receive
       conn (ladybird-test-welcome '(((view . 7) (url . "mock://seven"))
                                   ((view . 8) (url . "mock://now")))))
      (should (= (length (ladybird--buffers conn)) 2))
      (should-not (ladybird-test-sent "create_view"))
      (should (= ladybird--view 8)))))

(ert-deftest ladybird-render-test-view-created-order ()
  (ladybird-render-test-with-view
    (let ((second (ladybird--make-view-buffer conn nil "mock://2"))
          (third (ladybird--make-view-buffer conn nil "mock://3")))
      (with-current-buffer second (ladybird--create-view))
      (with-current-buffer third
        (ladybird--create-view)
        ;; Asking twice sends once.
        (ladybird--create-view))
      (should (equal (mapcar (lambda (m) (alist-get 'url m))
                             (ladybird-test-sent "create_view"))
                     '("mock://2" "mock://3")))
      ;; The view of a buffer killed meanwhile is closed.
      (kill-buffer second)
      (setq ladybird-test-sent nil)
      (ladybird-test-receive conn '((type . "view_created") (view . 2)))
      (should (equal (ladybird-test-sent)
                     '(((type . "close_view") (view . 2)))))
      (ladybird-test-receive conn '((type . "view_created") (view . 3)
                                  (url . "mock://3") (title . "Three")))
      (should (= (buffer-local-value 'ladybird--view third) 3))
      (should (equal (buffer-name third) "*ladybird: Three*")))))

(ert-deftest ladybird-render-test-kill ()
  (ladybird-render-test-with-view
    (let ((second (ladybird--make-view-buffer conn 2 "mock://2"))
          (process (ladybird--conn-process conn)))
      (kill-buffer second)
      (should (equal (ladybird-test-sent)
                     '(((type . "close_view") (view . 2)))))
      (should-not (gethash 2 (ladybird--conn-views conn)))
      (should (process-live-p process))
      ;; The last buffer takes the connection with it.  A view that is
      ;; kept is hidden and loses the focus.
      (setq ladybird-test-sent nil)
      (let ((ladybird-keep-view-on-kill t))
        (kill-buffer buffer))
      (should (equal (ladybird-test-sent)
                     '(((type . "set_visibility") (view . 1) (visible))
                       ((type . "set_focus") (view . 1) (focused)))))
      (should-not (process-live-p process))
      (should-not ladybird--conns))))

(ert-deftest ladybird-render-test-close ()
  (ladybird-render-test-with-view
    (let ((ladybird-keep-view-on-kill t))
      (ladybird-close))
    (should-not (buffer-live-p buffer))
    (should (equal (ladybird-test-sent)
                   '(((type . "close_view") (view . 1)))))))

(ert-deftest ladybird-render-test-view-closed ()
  (ladybird-render-test-with-view
    (let ((messages (ladybird-render-test-messages
                      (ladybird-test-receive
                       conn '((type . "crashed") (view . 1) (reason . "oom")))
                      (should (buffer-live-p buffer))
                      (ladybird-test-receive
                       conn '((type . "view_closed") (view . 1)
                              (reason . "closed"))))))
      (should (equal messages
                     '("ladybird: the page in *ladybird: mock://one* crashed: oom"
                       "ladybird: *ladybird: mock://one* closed (closed)"))))
    (should-not (buffer-live-p buffer))
    (should-not (ladybird-test-sent "close_view"))))

(ert-deftest ladybird-render-test-command ()
  (ladybird-test-with-env
    (let* ((ladybird--frame-function #'ladybird--on-frame)
           (ladybird--welcome-function #'ladybird--on-welcome)
           (ladybird--change-function #'ladybird--on-conn-change)
           (ladybird--viewport-function #'ladybird--hello-viewport)
           (ladybird-device-pixel-ratio 2.0)
           (ladybird-program "ladybird-no-such-program")
           (ladybird-hosts '(("test" . "/nonexistent/ladybird")))
           (ladybird-default-host nil)
           buffer)
      (save-window-excursion
        (unwind-protect
            (progn
              (setq buffer (ladybird "mock://x"))
              (should (eq (window-buffer) buffer))
              (with-current-buffer buffer
                (should (equal (alist-get 'viewport
                                          (car (ladybird-test-sent "hello")))
                               `((width . ,(* 2 (window-body-width nil t)))
                                 (height . ,(* 2 (window-body-height nil t)))
                                 (dpr . 2.0))))
                (should (string-suffix-p " [connecting]" (ladybird--header-line)))
                (ladybird-test-receive ladybird--conn (ladybird-test-welcome))
                (should (equal (map-delete
                                (copy-alist (car (ladybird-test-sent "create_view")))
                                'request)
                               `((type . "create_view") (url . "mock://x")
                                 (width . ,(* 2 (window-body-width nil t)))
                                 (height . ,(* 2 (window-body-height nil t)))
                                 (dpr . 2.0))))
                (should (integerp (alist-get 'request
                                             (car (ladybird-test-sent
                                                   "create_view")))))
                (should (string-suffix-p " [opening]" (ladybird--header-line)))
                (ladybird-test-receive
                 ladybird--conn '((type . "view_created") (view . 1)
                                (url . "mock://x") (title . "Mock: mock://x")))
                (should (= ladybird--view 1))
                (should (equal (buffer-name) "*ladybird: Mock: mock://x*"))
                ;; The size asked for at creation is not asked for again.
                (should-not (ladybird-test-sent "set_viewport"))
                (should (equal ladybird--host
                               '("test" (:kind unix :path "/nonexistent/ladybird"))))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))
      (should-error (ladybird "mock://x" "nowhere") :type 'user-error)
      (let ((ladybird-hosts nil))
        (should-error (ladybird "mock://x") :type 'user-error)))))

(ert-deftest ladybird-render-test-reconnect-command ()
  (ladybird-render-test-with-view
    (let ((ladybird-reconnect nil))
      (ladybird--drop conn)
      (should (eq (ladybird--conn-state conn) 'closed))
      (ladybird-reconnect)
      (should (eq (ladybird--conn-state conn) 'hello))
      (ladybird-test-receive conn (ladybird-test-welcome))
      (should (= (length (ladybird-test-sent "create_view")) 1)))))

(ert-deftest ladybird-render-test-background ()
  (ladybird-render-test-with-view
    (ladybird-test-receive conn '((type . "background_color") (view . 1)
                                (rgb . "#102030")))
    (should (equal (alist-get 'default face-remapping-alist)
                   '((:background "#102030") default)))
    (ladybird-test-receive conn '((type . "background_color") (view . 1)
                                (rgb . "#ffffff")))
    (should (equal (alist-get 'default face-remapping-alist)
                   '((:background "#ffffff") default)))))


;;; C2: mouse and wheel

(ert-deftest ladybird-render-test-mouse-click ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show 2.0)
    (ladybird-mouse-down `(down-mouse-1 ,(ladybird-render-test-posn 5 7)))
    (ladybird-mouse-up `(mouse-1 ,(ladybird-render-test-posn 5 7)))
    (should (equal (ladybird-test-sent)
                   '(((type . "mouse") (view . 1) (kind . "down")
                      (x . 10) (y . 14) (button . "left") (buttons . ["left"])
                      (modifiers . 0) (clicks . 1))
                     ((type . "mouse") (view . 1) (kind . "up")
                      (x . 10) (y . 14) (button . "left") (buttons . [])
                      (modifiers . 0) (clicks . 1)))))
    (should-not ladybird--buttons)))

(ert-deftest ladybird-render-test-mouse-double-and-modifiers ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (ladybird-mouse-down `(double-down-mouse-1 ,(ladybird-render-test-posn 3 4) 2))
    (ladybird-mouse-up `(double-mouse-1 ,(ladybird-render-test-posn 3 4) 2))
    (should (equal (mapcar (lambda (m) (alist-get 'clicks m)) (ladybird-test-sent))
                   '(2 2)))
    (setq ladybird-test-sent nil)
    (ladybird-mouse-down `(C-S-down-mouse-3 ,(ladybird-render-test-posn 1 2)))
    (let ((down (car (ladybird-test-sent))))
      (should (equal (alist-get 'button down) "right"))
      (should (equal (alist-get 'modifiers down) 3))
      (should (equal (alist-get 'clicks down) 1)))
    ;; A second button joins the held ones.
    (ladybird-mouse-down `(down-mouse-1 ,(ladybird-render-test-posn 1 2)))
    (should (equal (alist-get 'buttons (cadr (ladybird-test-sent)))
                   ["left" "right"]))))

(ert-deftest ladybird-render-test-mouse-drag ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (let ((ladybird-hover-interval 0))
      (ladybird-mouse-down `(down-mouse-1 ,(ladybird-render-test-posn 5 5)))
      (should (eq track-mouse 'dragging))
      (ladybird-mouse-move `(mouse-movement ,(ladybird-render-test-posn 8 9)))
      ;; Off the canvas the position is clamped while a button is held.
      (ladybird-mouse-move
       `(mouse-movement ,(list (selected-window) 1 (cons 200 -5) 0)))
      (ladybird-mouse-up
       `(drag-mouse-1 ,(ladybird-render-test-posn 5 5)
                      ,(list (selected-window) 'mode-line (cons 12 0) 0)))
      (should (equal (mapcar (lambda (m)
                               (list (alist-get 'kind m) (alist-get 'x m)
                                     (alist-get 'y m) (alist-get 'buttons m)))
                             (ladybird-test-sent))
                     '(("down" 5 5 ["left"])
                       ("move" 8 9 ["left"])
                       ("move" 39 0 ["left"])
                       ("up" 39 0 [])))))
    (setq track-mouse nil)))

(ert-deftest ladybird-render-test-mouse-drag-release ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (let ((ladybird-hover-interval 60))
      (ladybird-mouse-down `(down-mouse-1 ,(ladybird-render-test-posn 5 5)))
      (ladybird-mouse-move `(mouse-movement ,(ladybird-render-test-posn 8 9)))
      ;; This movement is held back and the release comes before its timer.
      (ladybird-mouse-move `(mouse-movement ,(ladybird-render-test-posn 20 9)))
      (ladybird-mouse-up `(drag-mouse-1 ,(ladybird-render-test-posn 5 5)
                                      ,(ladybird-render-test-posn 30 9)))
      (should (equal (mapcar (lambda (m)
                               (list (alist-get 'kind m) (alist-get 'x m)
                                     (alist-get 'y m) (alist-get 'buttons m)))
                             (ladybird-test-sent))
                     '(("down" 5 5 ["left"])
                       ("move" 8 9 ["left"])
                       ("move" 30 9 ["left"])
                       ("up" 30 9 []))))
      (should-not ladybird--move-timer))
    (setq track-mouse nil)))

(ert-deftest ladybird-render-test-mouse-outside ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    ;; A press off the canvas is not sent, nor is its release.
    (ladybird-mouse-down
     `(down-mouse-1 ,(list (selected-window) 2 (cons 300 300) 0)))
    (ladybird-mouse-up `(mouse-1 ,(list (selected-window) 2 (cons 300 300) 0)))
    (should-not (ladybird-test-sent))
    (ladybird-mouse-down `(down-mouse-5 ,(ladybird-render-test-posn 1 1)))
    (should-not (ladybird-test-sent))))

(ert-deftest ladybird-render-test-mouse-move ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (let ((ladybird-hover-interval 60))
      (ladybird-mouse-move `(mouse-movement ,(ladybird-render-test-posn 1 1)))
      (ladybird-mouse-move `(mouse-movement ,(ladybird-render-test-posn 2 2)))
      (ladybird-mouse-move `(mouse-movement ,(ladybird-render-test-posn 3 3)))
      (should (equal (ladybird-test-sent)
                     '(((type . "mouse") (view . 1) (kind . "move")
                        (x . 1) (y . 1) (buttons . []) (modifiers . 0)))))
      ;; The movement held back is sent by the timer, the last one only.
      (should (timerp ladybird--move-timer))
      (setq ladybird-test-sent nil)
      (ladybird-test-run-timer ladybird--move-timer)
      (should (equal (mapcar (lambda (m) (alist-get 'x m)) (ladybird-test-sent))
                     '(3)))
      (should-not ladybird--move-timer))
    ;; Leaving the canvas is reported once.
    (let ((ladybird-hover-interval 0)
          (off `(mouse-movement
                 ,(list (selected-window) 'mode-line (cons 5 0) 0))))
      (setq ladybird-test-sent nil)
      (ladybird-mouse-move off)
      (ladybird-mouse-move off)
      (should (equal (ladybird-test-sent)
                     '(((type . "mouse") (view . 1) (kind . "leave")))))
      ;; So is moving on to a window that shows another buffer.
      (ladybird-mouse-move `(mouse-movement ,(ladybird-render-test-posn 1 1)))
      (setq ladybird-test-sent nil)
      (with-temp-buffer
        (save-window-excursion
          (set-window-buffer (selected-window) (current-buffer))
          (ladybird-mouse-move
           `(mouse-movement ,(list (selected-window) 1 (cons 1 1) 0)))))
      (should (equal (ladybird-test-sent)
                     '(((type . "mouse") (view . 1) (kind . "leave"))))))))

(ert-deftest ladybird-render-test-wheel ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show 2.0)
    (ladybird-wheel `(wheel-up ,(ladybird-render-test-posn 5 6) 1 1 (0.0 . 24.0)))
    (should (equal (ladybird-test-sent)
                   '(((type . "mouse") (view . 1) (kind . "wheel")
                      (x . 10) (y . 12) (dx . 0) (dy . -48) (modifiers . 0)
                      (precise . t)))))
    (setq ladybird-test-sent nil)
    (ladybird-wheel `(C-wheel-down ,(ladybird-render-test-posn 5 6) 1 2 nil))
    (let ((wheel (car (ladybird-test-sent))))
      (should (= (alist-get 'dy wheel) (* 2 2 (default-line-height))))
      (should (= (alist-get 'modifiers wheel) 2))
      (should-not (alist-get 'precise wheel)))
    ;; A wheel event off the canvas scrolls at its middle.
    (setq ladybird-test-sent nil)
    (ladybird-wheel `(wheel-down ,(list (selected-window) 2 (cons 0 0) 0) 1 1
                               (0.0 . -10.0)))
    (let ((wheel (car (ladybird-test-sent))))
      (should (equal (list (alist-get 'x wheel) (alist-get 'y wheel)
                           (alist-get 'dy wheel))
                     '(20 15 20))))))

(ert-deftest ladybird-render-test-scroll-commands ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show 2.0)
    (let ((ladybird-scroll-step 10))
      (ladybird-scroll-down-line)
      (ladybird-scroll-up-line 2)
      (ladybird-scroll-right)
      (ladybird-scroll-left)
      (ladybird-scroll-down-page)
      (ladybird-scroll-up-page)
      (ladybird-scroll-top)
      (ladybird-scroll-bottom))
    (let ((page (* 2 (- (window-body-height nil t) (frame-char-height)))))
      (should (equal (mapcar (lambda (m)
                               (list (alist-get 'x m) (alist-get 'y m)
                                     (alist-get 'dx m) (alist-get 'dy m)))
                             (ladybird-test-sent))
                     `((20 15 0 20) (20 15 0 -40) (20 15 20 0) (20 15 -20 0)
                       (20 15 0 ,page) (20 15 0 ,(- page))
                       (20 15 0 -2000000) (20 15 0 2000000)))))
    (should (eq (key-binding "n") #'ladybird-scroll-down-line))
    (should (eq (key-binding " ") #'ladybird-scroll-down-page))
    (should (eq (key-binding (kbd "C-v")) #'ladybird-scroll-down-page))
    (should (eq (key-binding (kbd "M-<")) #'ladybird-scroll-top))
    (should (eq (key-binding [down-mouse-1]) #'ladybird-mouse-down))
    (should (eq (key-binding [C-M-S-s-triple-drag-mouse-3]) #'ladybird-mouse-up))
    (should (eq (key-binding [M-wheel-left]) #'ladybird-wheel))
    (should (eq (key-binding [mouse-movement]) #'ladybird-mouse-move))))

(ert-deftest ladybird-render-test-tracking ()
  (ladybird-render-test-with-view
    (save-window-excursion
      (let ((track-mouse nil)
            (mouse-fine-grained-tracking nil))
        (set-window-buffer (selected-window) buffer)
        (ladybird--sync-tracking)
        (should (eq track-mouse t))
        (should (eq mouse-fine-grained-tracking t))
        (with-temp-buffer
          (set-window-buffer (selected-window) (current-buffer))
          (ladybird--sync-tracking))
        (should-not track-mouse)
        (should-not mouse-fine-grained-tracking)
        (let ((ladybird-track-hover nil))
          (set-window-buffer (selected-window) buffer)
          (ladybird--sync-tracking)
          (should-not track-mouse))))))

(ert-deftest ladybird-render-test-leave ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (ladybird-mouse-down `(down-mouse-1 ,(ladybird-render-test-posn 5 5)))
    (setq ladybird-test-sent nil)
    (ladybird--leave)
    (ladybird--leave)
    (should (equal (ladybird-test-sent)
                   '(((type . "mouse") (view . 1) (kind . "leave")))))
    (should-not ladybird--buttons)
    (setq track-mouse nil)))


;;; C3: keys, insert mode, paste

(ert-deftest ladybird-render-test-key-bindings ()
  (ladybird-render-test-with-view
    (should (eq (key-binding "a") #'ladybird-self-insert-hint))
    (should (eq (key-binding "é") #'ladybird-self-insert-hint))
    (should-error (ladybird-self-insert-hint) :type 'user-error)
    (should (eq (key-binding "i") #'ladybird-insert-mode))
    (should (eq (key-binding (kbd "RET")) #'ladybird-insert-mode))
    (should (eq (key-binding (kbd "C-y")) #'ladybird-yank))
    (should (eq (key-binding (kbd "M-w")) #'ladybird-copy-selection))
    (should (eq (key-binding (kbd "C-x h")) #'ladybird-select-all))
    (should (eq (key-binding "q") #'ladybird-quit))
    (should (eq (key-binding "Q") #'ladybird-close))
    (ladybird-insert-mode 1)
    (dolist (key '("a" "n" "q" "Q" "é" "!" "SPC" "RET" "TAB" "DEL" "<return>"
                   "<backspace>" "<escape>" "<left>" "C-<left>" "C-M-S-s-<f5>"
                   "S-<return>" "<kp-7>" "<backtab>" "M-<left>" "<home>"
                   "<delete>" "S-<left>" "C-<delete>"))
      (ert-info ((format "key %s" key))
        (should (eq (key-binding (kbd key)) #'ladybird-insert-key))))
    (dolist (key '("C-a" "C-e" "C-k" "C-d" "M-b" "M-f" "M-d" "M-DEL"
                   "M-<backspace>" "C-<backspace>" "C-z" "C-/" "C-_" "C-?"))
      (ert-info ((format "key %s" key))
        (should (eq (key-binding (kbd key)) #'ladybird-insert-edit-key))))
    ;; Editing keys outside the option stay with Emacs.
    (should-not (eq (key-binding (kbd "C-f")) #'ladybird-insert-edit-key))
    (should (eq (key-binding (kbd "C-x C-f")) #'find-file))
    (should (eq (key-binding (kbd "M-x")) #'execute-extended-command))
    (should (eq (key-binding (kbd "C-g")) #'keyboard-quit))
    (should (eq (key-binding (kbd "C-h k")) #'describe-key))
    (should (eq (key-binding (kbd "C-u")) #'universal-argument))
    (should (eq (key-binding (kbd "C-l")) #'recenter-top-bottom))
    (should (eq (key-binding (kbd "C-y")) #'ladybird-yank))
    (should (eq (key-binding (kbd "M-w")) #'ladybird-copy-selection))
    (should (eq (key-binding (kbd "C-c C-c")) #'ladybird-insert-mode))
    (should (eq (key-binding [xterm-paste]) #'ladybird-xterm-paste))
    (should (eq (key-binding [down-mouse-1]) #'ladybird-mouse-down))
    (unwind-protect
        (let ((ladybird-insert-mode-forward-keys nil))
          (ladybird--rebuild-insert-map)
          (should (eq (key-binding (kbd "C-a")) #'move-beginning-of-line))
          (should (eq (key-binding (kbd "M-f")) #'forward-word))
          (should (eq (key-binding "a") #'ladybird-insert-key)))
      (ladybird--rebuild-insert-map))
    (should (eq (key-binding (kbd "C-a")) #'ladybird-insert-edit-key))
    (ladybird-insert-mode -1)
    (should (eq (key-binding "a") #'ladybird-self-insert-hint))))

(ert-deftest ladybird-render-test-send-key ()
  (ladybird-render-test-with-view
    (ladybird--send-key '("Return" 10 0))
    (should (equal (ladybird-test-sent)
                   '(((type . "key") (view . 1) (kind . "down") (key . "Return")
                      (code_point . 10) (modifiers . 0) (repeat))
                     ((type . "key") (view . 1) (kind . "up") (key . "Return")
                      (code_point . 10) (modifiers . 0)))))
    (setq ladybird-test-sent nil)
    (ladybird--send-key '(text "héllo"))
    (should (equal (ladybird-test-sent)
                   '(((type . "text") (view . 1) (text . "héllo")))))))

(ert-deftest ladybird-render-test-insert-key ()
  (ladybird-render-test-with-view
    (dolist (last-command-event (list ?H ?! ?\r ?é 'C-left 'lshift))
      (ladybird-insert-key))
    (should (equal (mapcar (lambda (m)
                             (or (alist-get 'text m)
                                 (list (alist-get 'kind m) (alist-get 'key m)
                                       (alist-get 'code_point m)
                                       (alist-get 'modifiers m))))
                           (ladybird-test-sent))
                   '(("down" "H" 72 1) ("up" "H" 72 1)
                     ("down" "ExclamationPoint" 33 0)
                     ("up" "ExclamationPoint" 33 0)
                     ("down" "Return" 10 0) ("up" "Return" 10 0)
                     "é"
                     ("down" "Left" 0 2) ("up" "Left" 0 2))))))

(defun ladybird-render-test-edit-keys (&rest keys)
  "Run `ladybird-insert-edit-key' for each of KEYS; return what was sent.
A key press is (KEY MODIFIERS), an edit message its operation."
  (setq ladybird-test-sent nil)
  (dolist (key keys)
    (let ((last-command-event (aref (key-parse key) 0)))
      (ladybird-insert-edit-key)))
  (delq nil (mapcar (lambda (m)
                      (pcase (alist-get 'type m)
                        ("edit" (alist-get 'op m))
                        ("key" (and (equal (alist-get 'kind m) "down")
                                    (list (alist-get 'key m)
                                          (alist-get 'modifiers m))))))
                    (ladybird-test-sent))))

(ert-deftest ladybird-render-test-edit-keys ()
  (ladybird-render-test-with-view
    (should (eq (ladybird--platform) 'other))
    (should (equal (ladybird-render-test-edit-keys
                    "C-a" "C-e" "C-d" "C-k" "M-b" "M-f" "M-d" "M-DEL"
                    "C-<backspace>" "C-z" "C-/" "C-?")
                   '(("Home" 0) ("End" 0) ("Delete" 0) ("End" 1) ("Delete" 0)
                     ("Left" 2) ("Right" 2) ("Delete" 2) ("Backspace" 2)
                     ("Backspace" 2) "undo" "undo" "redo")))
    ;; Every press is released.
    (ladybird-render-test-edit-keys "C-k")
    (should (equal (mapcar (lambda (m) (alist-get 'kind m)) (ladybird-test-sent))
                   '("down" "up" "down" "up")))
    ;; A server on macOS moves and deletes by words with the alt key.
    (setf (ladybird--conn-server-info conn)
          '((host . ((hostname . "mac") (platform . "macos")))))
    (should (eq (ladybird--platform) 'macos))
    (should (equal (ladybird-render-test-edit-keys
                    "C-a" "C-e" "C-k" "M-b" "M-f" "M-d" "M-DEL" "M-<backspace>"
                    "C-<backspace>" "C-z")
                   '(("Home" 0) ("End" 0) ("End" 1) ("Delete" 0) ("Left" 4)
                     ("Right" 4) ("Delete" 4) ("Backspace" 4) ("Backspace" 4)
                     ("Backspace" 4) "undo")))
    ;; A key without a translation goes as it is.
    (should (equal (ladybird-render-test-edit-keys "C-o") '(("O" 2))))))

(ert-deftest ladybird-render-test-paste ()
  (ladybird-render-test-with-view
    (kill-new (propertize "pasted ✓" 'face 'bold))
    (ladybird-yank)
    (ladybird-xterm-paste '(xterm-paste "from the terminal"))
    (ladybird-select-all)
    (should (equal (ladybird-test-sent)
                   '(((type . "paste") (view . 1) (text . "pasted ✓"))
                     ((type . "paste") (view . 1) (text . "from the terminal"))
                     ((type . "edit") (view . 1) (op . "select_all")))))))

(ert-deftest ladybird-render-test-copy-selection ()
  (ladybird-render-test-with-view
    (ladybird-copy-selection)
    (let ((request (car (ladybird-test-sent))))
      (should (equal (alist-get 'type request) "request_selection"))
      (should (equal (alist-get 'view request) 1))
      (ladybird-test-receive conn `((type . "selection") (view . 1)
                                  (request . ,(alist-get 'request request))
                                  (text . "chosen")))
      (should (equal (current-kill 0) "chosen")))
    ;; A selection nobody asked for is kept too.
    (ladybird-test-receive conn '((type . "selection") (view . 1) (request . 99)
                                (text . "unasked")))
    (should (equal (current-kill 0) "unasked"))))


;;; C4: page events, dialogs and pickers

(defun ladybird-render-test-request (type &rest fields)
  "Return a request message of TYPE with id 5 for view 1 and FIELDS."
  `((type . ,type) (view . 1) (id . 5) ,@fields))

(ert-deftest ladybird-render-test-alert ()
  (ladybird-render-test-with-view
    (let* ((alert (ladybird-render-test-request
                   "dialog" '(kind . "alert") '(message . "Hi")
                   '(origin . "https://example.org")))
           (messages (ladybird-render-test-messages
                       (ladybird-test-receive conn alert))))
      (should (equal messages '("https://example.org: Hi")))
      (should (equal (ladybird-test-sent)
                     '(((type . "dialog_closed") (view . 1) (id . 5)
                        (accepted . t)))))
      (setq ladybird-test-sent nil)
      (let ((ladybird-alert-style 'prompt)
            (prompt nil))
        (ladybird-render-test-prompting
          (cl-letf (((symbol-function 'read-key)
                     (lambda (text) (setq prompt text) ?x)))
            (ladybird-test-receive conn alert)))
        (should (string-prefix-p "https://example.org: Hi" prompt))
        (should (equal (ladybird-test-sent)
                       '(((type . "dialog_closed") (view . 1) (id . 5)
                          (accepted . t)))))))))

(ert-deftest ladybird-render-test-confirm ()
  (ladybird-render-test-with-view
    (ladybird-render-test-prompting
      (dolist (case '(("confirm" t t) ("confirm" nil nil)
                      ("beforeunload" t t) ("confirm" quit nil)))
        (pcase-let ((`(,kind ,answer ,accepted) case))
          (setq ladybird-test-sent nil)
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (_prompt)
                       (if (eq answer 'quit) (signal 'quit nil) answer))))
            (ladybird-test-receive
             conn (ladybird-render-test-request "dialog" `(kind . ,kind)
                                              '(message . "Sure?"))))
          (should (equal (ladybird-test-sent)
                         `(((type . "dialog_closed") (view . 1) (id . 5)
                            (accepted . ,accepted))))))))))

(ert-deftest ladybird-render-test-prompt ()
  (ladybird-render-test-with-view
    (ladybird-render-test-prompting
      (let ((seen nil)
            (prompt (ladybird-render-test-request
                     "dialog" '(kind . "prompt") '(message . "Name")
                     '(default . "nobody"))))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (prompt &optional initial &rest _)
                     (setq seen (list prompt initial))
                     "Ada ✓")))
          (ladybird-test-receive conn prompt))
        (should (equal seen '("*ladybird: mock://one*: Name: " "nobody")))
        (should (equal (ladybird-test-sent)
                       '(((type . "dialog_closed") (view . 1) (id . 5)
                          (accepted . t) (text . "Ada ✓")))))
        (setq ladybird-test-sent nil)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) (signal 'quit nil))))
          (ladybird-test-receive conn prompt))
        (should (equal (ladybird-test-sent)
                       '(((type . "dialog_closed") (view . 1) (id . 5)
                          (accepted)))))))))

(ert-deftest ladybird-render-test-dialog-is-deferred ()
  ;; A prompt opens from a timer, not from the process filter.
  (ladybird-render-test-with-view
    (progn
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_) (ert-fail "prompted from the filter"))))
        (ladybird-test-receive
         conn (ladybird-render-test-request "dialog" '(kind . "confirm"))
         (ladybird-render-test-state '(title . "Later"))))
      (should-not (ladybird-test-sent "dialog_closed"))
      ;; The record after the dialog was handled.
      (should (equal (buffer-name) "*ladybird: Later*"))
      (let ((timer (seq-find (lambda (timer)
                               (eq (timer--function timer) #'ladybird--run-prompt))
                             timer-list)))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
          (ladybird-test-run-timer timer)))
      (should (equal (ladybird-test-sent "dialog_closed")
                     '(((type . "dialog_closed") (view . 1) (id . 5)
                        (accepted . t))))))))

(defconst ladybird-render-test-select
  (ladybird-render-test-request
   "select" '(x . 1) '(y . 2) '(min_width . 100)
   '(items . [((id . 1) (label . "One"))
              ((id . 2) (label . "Two") (selected . t))
              ((separator . t))
              ((id . 3) (label . "Three") (disabled . t))
              ((id . 4) (label . "Four") (group . "More"))
              ((id . 5) (label . "One"))]))
  "A select request.")

(ert-deftest ladybird-render-test-select ()
  (ladybird-render-test-with-view
    (should (equal (ladybird--select-candidates
                    (alist-get 'items ladybird-render-test-select))
                   '(("One" 1 nil) ("Two" 2 t) ("More / Four" 4 nil)
                     ("One (2)" 5 nil))))
    (ladybird-render-test-prompting
      (let ((seen nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection &optional _predicate require
                                   _initial _history default &rest _)
                     (setq seen (list prompt (all-completions "" collection)
                                      require default))
                     "More / Four")))
          (ladybird-test-receive conn ladybird-render-test-select))
        (should (equal seen '("Select (default Two): "
                              ("One" "Two" "More / Four" "One (2)") t "Two")))
        (should (equal (ladybird-test-sent)
                       '(((type . "select_closed") (view . 1) (id . 5)
                          (item . 4)))))
        (setq ladybird-test-sent nil)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil))))
          (ladybird-test-receive conn ladybird-render-test-select))
        (should (equal (ladybird-test-sent)
                       '(((type . "select_closed") (view . 1) (id . 5)
                          (item)))))))))

(ert-deftest ladybird-render-test-file-picker ()
  (ladybird-render-test-with-view
    (ladybird-render-test-prompting
      (let ((files '("/tmp/a.txt" "~/b.txt"))
            (more '(t nil)))
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _) (pop files)))
                  ((symbol-function 'y-or-n-p) (lambda (_) (pop more))))
          (ladybird-test-receive
           conn (ladybird-render-test-request "file_picker" '(multiple . :false)))
          (should (equal (ladybird-test-sent)
                         '(((type . "file_picker_closed") (view . 1) (id . 5)
                            (paths . ["/tmp/a.txt"])))))
          (setq ladybird-test-sent nil
                files '("/tmp/a.txt" "~/b.txt"))
          (ladybird-test-receive
           conn (ladybird-render-test-request "file_picker" '(multiple . t)))
          (should (equal (alist-get 'paths (car (ladybird-test-sent)))
                         (vector "/tmp/a.txt" (expand-file-name "~/b.txt")))))
        (setq ladybird-test-sent nil)
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _) (signal 'quit nil))))
          (ladybird-test-receive
           conn (ladybird-render-test-request "file_picker")))
        (should (equal (ladybird-test-sent)
                       '(((type . "file_picker_closed") (view . 1) (id . 5)
                          (paths . [])))))))))

(ert-deftest ladybird-render-test-file-picker-remote ()
  (ladybird-render-test-with-view
    (ladybird-render-test-prompting
      (let* ((remote (ladybird-test-connect
                      '("far" (:kind tcp :host "far" :port 9000))))
             (prompt nil))
        (ladybird--make-view-buffer remote 1 "mock://far")
        (cl-letf (((symbol-function 'read-string)
                   (lambda (text &rest _) (setq prompt text) "/srv/file")))
          (ladybird-test-receive
           remote (ladybird-render-test-request "file_picker")))
        (should (equal prompt "Path on far, the server's machine: "))
        (should (equal (ladybird-test-sent)
                       '(((type . "file_picker_closed") (view . 1) (id . 5)
                          (paths . ["/srv/file"])))))))))

(ert-deftest ladybird-render-test-color-and-date ()
  (ladybird-render-test-with-view
    (should (equal (ladybird--color-hex "#00ff00") "#00ff00"))
    (should (equal (ladybird--color-hex "#0000ffff0000") "#00ff00"))
    (should-not (ladybird--color-hex "no such colour"))
    (ladybird-render-test-prompting
      (cl-letf (((symbol-function 'read-color) (lambda (&rest _) "#00ff00")))
        (ladybird-test-receive
         conn (ladybird-render-test-request "color_picker" '(current . "#ff0000"))))
      (cl-letf (((symbol-function 'read-color)
                 (lambda (&rest _) (signal 'quit nil))))
        (ladybird-test-receive conn (ladybird-render-test-request "color_picker")))
      (let ((dates '("2026-11-09" "")))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (_prompt &optional initial &rest _)
                     (should (equal initial "2026-01-02"))
                     (pop dates))))
          (dotimes (_ 2)
            (ladybird-test-receive
             conn (ladybird-render-test-request
                   "date_picker" '(input_type . "date")
                   '(value . "2026-01-02")))))))
    (should (equal (ladybird-test-sent)
                   '(((type . "color_picker_closed") (view . 1) (id . 5)
                      (color . "#00ff00"))
                     ((type . "color_picker_closed") (view . 1) (id . 5)
                      (color))
                     ((type . "date_picker_closed") (view . 1) (id . 5)
                      (value . "2026-11-09"))
                     ((type . "date_picker_closed") (view . 1) (id . 5)
                      (value)))))))

(defmacro ladybird-render-test-answering (answer &rest body)
  "Run BODY with `ladybird--read-answer' prompts answered by ANSWER.
ANSWER is evaluated at each prompt: a string to return, or `quit'.
`ladybird-render-test-asked' is the list of (PROMPT CHOICES) of the
prompts, newest first."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (prompt collection &optional _predicate require &rest _)
                (push (list prompt collection require)
                      ladybird-render-test-asked)
                (let ((answer ,answer))
                  (if (eq answer 'quit) (signal 'quit nil) answer))))
             ((symbol-function 'discard-input)
              (lambda () (push 'discard-input ladybird-render-test-asked))))
     ,@body))

(defvar ladybird-render-test-asked nil
  "What the prompts of a test asked, newest first.")

(ert-deftest ladybird-render-test-permission ()
  (ladybird-render-test-with-view
    (ladybird-render-test-prompting
      (let ((request (ladybird-render-test-request
                      "permission" '(name . "geolocation")
                      '(origin . "https://example.org")))
            (ladybird-render-test-asked nil))
        (dolist (case '(("allow once" . "allow_once")
                        ("allow always" . "allow_always")
                        ("deny" . "deny")
                        ;; Nothing chosen, or something that is no choice.
                        ("" . "dismiss")
                        ("a" . "dismiss")
                        (quit . "dismiss")))
          (setq ladybird-test-sent nil)
          (ladybird-render-test-answering (car case)
            (ladybird-test-receive conn request))
          (should (equal (ladybird-test-sent)
                         `(((type . "permission_closed") (view . 1) (id . 5)
                            (outcome . ,(cdr case)))))))
        ;; The answer is a word confirmed in the minibuffer, and keys typed
        ;; before the prompt are discarded.
        (should (equal (take 2 ladybird-render-test-asked)
                       '(("Allow geolocation for https://example.org? \
(allow once, allow always, deny) "
                          ("allow once" "allow always" "deny") t)
                         discard-input)))
        ;; A request the page withdrew closes the prompt unanswered.
        (dolist (type '("permission_cancelled" "request_cancelled"))
          (setq ladybird-test-sent nil)
          (ladybird-render-test-answering
              (progn (ladybird--cancel-prompt (list conn 1 6))
                     (ladybird--cancel-prompt (list conn 1 5))
                     (ert-fail "the prompt stayed open"))
            (ladybird-test-receive conn request))
          (should-not (ladybird-test-sent))
          ;; The cancellation is delivered from a timer.
          (ladybird-test-receive conn `((type . ,type) (view . 1) (id . 5)))
          (let ((timer (seq-find (lambda (timer)
                                   (eq (timer--function timer)
                                       #'ladybird--cancel-prompt))
                                 timer-list)))
            (should (equal (timer--args timer) (list (list conn 1 5))))
            (cancel-timer timer)))))))

(ert-deftest ladybird-render-test-request-cancelled ()
  ;; A withdrawn request closes whichever kind of prompt is open, and one
  ;; that waits to be opened never opens; no answer is sent.
  (ladybird-render-test-with-view
    (let ((ladybird--queued-prompts nil))
      (ladybird-render-test-prompting
        (dolist (request (list (ladybird-render-test-request
                                "dialog" '(kind . "confirm"))
                               (ladybird-render-test-request
                                "dialog" '(kind . "prompt"))
                               ladybird-render-test-select
                               (ladybird-render-test-request "file_picker")
                               (ladybird-render-test-request "color_picker")
                               (ladybird-render-test-request "date_picker")
                               (ladybird-render-test-request
                                "external_url" '(url . "https://example.org"))))
          (let ((withdraw (lambda (&rest _)
                            (ladybird--cancel-prompt (list conn 1 5))
                            (ert-fail "the prompt stayed open"))))
            (cl-letf (((symbol-function 'y-or-n-p) withdraw)
                      ((symbol-function 'read-string) withdraw)
                      ((symbol-function 'completing-read) withdraw)
                      ((symbol-function 'read-file-name) withdraw)
                      ((symbol-function 'read-color) withdraw))
              (ladybird-test-receive conn request)))
          (should-not (ladybird-test-sent))))
      ;; Queued, then withdrawn before the timer ran.
      (ladybird-test-receive
       conn (ladybird-render-test-request "dialog" '(kind . "confirm")))
      (should (= (length ladybird--queued-prompts) 1))
      (ladybird-test-receive conn '((type . "request_cancelled") (view . 1)
                                    (id . 5)))
      (should-not ladybird--queued-prompts)
      ;; An id nobody asked about is ignored.
      (ladybird-test-receive conn '((type . "request_cancelled") (view . 1)
                                    (id . 99)))
      (should-not (ladybird-test-sent))
      (dolist (timer timer-list)
        (when (memq (timer--function timer)
                    '(ladybird--cancel-prompt ladybird--run-prompt))
          (cancel-timer timer))))))

(ert-deftest ladybird-render-test-external-url ()
  (ladybird-render-test-with-view
    (ladybird-render-test-prompting
      (let* ((opened nil)
             (browse-url-secondary-browser-function
              (lambda (url &rest _) (push url opened)))
             (ladybird-render-test-asked nil)
             (request (lambda (url)
                        (ladybird-render-test-request
                         "external_url" `(url . ,url) '(application . "Mail")))))
        (dolist (case '(("open on server" . t) ("open here" . nil)
                        ("deny" . nil) ("" . nil) ("o" . nil) (quit . nil)))
          (setq ladybird-test-sent nil)
          (ladybird-render-test-answering (car case)
            (ladybird-test-receive conn (funcall request "mailto:a@example.org")))
          (should (equal (ladybird-test-sent)
                         `(((type . "external_url_closed") (view . 1) (id . 5)
                            (open . ,(cdr case)))))))
        (should (equal opened '("mailto:a@example.org")))
        (should (equal (take 2 ladybird-render-test-asked)
                       '(("Open mailto:a@example.org with Mail? \
(open on server, open here, deny) "
                          ("open on server" "open here" "deny") t)
                         discard-input)))
        ;; Only web and mail addresses are opened here: for anything else
        ;; that choice is not offered, and it is refused if it is made.
        (dolist (url '("file:///etc/passwd" "javascript:alert(1)"
                       "x-apple-reminder://x" "/Applications/Calculator.app"
                       " https://example.org" "ssh://host"))
          (setq opened nil
                ladybird-test-sent nil
                ladybird-render-test-asked nil)
          (ladybird-render-test-answering "open here"
            (ladybird-test-receive conn (funcall request url)))
          (should-not opened)
          (should (equal (nth 1 (car ladybird-render-test-asked))
                         '("open on server" "deny")))
          (should (equal (ladybird-test-sent)
                         '(((type . "external_url_closed") (view . 1) (id . 5)
                            (open))))))
        (should-not (ladybird--open-here-p nil))
        (should (ladybird--open-here-p "HTTPS://example.org/"))
        (should (ladybird--open-here-p "http://example.org/"))))))

(ert-deftest ladybird-render-test-context-menu ()
  (ladybird-render-test-with-view
    (let ((menu '((type . "context_menu") (view . 1) (x . 1) (y . 2)
                  (kind . "link") (link_url . "mock://linked")
                  (selection . "chosen words") (editable . t)))
          (shown nil))
      (should (equal (mapcar #'car (ladybird--context-menu-items menu))
                     '("Open Link" "Open Link in New Buffer" "Copy Link"
                       "Copy" "Search Selection"
                       "Paste" "Cut" "Select All" "Undo" "Redo"
                       "Back" "Forward" "Reload")))
      (should (equal (mapcar #'car (ladybird--context-menu-items
                                    '((image_url . "mock://i")
                                      (media_url . "mock://m")
                                      (selection . ""))))
                     '("Open Image" "Copy Image URL" "Copy Media URL"
                       "Back" "Forward" "Reload")))
      (ladybird-render-test-prompting
        (kill-new "to paste")
        (dolist (label '("Open Link" "Copy Link" "Search Selection" "Paste"
                         "Cut" "Back" "Reload" nil))
          (cl-letf (((symbol-function 'x-popup-menu)
                     (lambda (position menu)
                       (setq shown (list position (car menu)))
                       (cdr (assoc label (cdr (cadr menu)))))))
            (with-temp-buffer
              (ladybird-test-receive conn menu)))))
      (should (equal shown '(t "Page")))
      (should (equal (current-kill 0) "mock://linked"))
      (should (equal (ladybird-test-sent)
                     '(((type . "load") (view . 1) (url . "mock://linked"))
                       ((type . "load") (view . 1) (url . "chosen words"))
                       ((type . "paste") (view . 1) (text . "mock://linked"))
                       ((type . "edit") (view . 1) (op . "cut"))
                       ((type . "history") (view . 1) (delta . -1))
                       ((type . "reload") (view . 1) (bypass_cache))))))))

(ert-deftest ladybird-render-test-popup-blocked ()
  (ladybird-render-test-with-view
    (should-error (ladybird-open-blocked-popup) :type 'user-error)
    (let ((messages (ladybird-render-test-messages
                      (ladybird-test-receive
                       conn '((type . "popup_blocked") (view . 1)
                              (url . "mock://popped"))))))
      (should (string-prefix-p "Popup blocked: mock://popped" (car messages))))
    (should (equal ladybird--blocked-popup "mock://popped"))
    (save-window-excursion
      (let ((popup (ladybird-open-blocked-popup)))
        (should (equal (map-delete
                        (copy-alist (car (ladybird-test-sent "create_view")))
                        'request)
                       `((type . "create_view") (url . "mock://popped")
                         (width . ,(window-body-width nil t))
                         (height . ,(window-body-height nil t))
                         (dpr . 1.0))))
        (should (eq (buffer-local-value 'ladybird--conn popup) conn))))))

(ert-deftest ladybird-render-test-clipboard ()
  (ladybird-render-test-with-view
    (ladybird-test-receive conn '((type . "clipboard") (view . 1)
                                (text . "copied by the page")))
    (should (equal (current-kill 0) "copied by the page"))
    (ladybird-test-receive conn '((type . "clipboard") (view . 1) (text . "")))
    (should (equal (current-kill 0) "copied by the page"))))

(ert-deftest ladybird-render-test-cursor ()
  (ladybird-render-test-with-view
    (should (eq (get-text-property 1 'pointer) 'arrow))
    (ladybird-test-receive conn '((type . "cursor") (view . 1)
                                (cursor . "pointer")))
    (should (eq (get-text-property 1 'pointer) 'hand))
    (should-not (buffer-modified-p))
    ;; A new canvas keeps the shape.
    (ladybird-test-receive conn (ladybird-test-frame 1 1 4 3 nil 1 t))
    (should (eq (get-text-property 1 'pointer) 'hand))
    (ladybird-test-receive conn '((type . "cursor") (view . 1)
                                (cursor . "no-such-cursor")))
    (should (eq (get-text-property 1 'pointer) 'arrow))))

(ert-deftest ladybird-render-test-hover ()
  (ladybird-render-test-with-view
    (let ((shown 'none))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq shown (and format (apply #'format format args)))))
                ((symbol-function 'current-message) (lambda () shown)))
        (ladybird-test-receive conn '((type . "link_hover") (view . 1)
                                    (url . "https://example.org/100%")))
        (should (equal shown "https://example.org/100%"))
        (ladybird-test-receive conn '((type . "link_hover") (view . 1) (url)))
        (should-not shown)
        ;; A URL wider than the echo area is cut to one line.
        (let ((long (concat "https://example.org/" (make-string 1000 ?a))))
          (ladybird-test-receive conn `((type . "link_hover") (view . 1)
                                      (url . ,long)))
          (should (string-prefix-p "https://example.org/aaa" shown))
          (should (< (string-width shown) (window-width (minibuffer-window))))
          (ladybird-test-receive conn '((type . "link_hover") (view . 1) (url)))
          (should-not shown))
        ;; Another message in the echo area is left alone.
        (ladybird-test-receive conn '((type . "link_hover") (view . 1)
                                    (url . "https://example.org/")))
        (setq shown "something else")
        (ladybird-test-receive conn '((type . "link_hover") (view . 1) (url)))
        (should (equal shown "something else"))
        (let ((ladybird-show-link-hover nil))
          (ladybird-test-receive conn '((type . "link_hover") (view . 1)
                                      (url . "https://example.org/")))
          (should (equal shown "something else")))
        (ladybird-test-receive conn '((type . "tooltip") (view . 1)
                                    (text . "a tip")))
        (should (equal shown "a tip"))
        (ladybird-test-receive conn '((type . "tooltip") (view . 1) (text)))))))

(ert-deftest ladybird-render-test-favicon ()
  (ladybird-render-test-with-view
    (ladybird-test-receive
     conn `((type . "favicon") (view . 1)
            (png . ,(concat "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA"
                            "DUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))))
    (should (eq (car ladybird--favicon) 'image))
    (should (eq (plist-get (cdr ladybird--favicon) :type) 'png))
    (should (string-prefix-p "\x89PNG" (plist-get (cdr ladybird--favicon) :data)))
    (should (get-text-property 1 'display (ladybird--header-line)))
    (ladybird-test-receive conn '((type . "favicon") (view . 1) (png . "%%%")))
    (should-not ladybird--favicon)))

(ert-deftest ladybird-render-test-console ()
  (ladybird-render-test-with-view
    (let ((ladybird-console-buffer " *ladybird-test-console*"))
      (unwind-protect
          (progn
            (ladybird-test-receive conn '((type . "console") (view . 1)
                                        (level . "log") (text . "one")))
            (ladybird-test-receive conn '((type . "console") (view . 9)
                                        (level . "error") (text . "two")))
            (with-current-buffer ladybird-console-buffer
              (should (derived-mode-p 'special-mode))
              (should (equal (buffer-string)
                             (concat "*ladybird: mock://one* [log] one\n"
                                     "view 9 [error] two\n")))))
        (when (get-buffer ladybird-console-buffer)
          (kill-buffer ladybird-console-buffer))))))

(ert-deftest ladybird-render-test-reports ()
  (ladybird-render-test-with-view
    (should (equal (ladybird-render-test-messages
                     (ladybird-test-receive
                      conn '((type . "screenshot_saved") (view . 1)
                             (request . 77) (path . "/tmp/shot.png")))
                     (ladybird-test-receive
                      conn '((type . "error") (view . 1)
                             (message . "bad URL"))))
                   '("ladybird: screenshot saved on test as /tmp/shot.png"
                     "ladybird: test: bad URL")))))

;;; D1: navigation

(ert-deftest ladybird-render-test-navigation ()
  (ladybird-render-test-with-view
    (ladybird-goto-url "example.org/a b")
    (ladybird-reload)
    (ladybird-reload-bypass-cache)
    (ladybird-stop)
    (ladybird-zoom-in)
    (ladybird-zoom-out)
    (ladybird-zoom-reset)
    (should (equal (ladybird-test-sent)
                   '(((type . "load") (view . 1) (url . "example.org/a b"))
                     ((type . "reload") (view . 1) (bypass_cache))
                     ((type . "reload") (view . 1) (bypass_cache . t))
                     ((type . "stop") (view . 1))
                     ((type . "zoom") (view . 1) (op . "in"))
                     ((type . "zoom") (view . 1) (op . "out"))
                     ((type . "zoom") (view . 1) (op . "reset")))))
    (should-error (ladybird-goto-url "") :type 'user-error)
    (dolist (binding '(("l" . ladybird-goto-url) ("g" . ladybird-goto-url)
                       ("r" . ladybird-reload) ("R" . ladybird-reload-bypass-cache)
                       ("s" . ladybird-stop) ("b" . ladybird-back)
                       ("f" . ladybird-forward) ("+" . ladybird-zoom-in)
                       ("=" . ladybird-zoom-in) ("-" . ladybird-zoom-out)
                       ("0" . ladybird-zoom-reset) ("w" . ladybird-copy-url)
                       ("c" . ladybird-new-buffer) ("S" . ladybird-screenshot)
                       ("C-c C-l" . ladybird-toggle-console)
                       ("C-s" . ladybird-find) ("C-r" . ladybird-find-backward)
                       ("M-s n" . ladybird-find-next)
                       ("M-s p" . ladybird-find-previous)))
      (should (eq (key-binding (kbd (car binding))) (cdr binding))))))

(ert-deftest ladybird-render-test-history ()
  (ladybird-render-test-with-view
    (should-error (ladybird-back) :type 'user-error)
    (should-error (ladybird-forward) :type 'user-error)
    (ladybird-test-receive conn (ladybird-render-test-state '(can_go_back . t)))
    (ladybird-back)
    (should-error (ladybird-forward) :type 'user-error)
    (ladybird-test-receive conn (ladybird-render-test-state '(can_go_forward . t)))
    (ladybird-forward)
    (should (equal (ladybird-test-sent)
                   '(((type . "history") (view . 1) (delta . -1))
                     ((type . "history") (view . 1) (delta . 1)))))))

(ert-deftest ladybird-render-test-not-connected ()
  (ladybird-render-test-with-view
    (let ((ladybird-reconnect nil))
      (ladybird--drop conn))
    (dolist (command '(ladybird-reload ladybird-stop ladybird-zoom-in ladybird-find
                       ladybird-toggle-console ladybird-copy-selection))
      (should-error (funcall command) :type 'user-error))
    (should-not (ladybird-test-sent))))

(ert-deftest ladybird-render-test-copy-url-and-new-buffer ()
  (ladybird-render-test-with-view
    (ladybird-test-receive conn (ladybird-render-test-state '(url . "mock://now")))
    (ladybird-copy-url)
    (should (equal (current-kill 0) "mock://now"))
    (save-window-excursion
      (let ((new (ladybird-new-buffer)))
        (should-not (eq new buffer))
        (should (eq (window-buffer) new))
        (should (equal (alist-get 'url (car (ladybird-test-sent "create_view")))
                       "mock://now"))
        (should (equal (buffer-local-value 'ladybird--host new) ladybird--host))))))

(ert-deftest ladybird-render-test-screenshot ()
  (ladybird-render-test-with-view
    (ladybird-screenshot "/tmp/shot.png" "full")
    (ladybird-screenshot "" "visible")
    (pcase-let ((`(,first ,second) (ladybird-test-sent)))
      (should (equal (map-delete (copy-alist first) 'request)
                     '((type . "screenshot") (view . 1) (kind . "full")
                       (path . "/tmp/shot.png"))))
      (should (equal (map-delete (copy-alist second) 'request)
                     '((type . "screenshot") (view . 1) (kind . "visible"))))
      (should (equal (ladybird-render-test-messages
                       (ladybird-test-receive
                        conn `((type . "screenshot_saved") (view . 1)
                               (request . ,(alist-get 'request first))
                               (path . "/tmp/shot.png"))))
                     '("ladybird: screenshot saved on test as /tmp/shot.png"))))))

(ert-deftest ladybird-render-test-toggle-console ()
  (ladybird-render-test-with-view
    (let ((ladybird-console-buffer " *ladybird-test-console*"))
      (unwind-protect
          (save-window-excursion
            (ladybird-toggle-console)
            (should (get-buffer-window ladybird-console-buffer))
            (ladybird-toggle-console)
            (should (equal (ladybird-test-sent)
                           '(((type . "set_console") (view . 1) (enabled . t))
                             ((type . "set_console") (view . 1) (enabled))))))
        (when (get-buffer ladybird-console-buffer)
          (kill-buffer ladybird-console-buffer))))))

(ert-deftest ladybird-render-test-browse-url ()
  (ladybird-render-test-with-view
    (let ((ladybird-program "ladybird-no-such-program")
          (ladybird-hosts '(("test" . "/nonexistent/ladybird")))
          (ladybird-default-host nil)
          (ladybird--last-buffer nil))
      (should (eq (function-get 'ladybird-browse-url 'browse-url-browser-kind)
                  'internal))
      (save-window-excursion
        ;; Without a page buffer in use a new one opens.
        (let ((new (ladybird-browse-url "mock://first")))
          (should-not (eq new buffer))
          (should (equal (alist-get 'url (car (ladybird-test-sent "create_view")))
                         "mock://first"))
          (ladybird-test-receive conn '((type . "view_created") (view . 2)
                                      (url . "mock://first")))
          ;; The buffer used last loads the next URL.
          (should (eq (ladybird-browse-url "mock://second") new))
          (should (eq (window-buffer) new))
          (should (equal (car (ladybird-test-sent "load"))
                         '((type . "load") (view . 2) (url . "mock://second"))))
          ;; NEW-SESSION opens another buffer.
          (should-not (memq (ladybird-browse-url "mock://third" t)
                            (list new buffer)))
          (should (= (length (ladybird-test-sent "create_view")) 2)))))))


;;; D2: find

(ert-deftest ladybird-render-test-find-messages ()
  (ladybird-render-test-with-view
    (should-error (ladybird-find-next) :type 'user-error)
    (ladybird--send-find "needle")
    (ladybird--send-find "Needle")
    (ladybird-find-next)
    (ladybird-find-previous)
    (ladybird--send-find "")
    (should (equal (ladybird-test-sent)
                   '(((type . "find") (view . 1) (query . "needle")
                      (case_sensitive) (highlight_all . t))
                     ((type . "find") (view . 1) (query . "Needle")
                      (case_sensitive . t) (highlight_all . t))
                     ((type . "find_step") (view . 1) (direction . "next"))
                     ((type . "find_step") (view . 1) (direction . "previous"))
                     ((type . "find") (view . 1) (query . "")
                      (case_sensitive) (highlight_all . t)))))
    (should-not ladybird--find-string)))

(ert-deftest ladybird-render-test-find-result ()
  (ladybird-render-test-with-view
    (ladybird--send-find "new")
    (let ((messages (ladybird-render-test-messages
                      ;; A result for an earlier string is dropped.
                      (ladybird-test-receive
                       conn '((type . "find_result") (view . 1) (query . "old")
                              (index . 1) (total . 9)))
                      (should-not ladybird--find-result)
                      (ladybird-test-receive
                       conn '((type . "find_result") (view . 1) (query . "new")
                              (index . 2) (total . 3)))
                      (ladybird-test-receive
                       conn '((type . "find_result") (view . 1) (query . "new")
                              (index . 0) (total . 0))))))
      (should (equal messages '("Find new: 2/3" "Find new: no match")))
      (should (equal ladybird--find-result '(0 . 0))))
    ;; The first match has index 1; the total can be unknown.
    (should (equal (ladybird-render-test-messages
                     (ladybird-test-receive
                      conn '((type . "find_result") (view . 1) (query . "new")
                             (index . 1) (total . 1)))
                     (ladybird-test-receive
                      conn '((type . "find_result") (view . 1) (query . "new")
                             (index . 3) (total))))
                   '("Find new: 1/1" "Find new: 3/?")))
    (should (equal ladybird--find-result '(3)))))

(ert-deftest ladybird-render-test-find-command ()
  (ladybird-render-test-with-view
    (let ((prompt nil))
      ;; RET searches for what was typed, if the timer has not already.
      (cl-letf (((symbol-function 'read-from-minibuffer)
                 (lambda (text _initial keymap &rest _)
                   (setq prompt (list text keymap ladybird--find-buffer))
                   "needle")))
        (ladybird-find))
      (should (equal prompt (list "Find in page: " ladybird--find-minibuffer-map
                                  buffer)))
      (should (equal (mapcar (lambda (m) (alist-get 'query m)) (ladybird-test-sent))
                     '("needle")))
      (should (equal ladybird--find-string "needle"))
      (should-not ladybird--find-buffer)
      (cl-letf (((symbol-function 'read-from-minibuffer)
                 (lambda (&rest _)
                   (with-current-buffer buffer (ladybird--send-find "needle"))
                   "needle")))
        (setq ladybird-test-sent nil)
        (ladybird-find-backward))
      (should (= (length (ladybird-test-sent)) 1))
      ;; A quit ends the search.
      (setq ladybird-test-sent nil)
      (cl-letf (((symbol-function 'read-from-minibuffer)
                 (lambda (&rest _) (signal 'quit nil))))
        (should (eq (condition-case nil (ladybird-find) (quit 'quit)) 'quit)))
      (should (equal (mapcar (lambda (m) (alist-get 'query m)) (ladybird-test-sent))
                     '("")))
      (should-not ladybird--find-string)
      (should (eq (lookup-key ladybird--find-minibuffer-map (kbd "C-s"))
                  #'ladybird-find-minibuffer-next))
      (should (eq (lookup-key ladybird--find-minibuffer-map (kbd "C-r"))
                  #'ladybird-find-minibuffer-previous)))))


;;; D3: lifecycle

(ert-deftest ladybird-render-test-replaced-and-reconnect ()
  (ladybird-render-test-with-view
    (ladybird-test-receive conn (ladybird-test-frame 1 1 4 3 nil 1 t))
    (let ((canvas ladybird--canvas))
      (ladybird-test-receive conn '((type . "replaced")))
      (should (eq (ladybird--conn-state conn) 'replaced))
      (should-not (ladybird--conn-timer conn))
      (should (string-suffix-p " [detached]" (ladybird--header-line)))
      ;; The last frame stays, and input is dropped without a message.
      (should (eq (get-text-property 1 'display) canvas))
      (should-not (ladybird-render-test-messages
                    (ladybird--send-key '("A" 97 0))))
      (should-error (ladybird-reload) :type 'user-error)
      ;; Reconnecting takes the view over again.
      (setq ladybird-test-sent nil)
      (ladybird-reconnect)
      (ladybird-test-receive
       conn (ladybird-test-welcome '(((view . 1) (url . "mock://one")))))
      (should (= ladybird--view 1))
      (should (eq ladybird--canvas canvas))
      (should-not (ladybird-test-sent "create_view"))
      (should (= (length (ladybird--buffers conn)) 1))
      (should-not (ladybird--conn-tag)))))

(ert-deftest ladybird-render-test-focus-out ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (ladybird-mouse-down `(down-mouse-1 ,(ladybird-render-test-posn 5 5)))
    (setq ladybird-test-sent nil)
    (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) nil)))
      (ladybird--focus-changed)
      (should (equal (ladybird-test-sent)
                     '(((type . "mouse") (view . 1) (kind . "leave")))))
      (should-not ladybird--buttons)
      (should (timerp ladybird--update-timer))
      (setq ladybird-test-sent nil)
      (ladybird--update)
      (should (equal (ladybird-test-sent "set_focus")
                     '(((type . "set_focus") (view . 1) (focused))))))
    (setq track-mouse nil)))

(ert-deftest ladybird-render-test-keep-view-on-kill ()
  (ladybird-render-test-with-view
    (let ((second (ladybird--make-view-buffer conn 2 "mock://2"))
          (ladybird-keep-view-on-kill t))
      (kill-buffer second)
      (should-not (ladybird-test-sent "close_view"))
      (should-not (gethash 2 (ladybird--conn-views conn)))
      ;; The next welcome lists the view, which gets a buffer again.
      (ladybird--drop conn)
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (ladybird-test-receive
       conn (ladybird-test-welcome '(((view . 1) (url . "mock://one"))
                                   ((view . 2) (url . "mock://2")))))
      (should (buffer-live-p (gethash 2 (ladybird--conn-views conn))))
      (should (eq (gethash 1 (ladybird--conn-views conn)) buffer)))))


;;; Review fixes

(ert-deftest ladybird-render-test-create-request ()
  ;; The answer to `create_view' names its request, whatever the order.
  (ladybird-render-test-with-view
    (let* ((two (ladybird--make-view-buffer conn nil "mock://2"))
           (three (ladybird--make-view-buffer conn nil "mock://3"))
           (request (lambda (buffer)
                      (cdr (assq buffer (ladybird--conn-creating conn))))))
      (with-current-buffer two (ladybird--create-view))
      (with-current-buffer three (ladybird--create-view))
      (should (equal (mapcar (lambda (m) (alist-get 'request m))
                             (ladybird-test-sent "create_view"))
                     (list (funcall request two) (funcall request three))))
      ;; The later request is answered first.
      (ladybird-test-receive conn `((type . "view_created") (view . 9)
                                    (request . ,(funcall request three))
                                    (url . "mock://3") (title . "Three")))
      (should (= (buffer-local-value 'ladybird--view three) 9))
      (should-not (buffer-local-value 'ladybird--view two))
      (should (equal (mapcar #'car (ladybird--conn-creating conn)) (list two)))
      (ladybird-test-receive conn `((type . "view_created") (view . 8)
                                    (request . ,(funcall request two))))
      (should (= (buffer-local-value 'ladybird--view two) 8))
      (should-not (ladybird--conn-creating conn))
      (should (= (hash-table-count (ladybird--conn-pending conn)) 0))
      ;; The module keeps the frames of the new views.
      (should (equal (sort (mapcar #'car
                                   (plist-get (ladybird-module-stats
                                               (ladybird--conn-decoder conn))
                                              :views))
                           #'<)
                     '(1 8 9))))))

(ert-deftest ladybird-render-test-create-refused ()
  ;; A server that shows one page answers a second `create_view' with an
  ;; error: the placeholder goes, the URL loads in the page there is, and
  ;; the next page is not even asked for.
  (ladybird-render-test-with-view
    (save-window-excursion
      (set-window-buffer (selected-window) buffer)
      (setq ladybird--last-buffer buffer)
      (let* ((ladybird-program "ladybird-no-such-program")
             (ladybird-hosts '(("test" . "/nonexistent/ladybird")))
             (ladybird-default-host nil)
             (second (ladybird-new-buffer))
             (request (alist-get 'request (car (ladybird-test-sent "create_view"))))
             (messages (ladybird-render-test-messages
                         (ladybird-test-receive
                          conn `((type . "error") (request . ,request)
                                 (message . "only one view is supported"))))))
        (should (eq (window-buffer) buffer))
        (should-not (buffer-live-p second))
        (should (equal (car (ladybird-test-sent "load"))
                       '((type . "load") (view . 1) (url . "mock://one"))))
        (should (equal messages
                       '("ladybird: test opens no further page; mock://one \
loaded in *ladybird: mock://one*")))
        (should (= (ladybird--conn-view-limit conn) 1))
        (should-not (ladybird--conn-creating conn))
        (should (ladybird--ready-p conn))
        ;; From now on a further page loads in this one.
        (set-buffer buffer)
        (setq ladybird-test-sent nil
              ladybird--blocked-popup "mock://popped")
        (should (eq (ladybird-open-blocked-popup) buffer))
        (should (eq (ladybird "mock://again" ladybird-test-host) buffer))
        (should (eq (ladybird-browse-url "mock://third" t) buffer))
        (should-not (ladybird-test-sent "create_view"))
        (should (equal (mapcar (lambda (m) (alist-get 'url m))
                               (ladybird-test-sent "load"))
                       '("mock://popped" "mock://again" "mock://third")))
        (should (= (length (ladybird--buffers)) 1))
        ;; Another server process may show more.
        (ladybird--drop conn)
        (ladybird-test-run-timer (ladybird--conn-timer conn))
        (ladybird-test-receive
         conn `((log . "/tmp/other.log")
                ,@(assq-delete-all 'log (ladybird-test-welcome)))))
      (should-not (ladybird--conn-view-limit conn)))))

(ert-deftest ladybird-render-test-create-refused-unnamed ()
  ;; A server that does not name the request: an error about no view
  ;; fails the buffer that has waited longest.
  (ladybird-render-test-with-view
    (let ((two (ladybird--make-view-buffer conn nil "mock://2"))
          (three (ladybird--make-view-buffer conn nil "mock://3")))
      (with-current-buffer two (ladybird--create-view))
      (with-current-buffer three (ladybird--create-view))
      ;; An error about a view is none about a create.
      (should (equal (ladybird-render-test-messages
                       (ladybird-test-receive conn '((type . "error") (view . 1)
                                                     (message . "bad URL"))))
                     '("ladybird: test: bad URL")))
      (should (buffer-live-p two))
      (ladybird-test-receive conn '((type . "error")
                                    (message . "only one view is supported")))
      (should-not (buffer-live-p two))
      (should (buffer-live-p three))
      (should (equal (car (ladybird-test-sent "load"))
                     '((type . "load") (view . 1) (url . "mock://2"))))
      (ladybird-test-receive conn '((type . "view_created") (view . 5)))
      (should (= (buffer-local-value 'ladybird--view three) 5))
      (should (= (hash-table-count (ladybird--conn-pending conn)) 0)))))

(ert-deftest ladybird-render-test-create-refused-first ()
  ;; The only buffer of a connection gets no view: it is killed with a
  ;; message instead of staying at \"opening\".
  (ladybird-test-with-env
    (let* ((ladybird--welcome-function #'ladybird--on-welcome)
           (ladybird--change-function #'ladybird--on-conn-change)
           (ladybird-device-pixel-ratio 1.0)
           (ladybird-program "ladybird-no-such-program")
           (ladybird-hosts '(("test" . "/nonexistent/ladybird")))
           (ladybird--last-buffer nil)
           buffer messages)
      (save-window-excursion
        (setq buffer (ladybird "mock://x" "test"))
        (let ((conn (buffer-local-value 'ladybird--conn buffer)))
          (ladybird-test-receive conn (ladybird-test-welcome))
          (let ((inhibit-message nil))
            (setq messages
                  (ladybird-render-test-messages
                    (ladybird-test-receive
                     conn `((type . "error")
                            (request . ,(alist-get
                                         'request
                                         (car (ladybird-test-sent "create_view"))))
                            (message . "out of memory"))))))))
      (should-not (buffer-live-p buffer))
      (should (equal messages '("ladybird: test opened no page: out of memory")))
      (should-not ladybird--conns))))

(ert-deftest ladybird-render-test-drag-and-hover-tracking ()
  ;; The drag and the hover tracking do not take each other's value for
  ;; the one to put back.
  (ladybird-render-test-with-view
    (save-window-excursion
      (let ((track-mouse nil)
            (mouse-fine-grained-tracking nil)
            (this-command nil)
            (end-drag (lambda ()
                        (setq ladybird--dragging nil)
                        (ladybird--sync-tracking t))))
        (ladybird-render-test-show)
        ;; A drag begins before the hover tracking has run.
        (let ((ladybird-track-hover nil))
          (ladybird-mouse-down `(down-mouse-1 ,(ladybird-render-test-posn 5 5)))
          (should (eq track-mouse 'dragging))
          (should (equal ladybird--saved-tracking '(nil nil))))
        ;; The update timer fires during the drag.
        (ladybird--update)
        (should (eq track-mouse 'dragging))
        (should (equal ladybird--saved-tracking '(nil nil)))
        (funcall end-drag)
        (should (eq track-mouse t))
        ;; A drag while the hover tracking is on goes back to it.
        (ladybird-mouse-down `(down-mouse-1 ,(ladybird-render-test-posn 5 5)))
        (should (eq track-mouse 'dragging))
        (funcall end-drag)
        (should (eq track-mouse t))
        ;; Leaving the page puts back what was there before either.
        (with-temp-buffer
          (set-window-buffer (selected-window) (current-buffer))
          (ladybird--update))
        (should-not track-mouse)
        (should-not mouse-fine-grained-tracking)
        (should-not ladybird--saved-tracking)))))

(ert-deftest ladybird-render-test-tracking-bound ()
  ;; A value of `track-mouse' bound by a running command or inside a
  ;; recursive edit is neither saved nor overwritten.
  (ladybird-render-test-with-view
    (save-window-excursion
      (let ((track-mouse nil)
            (mouse-fine-grained-tracking nil)
            (this-command nil))
        (set-window-buffer (selected-window) buffer)
        ;; A timer runs while a command waits with the variable bound.
        (let ((track-mouse 'bound)
              (this-command 'mouse-drag-region))
          (ladybird--update)
          (should (eq track-mouse 'bound))
          (should-not ladybird--saved-tracking))
        ;; So does one inside a recursive edit.
        (cl-letf (((symbol-function 'recursion-depth) (lambda () 1)))
          (let ((track-mouse 'bound))
            (ladybird--update)
            (ladybird--after-command)
            (should (eq track-mouse 'bound))
            (should-not ladybird--saved-tracking)))
        (should-not track-mouse)
        ;; The end of the next command catches up.
        (let ((this-command 'other-window))
          (ladybird--after-command))
        (should (eq track-mouse t))
        (should (equal ladybird--saved-tracking '(nil nil)))
        ;; Leaving while a command has it bound waits as well.
        (with-temp-buffer
          (set-window-buffer (selected-window) (current-buffer))
          (let ((track-mouse 'bound)
                (this-command 'mouse-drag-region))
            (ladybird--update)
            (should (eq track-mouse 'bound))
            (should ladybird--saved-tracking))
          (should (eq track-mouse t))
          (ladybird--after-command))
        (should-not track-mouse)
        (should-not ladybird--saved-tracking)))))

(ert-deftest ladybird-render-test-local-server ()
  (ladybird-render-test-with-view
    ;; The test connection is a Unix socket whose server names this host.
    (should (ladybird--local-server-p conn))
    ;; A segment that could not be mapped: the socket is forwarded.
    (setf (ladybird--conn-shm-failed conn) t)
    (should-not (ladybird--local-server-p conn))
    (setf (ladybird--conn-shm-failed conn) nil)
    ;; The server names another machine.
    (setf (ladybird--conn-server-info conn)
          '((host . ((hostname . "elsewhere.example") (platform . "linux")))))
    (should-not (ladybird--local-server-p conn))
    (setf (ladybird--conn-server-info conn) '((host)))
    (should-not (ladybird--local-server-p conn))
    (setf (ladybird--conn-server-info conn)
          `((host . ((hostname . ,(upcase (system-name)))))))
    (should (ladybird--local-server-p conn))
    ;; An endpoint that rules shared memory out.
    (setf (ladybird--conn-endpoint conn) '(:kind unix :path "/s" :shm nil))
    (should-not (ladybird--local-server-p conn))
    (dolist (case '(((:kind local) . t)
                    ((:kind local :command ("x")) . t)
                    ((:kind ssh :host "h") . nil)
                    ((:kind tcp :host "h" :port 1) . nil)))
      (setf (ladybird--conn-endpoint conn) (car case))
      (should (eq (and (ladybird--local-server-p conn) t) (cdr case))))
    (should (equal (ladybird--local-directory "/tmp/x") "/tmp/x"))
    (dolist (hint '("/ssh:evil.example:/tmp" "/sudo::/root" "relative/dir" nil 7))
      (should-not (ladybird--local-directory hint)))))

(ert-deftest ladybird-render-test-file-picker-forwarded ()
  ;; Over a forwarded socket the picker asks for a path on the server's
  ;; machine, and a remote directory hint never reaches `read-file-name'.
  (ladybird-render-test-with-view
    (ladybird-render-test-prompting
      (let ((asked nil))
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (_prompt &optional directory &rest _)
                     (push (list 'file directory) asked)
                     "/tmp/a.txt"))
                  ((symbol-function 'read-string)
                   (lambda (prompt &rest _)
                     (push (list 'string prompt) asked)
                     "/srv/b.txt")))
          (ladybird-test-receive
           conn (ladybird-render-test-request
                 "file_picker" '(directory . "/ssh:evil.example:/tmp")))
          (should (equal asked '((file nil))))
          (ladybird-test-receive
           conn (ladybird-render-test-request
                 "file_picker" '(directory . "/tmp")))
          (should (equal (car asked) '(file "/tmp")))
          (setf (ladybird--conn-shm-failed conn) t)
          (setq ladybird-test-sent nil)
          (ladybird-test-receive conn (ladybird-render-test-request "file_picker"))
          (should (equal (car asked)
                         '(string "Path on test, the server's machine: ")))
          (should (equal (alist-get 'paths (car (ladybird-test-sent)))
                         ["/srv/b.txt"])))))))

(ert-deftest ladybird-render-test-close-while-down ()
  ;; A page closed while the connection is down is closed on the server
  ;; when the connection is back, and gets no buffer again.
  (ladybird-render-test-with-view
    (let ((second (ladybird--make-view-buffer conn 2 "mock://2"))
          (views '(((view . 1) (url . "mock://one"))
                   ((view . 2) (url . "mock://2")))))
      (ladybird--drop conn)
      (should (eq (ladybird--conn-state conn) 'redialing))
      (kill-buffer second)
      (should (equal (ladybird--conn-closing conn) '(2)))
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (setq ladybird-test-sent nil)
      (ladybird-test-receive conn (ladybird-test-welcome views))
      (should (equal (ladybird-test-sent "close_view")
                     '(((type . "close_view") (view . 2)))))
      (should (equal (ladybird--buffers conn) (list buffer)))
      (should-not (ladybird--conn-closing conn))
      (should-not (gethash 2 (ladybird--conn-views conn)))
      ;; The server's confirmation changes nothing.
      (ladybird-test-receive conn '((type . "view_closed") (view . 2)
                                    (reason . "client")))
      (should (buffer-live-p buffer))
      (should (ladybird--ready-p conn))
      ;; The last buffer killed while down: the connection is dialled
      ;; again to close its view, and then let go.
      (ladybird--drop conn)
      (kill-buffer buffer)
      (should (equal (ladybird--conn-closing conn) '(1)))
      (should (memq conn ladybird--conns))
      (should (eq (ladybird--conn-state conn) 'redialing))
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (setq ladybird-test-sent nil)
      (ladybird-test-receive conn (ladybird-test-welcome (list (car views))))
      (should (equal (ladybird-test-sent "close_view")
                     '(((type . "close_view") (view . 1)))))
      (should-not (ladybird--buffers conn))
      (should (timerp (ladybird--conn-lingering conn)))
      (ladybird-test-receive conn '((type . "view_closed") (view . 1)
                                    (reason . "client")))
      (should-not ladybird--conns))))

(ert-deftest ladybird-render-test-other-server-process ()
  ;; After a server restart a view with the id of a buffer's old view is
  ;; another page: the buffer asks for a view of its own.
  (ladybird-render-test-with-view
    (ladybird-test-receive conn (ladybird-render-test-state '(url . "mock://mine")))
    (ladybird--drop conn)
    (ladybird-test-run-timer (ladybird--conn-timer conn))
    (setq ladybird-test-sent nil)
    (ladybird-test-receive
     conn `((log . "/tmp/ladybird-emacs-777.log")
            ,@(assq-delete-all
               'log (ladybird-test-welcome
                     '(((view . 1) (url . "mock://theirs") (title . "Theirs")))))))
    (should-not ladybird--view)
    (should (equal (alist-get 'url (car (ladybird-test-sent "create_view")))
                   "mock://mine"))
    (let ((theirs (gethash 1 (ladybird--conn-views conn))))
      (should (buffer-live-p theirs))
      (should-not (eq theirs buffer))
      (should (equal (buffer-name theirs) "*ladybird: Theirs*")))))

(ert-deftest ladybird-render-test-linger ()
  ;; On a network connection the last `close_view' gets time to leave.
  (ladybird-render-test-with-view
    (let ((process (ladybird--conn-process conn)))
      (cl-letf (((symbol-function 'process-type) (lambda (_) 'network)))
        (kill-buffer buffer)
        (should (equal (ladybird-test-sent)
                       '(((type . "close_view") (view . 1)))))
        (should (process-live-p process))
        (should (memq conn ladybird--conns))
        (should (timerp (ladybird--conn-lingering conn)))
        ;; The server's answer ends the wait.
        (ladybird-test-receive conn '((type . "view_closed") (view . 1)
                                      (reason . "client")))
        (should-not (process-live-p process))
        (should-not ladybird--conns)
        (should-not (ladybird--conn-lingering conn))))
    ;; Without an answer the timer does; a connection in use again stays.
    (let* ((other (ladybird-test-connect '("other" (:kind unix :path "/o"))))
           (page (ladybird--make-view-buffer other 1 "mock://o")))
      (cl-letf (((symbol-function 'process-type) (lambda (_) 'network)))
        (kill-buffer page))
      (let ((timer (ladybird--conn-lingering other))
            (again (ladybird--make-view-buffer other 2 "mock://again")))
        (timer-event-handler timer)
        (should (memq other ladybird--conns))
        (kill-buffer again)))))

(ert-deftest ladybird-render-test-kill-with-broken-connection ()
  ;; An error while closing the view does not keep the buffer alive.
  (ladybird-render-test-with-view
    (cl-letf (((symbol-function 'ladybird--write)
               (lambda (&rest _) (error "Process ladybird not running"))))
      (kill-buffer buffer))
    (should-not (buffer-live-p buffer))
    (let ((page (ladybird--make-view-buffer
                 (ladybird-test-connect '("other" (:kind unix :path "/o")))
                 1 "mock://o")))
      (cl-letf (((symbol-function 'ladybird--kill-view)
                 (lambda () (error "Boom"))))
        (should (equal (ladybird-render-test-messages (kill-buffer page))
                       '("ladybird: closing *ladybird: mock://o*: (error \"Boom\")"))))
      (should-not (buffer-live-p page)))))

(ert-deftest ladybird-render-test-forget-in-module ()
  ;; The module drops a view with its buffer, with `view_closed' and when
  ;; the view is gone after a reconnect.
  (ladybird-render-test-with-view
    (let ((views (lambda ()
                   (sort (mapcar #'car (plist-get (ladybird-module-stats
                                                   (ladybird--conn-decoder conn))
                                                  :views))
                         #'<)))
          (two (ladybird--make-view-buffer conn 2 "mock://2"))
          (three (ladybird--make-view-buffer conn 3 "mock://3")))
      (ladybird-test-receive conn (ladybird-test-frame 1 2 4 3 nil 1 t))
      (should (equal (funcall views) '(1 2 3)))
      (kill-buffer two)
      (should (equal (funcall views) '(1 3)))
      (ladybird-test-receive conn '((type . "view_closed") (view . 3)
                                    (reason . "closed")))
      (should-not (buffer-live-p three))
      (should (equal (funcall views) '(1)))
      (ladybird--drop conn)
      (ladybird-test-run-timer (ladybird--conn-timer conn))
      (ladybird-test-receive conn (ladybird-test-welcome))
      (should-not (funcall views))
      (ladybird-test-receive conn '((type . "view_created") (view . 6)))
      (should (equal (funcall views) '(6))))))

(ert-deftest ladybird-render-test-canvas-error ()
  ;; A canvas Emacs rejects is replaced.
  (ladybird-render-test-with-view
    (ladybird-test-receive conn (ladybird-test-frame 1 1 4 3 nil 1 t))
    (let ((canvas ladybird--canvas))
      (plist-put (cdr canvas) :data-width 'broken)
      (ladybird-test-receive conn (ladybird-test-frame 2 1 4 3 nil 2 t))
      (should-not (eq ladybird--canvas canvas))
      (should (= (ladybird-module-canvas-pixel ladybird--canvas 3 2)
                 (ladybird-test-pixel 3 2 2 4 3)))
      (should (equal (mapcar (lambda (m) (alist-get 'seq m))
                             (ladybird-test-sent "frame_ack"))
                     '(1 2))))))

(ert-deftest ladybird-render-test-context-menu-release ()
  ;; The menu can take the release of the button that opened it.
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (ladybird-mouse-down `(down-mouse-3 ,(ladybird-render-test-posn 7 8)))
    (should (equal ladybird--buttons '("right")))
    (setq ladybird-test-sent nil)
    (ladybird-render-test-prompting
      (cl-letf (((symbol-function 'x-popup-menu) (lambda (&rest _) nil)))
        (ladybird-test-receive conn '((type . "context_menu") (view . 1)
                                      (x . 7) (y . 8)))))
    (should-not ladybird--buttons)
    (should (equal (ladybird-test-sent)
                   '(((type . "mouse") (view . 1) (kind . "up") (x . 7) (y . 8)
                      (button . "right") (buttons . []) (modifiers . 0)
                      (clicks . 1)))))
    ;; A release that arrived is not repeated.
    (setq ladybird-test-sent nil)
    (ladybird-render-test-prompting
      (cl-letf (((symbol-function 'x-popup-menu) (lambda (&rest _) nil)))
        (ladybird-test-receive conn '((type . "context_menu") (view . 1)))))
    (should-not (ladybird-test-sent))))

(ert-deftest ladybird-render-test-console-cap ()
  (ladybird-render-test-with-view
    (let ((ladybird-console-buffer " *ladybird-test-console*")
          (ladybird-console-max-lines 3))
      (unwind-protect
          (progn
            (dotimes (n 5)
              (ladybird-test-receive conn `((type . "console") (view . 9)
                                            (level . "log")
                                            (text . ,(format "line %d" n)))))
            (with-current-buffer ladybird-console-buffer
              (should (equal (buffer-string)
                             (concat "view 9 [log] line 2\n"
                                     "view 9 [log] line 3\n"
                                     "view 9 [log] line 4\n")))))
        (when (get-buffer ladybird-console-buffer)
          (kill-buffer ladybird-console-buffer))))))


;;; Mock server

(ert-deftest ladybird-mock-test-page ()
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird-device-pixel-ratio 1.0)
         (kill-ring nil)
         (kill-ring-yank-pointer nil)
         (interprogram-cut-function nil)
         (interprogram-paste-function nil)
         (inhibit-message t)
         (logged (lambda (type)
                   (seq-filter (lambda (m) (equal (alist-get 'type m) type))
                               (ladybird-test-log log))))
         buffer)
    (save-window-excursion
      (unwind-protect
          (progn
            (setq buffer (ladybird "mock://one" (ladybird-test-mock-host log)))
            (with-current-buffer buffer
              (let ((conn ladybird--conn)
                    (size (cons (window-body-width nil t)
                                (window-body-height nil t))))
                (ladybird-test-wait conn (lambda () ladybird--canvas))
                (should (equal ladybird--canvas-size size))
                (should (equal (buffer-name) "*ladybird: Mock: mock://one*"))
                (should (eq (get-text-property 1 'display) ladybird--canvas))
                (should (= (ladybird-module-canvas-pixel ladybird--canvas 3 2)
                           (ladybird-test-pixel 3 2 0 (car size) (cdr size))))
                ;; A press paints the mock's square under the pointer.
                (ladybird-mouse-down
                 `(down-mouse-1 ,(ladybird-render-test-posn 40 10)))
                (ladybird-mouse-up `(mouse-1 ,(ladybird-render-test-posn 40 10)))
                (ladybird-test-wait
                 conn (lambda ()
                        (= (ladybird-module-canvas-pixel ladybird--canvas 40 10)
                           #xffffffff)))
                ;; Typing, the selection and a dialog make the round trip.
                (ladybird-insert-mode 1)
                (dolist (last-command-event '(?H ?i ?! ?\r))
                  (ladybird-insert-key))
                (ladybird-copy-selection)
                (ladybird-test-wait conn (lambda () kill-ring))
                (should (equal (current-kill 0) "mock selection"))
                (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
                  (ladybird--send-view "load" '(url . "mock://confirm"))
                  (ladybird-test-wait
                   conn (lambda () (funcall logged "dialog_closed"))))
                (should (equal (alist-get 'accepted
                                          (car (funcall logged "dialog_closed")))
                               t))
                (should (equal (buffer-name) "*ladybird: Mock: mock://confirm*"))
                (should (equal (mapcar (lambda (m) (alist-get 'key m))
                                       (seq-filter
                                        (lambda (m)
                                          (equal (alist-get 'kind m) "down"))
                                        (funcall logged "key")))
                               '("H" "I" "ExclamationPoint" "Return")))
                (let ((down (car (funcall logged "mouse"))))
                  (should (equal (list (alist-get 'x down) (alist-get 'y down))
                                 '(40 10))))
                ;; Killing the buffer closes the view and the connection.
                (kill-buffer buffer)
                (should-not ladybird--conns)
                (with-timeout (5 (ert-fail "the view was not closed"))
                  (while (not (funcall logged "close_view"))
                    (sleep-for 0.05))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (delete-file log)))))

(ert-deftest ladybird-mock-test-single-view ()
  ;; A server that shows one page: the second page loads in the first.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird--last-buffer nil)
         (ladybird-device-pixel-ratio 1.0)
         (inhibit-message t)
         (host (ladybird-test-mock-host log "--max-views" "1"))
         buffer)
    (save-window-excursion
      (unwind-protect
          (progn
            (setq buffer (ladybird "mock://one" host))
            (let ((conn (buffer-local-value 'ladybird--conn buffer)))
              (ladybird-test-wait conn (lambda ()
                                         (buffer-local-value 'ladybird--canvas
                                                             buffer)))
              (let ((second (ladybird "mock://two" host)))
                (should-not (eq second buffer))
                (ladybird-test-wait conn (lambda () (not (buffer-live-p second))))
                (should (eq (window-buffer) buffer))
                (ladybird-test-wait
                 conn (lambda ()
                        (equal (alist-get 'url (buffer-local-value 'ladybird--state
                                                                   buffer))
                               "mock://two"))))
              (should (= (ladybird--conn-view-limit conn) 1))
              ;; The third page is not asked for.
              (should (eq (ladybird "mock://three" host) buffer))
              (ladybird-test-wait
               conn (lambda ()
                      (equal (alist-get 'url (buffer-local-value 'ladybird--state
                                                                 buffer))
                             "mock://three")))
              (should (= (length (seq-filter
                                  (lambda (m)
                                    (equal (alist-get 'type m) "create_view"))
                                  (ladybird-test-log log)))
                         2))
              (should (= (length (ladybird--buffers)) 1))))
        (mapc #'kill-buffer (ladybird--buffers))
        (delete-file log)))))

(ert-deftest ladybird-mock-test-request-cancelled ()
  ;; The server withdraws a request while its prompt is open: the prompt
  ;; closes through the real timers and nothing is answered.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird--last-buffer nil)
         (ladybird--queued-prompts nil)
         (ladybird-device-pixel-ratio 1.0)
         (inhibit-message t)
         (prompted nil)
         (returned nil)
         buffer)
    (save-window-excursion
      (unwind-protect
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (prompt)
                       (setq prompted prompt)
                       ;; Wait as a prompt does, letting timers run.
                       (with-timeout (5 nil)
                         (while t (accept-process-output nil 0.05)))
                       (setq returned t)
                       nil)))
            (setq buffer (ladybird "mock://cancel-confirm"
                                   (ladybird-test-mock-host log)))
            (let ((conn (buffer-local-value 'ladybird--conn buffer))
                  (logged (lambda (type)
                            (seq-find (lambda (m) (equal (alist-get 'type m) type))
                                      (ladybird-test-log log)))))
              (ladybird-test-wait conn (lambda () prompted))
              (should (string-match-p "Mock confirm" prompted))
              ;; The prompt was left without returning, and unanswered.
              (should-not returned)
              (should-not ladybird--prompt)
              ;; The page is still served.
              (with-current-buffer buffer
                (ladybird--request conn "request_selection" `((view . ,ladybird--view))
                                   (lambda (_) (setq returned 'selection))))
              (ladybird-test-wait conn (lambda () (eq returned 'selection)))
              (should-not (funcall logged "dialog_closed"))))
        (mapc #'kill-buffer (ladybird--buffers))
        (delete-file log)))))

(provide 'ladybird-render-test)

;;; ladybird-render-test.el ends here
