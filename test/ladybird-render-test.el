;;; ladybird-render-test.el --- Tests for ladybird.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests of the page buffers: canvas and sizing, mouse and wheel,
;; keys, page and command mode, dialogs and the other page events.  They use
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
    (should (equal (substring-no-properties (ladybird--mode-line-process))
                   ":Page:Loading"))
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
    (should (equal (substring-no-properties (ladybird--mode-line-process))
                   ":Page"))
    (ladybird-command-mode 1)
    (should (equal (substring-no-properties (ladybird--mode-line-process))
                   ":Command"))
    ;; A click on the tag switches the mode of the clicked window's buffer,
    ;; also when another window is selected.
    (let ((map (get-text-property 0 'local-map (ladybird--mode-line-process))))
      (should (eq (lookup-key map [mode-line mouse-1]) #'ladybird-mode-line-toggle)))
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer (selected-window) buffer)
      (let ((page (selected-window))
            (other (split-window)))
        (with-temp-buffer
          (set-window-buffer other (current-buffer))
          (select-window other)
          (ladybird-mode-line-toggle `(mouse-1 (,page mode-line (0 . 0) 0)))
          (should (eq (selected-window) other))
          (should-not (buffer-local-value 'ladybird-command-mode buffer))
          (ladybird-mode-line-toggle `(mouse-1 (,page mode-line (0 . 0) 0)))
          (should (buffer-local-value 'ladybird-command-mode buffer)))))
    (ladybird-command-mode -1)
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
      ;; Every view is told its visibility from a timer the welcome set,
      ;; an undisplayed one that it is hidden.
      (should-not (ladybird-test-sent "set_visibility"))
      (should (timerp ladybird--update-timer))
      (ladybird--update)
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
    (dolist (command-mode '(nil t))
      (ladybird-command-mode (if command-mode 1 -1))
      (should (eq (key-binding [down-mouse-1]) #'ladybird-mouse-down))
      (should (eq (key-binding [C-M-S-s-triple-drag-mouse-3]) #'ladybird-mouse-up))
      (should (eq (key-binding [M-wheel-left]) #'ladybird-wheel))
      (should (eq (key-binding [mouse-movement]) #'ladybird-mouse-move)))
    ;; Command mode scrolls with single keys and the motion keys.
    (dolist (binding '(("n" . ladybird-scroll-down-line) ("p" . ladybird-scroll-up-line)
                       ("SPC" . ladybird-scroll-down-page)
                       ("DEL" . ladybird-scroll-up-page)
                       ("S-SPC" . ladybird-scroll-up-page)
                       ("<" . ladybird-scroll-top) (">" . ladybird-scroll-bottom)
                       ("<down>" . ladybird-scroll-down-line)
                       ("<up>" . ladybird-scroll-up-line)
                       ("<left>" . ladybird-scroll-left)
                       ("<right>" . ladybird-scroll-right)
                       ("<next>" . ladybird-scroll-down-page)
                       ("<prior>" . ladybird-scroll-up-page)
                       ("C-n" . ladybird-scroll-down-line)
                       ("C-p" . ladybird-scroll-up-line)
                       ("C-f" . ladybird-scroll-right)
                       ("C-b" . ladybird-scroll-left)
                       ("C-v" . ladybird-scroll-down-page)
                       ("M-v" . ladybird-scroll-up-page)
                       ("M-<" . ladybird-scroll-top) ("M->" . ladybird-scroll-bottom)))
      (ert-info ((car binding))
        (should (eq (key-binding (kbd (car binding))) (cdr binding)))))
    (ladybird-command-mode -1)))

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


;;; C3: keys, page and command mode, paste

(ert-deftest ladybird-render-test-key-bindings ()
  ;; Page mode: keys go to the page, a few stay with Emacs.
  (ladybird-render-test-with-view
    (should-not ladybird-command-mode)
    (dolist (key '("a" "n" "q" "Q" "o" "é" "!" "0" "-" "SPC" "RET" "TAB" "DEL"
                   "<return>" "<backspace>" "<escape>" "<left>" "C-<left>"
                   "C-M-S-s-<f5>" "S-<return>" "<kp-7>" "<backtab>" "M-<left>"
                   "<home>" "<delete>" "S-<left>" "C-<delete>" "<next>" "<prior>"))
      (ert-info ((format "key %s" key))
        (should (eq (key-binding (kbd key)) #'ladybird-send-key))))
    (dolist (key '("C-a" "C-e" "C-k" "C-d" "M-b" "M-f" "M-d" "M-DEL"
                   "M-<backspace>" "C-<backspace>" "C-z" "C-/" "C-_" "C-?"
                   "C-n" "C-p" "C-b" "C-f" "C-v" "M-v" "M-<" "M->"))
      (ert-info ((format "key %s" key))
        (should (eq (key-binding (kbd key)) #'ladybird-send-edit-key))))
    (dolist (binding '(("C-x C-f" . find-file) ("M-x" . execute-extended-command)
                       ("C-g" . keyboard-quit) ("C-h k" . describe-key)
                       ("C-u" . universal-argument) ("M-:" . eval-expression)
                       ("C-l" . recenter-top-bottom)))
      (ert-info ((car binding))
        (should (eq (key-binding (kbd (car binding))) (cdr binding)))))
    (should (eq (key-binding [xterm-paste]) #'ladybird-xterm-paste))
    (should (eq (key-binding [deletechar]) #'ladybird-send-key))
    (should (eq (key-binding (kbd "C-q")) #'ladybird-send-next-key))
    ;; The keys of `ladybird-emacs-keys' stay with Emacs, also when they are
    ;; in `ladybird-translated-keys' too; a key with a modifier goes on.
    (dolist (key '("<f1>" "<f3>" "<f4>" "<f10>" "<f11>"))
      (ert-info ((format "key %s" key))
        (should (eq (key-binding (kbd key)) (global-key-binding (kbd key))))))
    (should (eq (key-binding (kbd "C-<f1>")) #'ladybird-send-key))
    (unwind-protect
        (let ((ladybird-emacs-keys '("C-a" "<f5>"))
              (ladybird-translated-keys '("C-a" "C-e")))
          (ladybird--rebuild-page-map)
          (should (eq (key-binding (kbd "C-a")) #'move-beginning-of-line))
          (should (eq (key-binding (kbd "<f5>")) (global-key-binding (kbd "<f5>"))))
          (should (eq (key-binding (kbd "C-e")) #'ladybird-send-edit-key))
          (should (eq (key-binding (kbd "<f1>")) #'ladybird-send-key)))
      (ladybird--rebuild-page-map))
    ;; The page's key commands are not offered by M-x.
    (should (eq (function-get 'ladybird-send-key 'completion-predicate) #'ignore))
    (should (eq (function-get 'ladybird-send-edit-key 'completion-predicate) #'ignore))
    ;; An editing key outside the option keeps its Emacs meaning.
    (unwind-protect
        (let ((ladybird-translated-keys nil))
          (ladybird--rebuild-page-map)
          (should (eq (key-binding (kbd "C-a")) #'move-beginning-of-line))
          (should (eq (key-binding (kbd "M-f")) #'forward-word))
          (should (eq (key-binding (kbd "C-n")) #'next-line))
          (should (eq (key-binding "a") #'ladybird-send-key)))
      (ladybird--rebuild-page-map))
    (should (eq (key-binding (kbd "C-a")) #'ladybird-send-edit-key))
    ;; Command mode: single keys are commands, others say how to type.
    (ladybird-command-mode 1)
    (should (eq (key-binding "a") #'ladybird-command-mode-self-insert))
    (should (eq (key-binding "é") #'ladybird-command-mode-self-insert))
    (should (equal (cadr (should-error (ladybird-command-mode-self-insert)
                                       :type 'user-error))
                   "Keys are commands here; i sends them to the page again"))
    (should (eq (key-binding (kbd "<f5>")) #'ladybird-send-key))
    (should (eq (key-binding (kbd "C-a")) #'ladybird-send-edit-key))
    ;; Return and Backspace of a graphical frame do the jobs of RET and DEL.
    (should (eq (key-binding [return]) #'ladybird-page-mode))
    (should (eq (key-binding [kp-enter]) #'ladybird-page-mode))
    (should (eq (key-binding (kbd "RET")) #'ladybird-page-mode))
    (should (eq (key-binding [backspace]) #'ladybird-scroll-up-page))
    (should (eq (key-binding (kbd "DEL")) #'ladybird-scroll-up-page))
    (ladybird-command-mode -1)
    (should (eq (key-binding [return]) #'ladybird-send-key))
    (should (eq (key-binding [backspace]) #'ladybird-send-key))
    (should (eq (key-binding "a") #'ladybird-send-key))))

(ert-deftest ladybird-render-test-modes ()
  ;; C-c C-e and C-c C-j switch, i and RET go back; the option sets
  ;; where a new buffer starts.
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (ladybird-render-test-keys-in-page "C-c C-e")
    (should ladybird-command-mode)
    (ladybird-render-test-keys-in-page "i")
    (should-not ladybird-command-mode)
    (ladybird-render-test-keys-in-page "C-c C-e RET")
    (should-not ladybird-command-mode)
    (ladybird-render-test-keys-in-page "C-c C-e C-c C-j")
    (should-not ladybird-command-mode)
    (ladybird-render-test-keys-in-page "C-c C-e C-c C-e")
    (should-not ladybird-command-mode)
    (ladybird-render-test-keys-in-page "C-c C-j")
    (should-not ladybird-command-mode)
    (should-not (ladybird-test-sent))
    (let ((ladybird-initial-mode 'command))
      (with-current-buffer (ladybird--make-view-buffer conn 2 "mock://2")
        (should ladybird-command-mode)))
    (with-current-buffer (ladybird--make-view-buffer conn 3 "mock://3")
      (should-not ladybird-command-mode))))

(defun ladybird-render-test-keys-in-page (keys)
  "Type KEYS, a string for `kbd', in the page buffer shown in the window."
  (execute-kbd-macro (kbd keys)))

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

(defun ladybird-render-test-key-downs ()
  "Return the keys sent as (KEY CODE-POINT MODIFIERS) of their presses, or text."
  (delq nil (mapcar (lambda (m)
                      (cond ((alist-get 'text m))
                            ((equal (alist-get 'kind m) "down")
                             (list (alist-get 'key m) (alist-get 'code_point m)
                                   (alist-get 'modifiers m)))))
                    (ladybird-test-sent))))

(ert-deftest ladybird-render-test-page-keys ()
  (ladybird-render-test-with-view
    (dolist (last-command-event (list ?H ?! ?\r ?é 'C-left 'lshift))
      (ladybird-send-key))
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
                     ("down" "Left" 0 2) ("up" "Left" 0 2))))
    ;; Typed through the command loop, with no mode to switch first.
    (ladybird-render-test-show)
    (ladybird-render-test-keys-in-page "H i SPC 5 - q RET <f5>")
    (should (equal (ladybird-render-test-key-downs)
                   '(("H" 72 1) ("I" 105 0) ("Space" 32 0) ("5" 53 0)
                     ("Minus" 45 0) ("Q" 113 0) ("Return" 10 0) ("F5" 0 0))))
    ;; A numeric prefix argument repeats a key; C-u stays Emacs's.
    (setq ladybird-test-sent nil)
    (ladybird-render-test-keys-in-page "C-u 3 a C-u C-n")
    (should (equal (ladybird-render-test-key-downs)
                   '(("A" 97 0) ("A" 97 0) ("A" 97 0)
                     ("Down" 0 0) ("Down" 0 0) ("Down" 0 0) ("Down" 0 0))))
    ;; A keyboard macro replays the keys.
    (setq ladybird-test-sent nil)
    (let ((last-kbd-macro (kbd "x y")))
      (execute-kbd-macro last-kbd-macro 2))
    (should (equal (mapcar #'car (ladybird-render-test-key-downs))
                   '("X" "Y" "X" "Y")))
    ;; ESC and a key, as a terminal sends Meta, is the Meta key.
    (setq ladybird-test-sent nil)
    (ladybird-render-test-keys-in-page "ESC b ESC f")
    (should (equal (ladybird-render-test-key-downs) '(("Left" 0 2) ("Right" 0 2))))))

(defun ladybird-render-test-edit-keys (&rest keys)
  "Run `ladybird-send-edit-key' for each of KEYS; return what was sent.
A key press is (KEY MODIFIERS), an edit message its operation."
  (setq ladybird-test-sent nil)
  (dolist (key keys)
    (let ((last-command-event (aref (key-parse key) 0)))
      (ladybird-send-edit-key)))
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
    (should (equal (ladybird-render-test-edit-keys
                    "C-n" "C-p" "C-b" "C-f" "C-v" "M-v" "M-<" "M->")
                   '(("Down" 0) ("Up" 0) ("Left" 0) ("Right" 0)
                     ("PageDown" 0) ("PageUp" 0) ("Home" 2) ("End" 2))))
    ;; Every press is released.
    (ladybird-render-test-edit-keys "C-k")
    (should (equal (mapcar (lambda (m) (alist-get 'kind m)) (ladybird-test-sent))
                   '("down" "up" "down" "up")))
    ;; A server on macOS moves and deletes by words with the alt key and
    ;; reaches the ends with the command key.
    (setf (ladybird--conn-server-info conn)
          '((host . ((hostname . "mac") (platform . "macos")))))
    (should (eq (ladybird--platform) 'macos))
    (should (equal (ladybird-render-test-edit-keys
                    "C-a" "C-e" "C-k" "M-b" "M-f" "M-d" "M-DEL" "M-<backspace>"
                    "C-<backspace>" "C-z")
                   '(("Home" 0) ("End" 0) ("End" 1) ("Delete" 0) ("Left" 4)
                     ("Right" 4) ("Delete" 4) ("Backspace" 4) ("Backspace" 4)
                     ("Backspace" 4) "undo")))
    (should (equal (ladybird-render-test-edit-keys
                    "C-n" "C-p" "C-b" "C-f" "C-v" "M-v" "M-<" "M->")
                   '(("Down" 0) ("Up" 0) ("Left" 0) ("Right" 0)
                     ("PageDown" 0) ("PageUp" 0) ("Up" 8) ("Down" 8))))
    ;; A key without a translation goes as it is.
    (should (equal (ladybird-render-test-edit-keys "C-o") '(("O" 2))))))

(ert-deftest ladybird-render-test-send-next-key ()
  ;; C-c C-q sends the next key as it is, whatever Emacs binds it to.
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (let ((keys nil)
          (sequence nil))
      (cl-letf (((symbol-function 'read-key)
                 (lambda (&rest _)
                   (setq sequence (vconcat keys))
                   (prog1 (car keys) (setq keys nil))))
                ((symbol-function 'this-command-keys-vector)
                 (lambda () sequence)))
        (dolist (case `((,(aref (kbd "C-x") 0) ("X" 120 2))
                        (?\C-g ("G" 103 2))
                        (,(aref (kbd "C-s") 0) ("S" 115 2))
                        (,(aref (kbd "C-a") 0) ("A" 97 2))
                        (f5 ("F5" 0 0))
                        (,(aref (kbd "M-x") 0) ("X" 120 4))))
          (setq keys (list (car case))
                ladybird-test-sent nil)
          (ladybird-send-next-key)
          (should (equal (ladybird-render-test-key-downs) (list (cadr case)))))
        ;; ESC and a key read as one sequence, as a terminal sends Meta.
        (setq keys (list ?\e ?x) ladybird-test-sent nil)
        (ladybird-send-next-key)
        (should (equal (ladybird-render-test-key-downs) '(("X" 120 4))))
        ;; A lone ESC is Escape.
        (setq keys (list ?\e) ladybird-test-sent nil)
        (ladybird-send-next-key)
        (should (equal (ladybird-render-test-key-downs) '(("Escape" 27 0))))
        ;; A prefix argument repeats it.
        (setq keys (list ?\C-x) ladybird-test-sent nil)
        (ladybird-send-next-key 2)
        (should (= (length (ladybird-render-test-key-downs)) 2))
        ;; A mouse event is handled as usual.
        (let ((unread-command-events nil)
              (click `(mouse-1 ,(ladybird-render-test-posn 3 3))))
          (setq keys (list click) ladybird-test-sent nil)
          (ladybird-send-next-key)
          (should-not (ladybird-test-sent))
          (should (equal unread-command-events (list click))))))
    ;; In a graphical frame the event is read as it is, past mouse movement.
    (let ((events (list `(mouse-movement ,(ladybird-render-test-posn 1 1)) ?\C-x)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'read-event) (lambda (&rest _) (pop events))))
        (setq ladybird-test-sent nil)
        (ladybird-send-next-key)
        (should (equal (ladybird-render-test-key-downs) '(("X" 120 2))))))
    ;; Through the command loop.
    (setq ladybird-test-sent nil)
    (ladybird-render-test-keys-in-page "C-c C-q C-s a C-c C-q C-c")
    (should (equal (ladybird-render-test-key-downs)
                   '(("S" 115 2) ("A" 97 0) ("C" 99 2))))))

(ert-deftest ladybird-render-test-focus-and-zoom ()
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (ladybird-render-test-keys-in-page "C-c C-n C-u 2 C-c C-p")
    (should (equal (ladybird-render-test-key-downs)
                   '(("Tab" 9 0) ("Tab" 9 1) ("Tab" 9 1))))
    ;; C-x C-+ zooms, and + - 0 alone go on zooming as text-scale-adjust
    ;; does; the next other key goes to the page again.
    (setq ladybird-test-sent nil)
    (ladybird-render-test-keys-in-page
     "C-x C-+ + = - 0 C-x C-- C-x C-0 C-x C-= <kp-add> <kp-subtract> <kp-0> a")
    (should (equal (mapcar (lambda (m) (or (alist-get 'op m) (alist-get 'key m)))
                           (seq-filter (lambda (m)
                                         (member (alist-get 'kind m) '(nil "down")))
                                       (ladybird-test-sent)))
                   '("in" "in" "in" "out" "reset" "out" "reset" "in" "in" "out" "reset"
                     "A")))))

(ert-deftest ladybird-render-test-describe-mode ()
  ;; C-h m lists the commands, not the generated mouse and key bindings.
  (ladybird-render-test-with-view
    (dolist (command-mode '(nil t))
      (ladybird-command-mode (if command-mode 1 -1))
      (save-window-excursion
        (let ((help-window-select nil))
          (describe-mode buffer)
          (with-current-buffer (help-buffer)
            (let* ((end (save-excursion
                          (goto-char (point-min))
                          (if (re-search-forward "^Global minor mode" nil t)
                              (match-beginning 0)
                            (point-max))))
                   (text (buffer-substring-no-properties (point-min) end)))
              (ert-info ((format "command mode %s:\n%s" command-mode text))
                (should (string-match-p "C-c C-o  activate a link" text))
                (should-not (string-match-p
                             "down-mouse\\|wheel-\\|kp-[0-9]\\|kp-add\\|mouse-movement\\|<f5>"
                             text))
                (should (< (length (string-lines text)) (if command-mode 130 80)))
                (should (equal (string-match-p "q\t+ladybird-quit" text)
                               (and command-mode
                                    (string-match-p "q\t+ladybird-quit" text))))))))))
    (ladybird-command-mode -1)))

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
        (dolist (case '((("allow once") . "allow_once")
                        (("allow always") . "allow_always")
                        (("deny") . "deny")
                        ;; Nothing chosen.
                        (("") . "dismiss")
                        ((quit) . "dismiss")
                        ;; A part of a choice, or text typed for the page,
                        ;; answers nothing: the question is asked again.
                        (("d" "a" "allow a" "") . "dismiss")
                        (("d" "deny") . "deny")))
          (setq ladybird-test-sent nil
                ladybird-render-test-asked nil)
          (let ((answers (car case)))
            (ladybird-render-test-answering (pop answers)
              (ladybird-test-receive conn request)))
          (should (equal (ladybird-test-sent)
                         `(((type . "permission_closed") (view . 1) (id . 5)
                            (outcome . ,(cdr case))))))
          ;; Every question discards the keys typed before it.
          (should (= (seq-count (lambda (entry) (eq entry 'discard-input))
                                ladybird-render-test-asked)
                     (length (car case)))))
        ;; The answer is typed or completed in full: no require-match
        ;; that would complete a part of a choice on RET.
        (should (equal (take 2 (last ladybird-render-test-asked 2))
                       '(("Allow geolocation for https://example.org? \
(allow once, allow always, deny) "
                          ("allow once" "allow always" "deny") nil)
                         discard-input)))
        (should (equal (car (car ladybird-render-test-asked))
                       "Type a choice in full: Allow geolocation for \
https://example.org? (allow once, allow always, deny) "))
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
                        ("deny" . nil) ("" . nil) (quit . nil)))
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
                          ("open on server" "open here" "deny") nil)
                         discard-input)))
        ;; A part of a choice is asked again.
        (setq ladybird-test-sent nil)
        (let ((answers (list "o" "open " "open on server")))
          (ladybird-render-test-answering (pop answers)
            (ladybird-test-receive conn (funcall request "mailto:a@example.org"))))
        (should (equal (alist-get 'open (car (ladybird-test-sent))) t))
        ;; Only web and mail addresses are opened here: for anything else
        ;; that choice is not offered, and it is refused if it is made.
        (dolist (url '("file:///etc/passwd" "javascript:alert(1)"
                       "x-apple-reminder://x" "/Applications/Calculator.app"
                       " https://example.org" "ssh://host"))
          (setq opened nil
                ladybird-test-sent nil
                ladybird-render-test-asked nil)
          (let ((answers (list "open here" "")))
            (ladybird-render-test-answering (pop answers)
              (ladybird-test-receive conn (funcall request url))))
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
                  (kind . "link") (link_url . "https://example.org/linked")
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
      (should (equal (current-kill 0) "https://example.org/linked"))
      (should (equal (ladybird-test-sent)
                     '(((type . "load") (view . 1) (url . "https://example.org/linked"))
                       ((type . "load") (view . 1) (url . "chosen words"))
                       ((type . "paste") (view . 1) (text . "https://example.org/linked"))
                       ((type . "edit") (view . 1) (op . "cut"))
                       ((type . "history") (view . 1) (delta . -1))
                       ((type . "reload") (view . 1) (bypass_cache))))))
      ;; A link is loaded only with http or https, or with file from a file.
      (ladybird-render-test-prompting
        (dolist (case '(("file:///etc/passwd" "https://example.org/" nil)
                        ("javascript:alert(1)" "https://example.org/" nil)
                        ("mock://linked" "mock://one" nil)
                        ("HTTP://example.org/" "about:blank" t)
                        ("file:///tmp/b.html" "file:///tmp/a.html" t)))
          (pcase-let ((`(,link ,page ,loaded) case))
            (dolist (label '("Open Link" "Open Link in New Buffer"))
              (ert-info ((format "%s %s from %s" label link page))
                (setq ladybird-test-sent nil
                      ladybird--state `((url . ,page)))
                (let ((messages
                       (ladybird-render-test-messages
                         (cl-letf (((symbol-function 'x-popup-menu)
                                    (lambda (_position menu)
                                      (cdr (assoc label (cdr (cadr menu)))))))
                           (ladybird-test-receive
                            conn `((type . "context_menu") (view . 1) (x . 1) (y . 2)
                                   (kind . "link") (link_url . ,link)))))))
                  (if loaded
                      (should (equal (alist-get 'url (car (ladybird-test-sent)))
                                     link))
                    (should-not (ladybird-test-sent))
                    (should (equal messages
                                   (list (concat "ladybird: not opening " link)))))
                  (mapc #'kill-buffer (remq buffer (ladybird--buffers)))))))))))

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
  (skip-unless (image-type-available-p 'png))
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
    ;; A prefix argument bypasses the cache.
    (setq ladybird-test-sent nil)
    (ladybird-reload '(4))
    (should (equal (ladybird-test-sent)
                   '(((type . "reload") (view . 1) (bypass_cache . t)))))
    ;; The C-c commands, in both modes.
    (dolist (command-mode '(nil t))
      (ladybird-command-mode (if command-mode 1 -1))
      (dolist (binding '(("C-c C-l" . ladybird-goto-url)
                         ("C-c C-o" . ladybird-follow-hint)
                         ("C-c C-b" . ladybird-back) ("C-c C-f" . ladybird-forward)
                         ("C-c C-r" . ladybird-reload) ("C-c C-k" . ladybird-stop)
                         ("C-c C-w" . ladybird-copy-url)
                         ("C-c C-t" . ladybird-toggle-console)
                         ("C-c C-n" . ladybird-focus-next)
                         ("C-c C-p" . ladybird-focus-previous)
                         ("C-c C-q" . ladybird-send-next-key)
                         ("C-c C-y" . ladybird-yank) ("C-y" . ladybird-yank)
                         ("C-c C-e" . ladybird-command-mode)
                         ("C-c C-j" . ladybird-page-mode)
                         ("C-s" . ladybird-find) ("C-r" . ladybird-find-backward)
                         ("M-s n" . ladybird-find-next)
                         ("M-s p" . ladybird-find-previous)
                         ("M-w" . ladybird-copy-selection)
                         ("C-x h" . ladybird-select-all)
                         ("C-x C-+" . ladybird-zoom-adjust)
                         ("C-x C-=" . ladybird-zoom-adjust)
                         ("C-x C--" . ladybird-zoom-adjust)
                         ("C-x C-0" . ladybird-zoom-adjust)))
        (ert-info ((format "%s in %s mode" (car binding)
                           (if command-mode "command" "page")))
          (should (eq (key-binding (kbd (car binding))) (cdr binding))))))
    ;; The single keys of command mode.
    (dolist (binding '(("l" . ladybird-goto-url) ("g" . ladybird-goto-url)
                       ("r" . ladybird-reload) ("R" . ladybird-reload-bypass-cache)
                       ("s" . ladybird-stop) ("b" . ladybird-back)
                       ("f" . ladybird-forward) ("+" . ladybird-zoom-in)
                       ("=" . ladybird-zoom-in) ("-" . ladybird-zoom-out)
                       ("0" . ladybird-zoom-reset) ("w" . ladybird-copy-url)
                       ("c" . ladybird-new-buffer) ("S" . ladybird-screenshot)
                       ("o" . ladybird-follow-hint) ("q" . ladybird-quit)
                       ("Q" . ladybird-close) ("i" . ladybird-page-mode)
                       ("RET" . ladybird-page-mode)))
      (should (eq (key-binding (kbd (car binding))) (cdr binding))))
    (ladybird-command-mode -1)))

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


;;; Hints

(defconst ladybird-render-test-hint-items
  '(((index . 0) (label . "aa") (kind . "link") (text . "Home")
     (url . "https://example.org/home"))
    ((index . 1) (label . "as") (kind . "button") (text . "Send"))
    ((index . 2) (label . "ad") (kind . "input") (text . "Name"))
    ((index . 3) (label . "sa") (kind . "other") (text . ""))
    ((index . 4) (label . "sd") (kind . "link") (text . "  ")
     (url . "https://example.org/bare")))
  "The items of the hint lists of the tests.")

(defvar ladybird-render-test-beeps 0 "Number of times a test rang the bell.")

(defmacro ladybird-render-test-with-hints (&rest body)
  "Run BODY in a shown page buffer on a server that offers hints.
The keys typed go through the command loop; `ding' counts in
`ladybird-render-test-beeps'.  The hint session ends afterwards."
  (declare (indent 0) (debug t))
  `(ladybird-render-test-with-view
     (let ((ladybird--hint nil)
           (ladybird--hint-shown nil)
           (ladybird-hint-alphabet "asdfghjkl")
           (ladybird-render-test-beeps 0)
           (minibuffer-setup-hook minibuffer-setup-hook)
           (pre-command-hook pre-command-hook)
           (emulation-mode-map-alists emulation-mode-map-alists))
       (setf (ladybird--conn-server-info conn)
             (append '((features . ["hints"])) (ladybird--conn-server-info conn)))
       (ladybird-render-test-show)
       (unwind-protect
           (cl-letf (((symbol-function 'ding)
                      (lambda (&rest _) (cl-incf ladybird-render-test-beeps))))
             ,@body)
         (ladybird--hint-stop)
         (setq ladybird-command-mode nil)))))

(defmacro ladybird-render-test-hint-messages (&rest body)
  "Run BODY and return the messages it showed that are not empty."
  (declare (indent 0) (debug t))
  `(remove "" (ladybird-render-test-messages ,@body)))

(defun ladybird-render-test-keys (keys)
  "Type KEYS, a string for `kbd' or a vector of events."
  (execute-kbd-macro (if (stringp keys) (kbd keys) keys)))

(defun ladybird-render-test-hint-id ()
  "Return the id of the last `hints' sent."
  (alist-get 'id (car (last (ladybird-test-sent "hints")))))

(defun ladybird-render-test-hints-list (&optional id items truncated)
  "Return a `hints_list' for view 1 with ID, ITEMS and TRUNCATED.
ID defaults to the last one sent, ITEMS to the test items."
  `((type . "hints_list") (view . 1)
    (id . ,(or id (ladybird-render-test-hint-id)))
    (items . ,(vconcat (or items ladybird-render-test-hint-items)))
    (truncated . ,(ladybird--bool truncated))))

(defun ladybird-render-test-hint-start (&optional keys)
  "Start hints with KEYS, by default C-c C-o, and answer them; return the id."
  (ladybird-render-test-keys (or keys "C-c C-o"))
  (let ((id (ladybird-render-test-hint-id)))
    (ladybird-test-receive ladybird--conn (ladybird-render-test-hints-list id))
    (setq ladybird-test-sent nil)
    id))

(defun ladybird-render-test-take-up ()
  "Run the timers that take up what was typed before the labels came."
  (dolist (timer timer-list)
    (when (eq (timer--function timer) #'ladybird--hint-take-up)
      (cancel-timer timer)
      (apply #'ladybird--hint-take-up (timer--args timer)))))

(defun ladybird-render-test-hint-map-active-p ()
  "Return non-nil if `ladybird-hint-map' is active."
  (eq (key-binding "z") #'ladybird-hint-add-char))

(ert-deftest ladybird-render-test-hint-bindings ()
  (ladybird-render-test-with-view
    (should (eq (key-binding (kbd "C-c C-o")) #'ladybird-follow-hint))
    (should (eq (key-binding "o") #'ladybird-send-key))
    (ladybird-command-mode 1)
    (should (eq (key-binding (kbd "C-c C-o")) #'ladybird-follow-hint))
    (should (eq (key-binding "o") #'ladybird-follow-hint))
    (ladybird-command-mode -1))
  (dolist (key '("a" "z" "0" "A" "é" "SPC" "!"))
    (should (eq (lookup-key ladybird-hint-map (kbd key)) #'ladybird-hint-add-char)))
  (should (eq (lookup-key ladybird-hint-map (kbd "DEL")) #'ladybird-hint-delete-char))
  (should (eq (lookup-key ladybird-hint-map [backspace]) #'ladybird-hint-delete-char))
  (should (eq (lookup-key ladybird-hint-map (kbd "C-g")) #'ladybird-hint-quit))
  (should (eq (lookup-key ladybird-hint-map [escape]) #'ladybird-hint-quit))
  ;; Meta keys, ESC, control keys and mouse events are not the map's.
  (dolist (key (list (kbd "M-x") (kbd "ESC") (kbd "C-x") (kbd "RET") [mouse-1]
                     [wheel-down]))
    (should-not (lookup-key ladybird-hint-map key)))
  (should (equal (default-value 'ladybird-hint-alphabet) "asdfghjkl"))
  (dolist (good '("asdfghjkl" "ab" "0123456789" "abcdefghijklmnopqrstuvwxyz0123456789"))
    (should (ladybird--hint-alphabet-p good)))
  (dolist (bad '("a" "" "aa" "aB" "AB" "a b" "ab-" "äb"
                 "abcdefghijklmnopqrstuvwxyz0123456789x" nil ab))
    (should-not (ladybird--hint-alphabet-p bad))))

(ert-deftest ladybird-render-test-hint-narrow ()
  (ladybird-render-test-with-hints
    (let ((messages (ladybird-render-test-hint-messages (ladybird-render-test-keys "C-c C-o"))))
      (should (equal messages '("Hint:   [waiting for the labels]"))))
    (let ((id (ladybird-render-test-hint-id)))
      (should (equal (ladybird-test-sent)
                     `(((type . "hints") (view . 1) (id . ,id)
                        (alphabet . "asdfghjkl")))))
      (should (ladybird-render-test-hint-map-active-p))
      (setq ladybird-test-sent nil)
      (should (equal (ladybird-render-test-hint-messages
                       (ladybird-test-receive conn (ladybird-render-test-hints-list id)))
                     '("Hint:   [5 left]")))
      ;; Each character narrows.
      (should (equal (ladybird-render-test-hint-messages (ladybird-render-test-keys "s"))
                     '("Hint: s  [2 left]")))
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_narrow") (view . 1) (id . ,id)
                        (prefix . "s")))))
      ;; A character in no remaining label is refused and changes nothing.
      (setq ladybird-test-sent nil)
      (dolist (key '("s" "x" "SPC" "é"))
        (ladybird-render-test-keys key))
      (should (= ladybird-render-test-beeps 4))
      (should-not (ladybird-test-sent))
      (should (equal (ladybird--hint-prefix ladybird--hint) "s"))
      ;; DEL takes the last character back, and beeps with nothing to take.
      (ladybird-render-test-keys "DEL")
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_narrow") (view . 1) (id . ,id)
                        (prefix . "")))))
      (ladybird-render-test-keys "DEL")
      (should (= ladybird-render-test-beeps 5))
      (should (= (length (ladybird-test-sent)) 1))
      ;; An upper case letter is taken as lower case; <backspace> is DEL.
      (setq ladybird-test-sent nil)
      (ladybird-render-test-keys "A")
      (should (equal (ladybird--hint-prefix ladybird--hint) "a"))
      (ladybird-render-test-keys "<backspace>")
      (should (equal (mapcar (lambda (m) (alist-get 'prefix m)) (ladybird-test-sent))
                     '("a" "")))
      (should (equal (ladybird--hint-id ladybird--hint) id)))))

(ert-deftest ladybird-render-test-hint-keypad ()
  ;; The keypad's digits are label characters too.
  (ladybird-render-test-with-hints
    (let ((ladybird-hint-alphabet "12"))
      (ladybird-render-test-keys "C-c C-o")
      (let ((id (ladybird-render-test-hint-id)))
        (ladybird-test-receive
         conn (ladybird-render-test-hints-list
               id '(((index . 0) (label . "11") (kind . "button"))
                    ((index . 1) (label . "12") (kind . "button")))))
        (setq ladybird-test-sent nil)
        (ladybird-render-test-keys "<kp-1> <kp-2>")
        (should (equal (ladybird-test-sent)
                       `(((type . "hints_narrow") (view . 1) (id . ,id) (prefix . "1"))
                         ((type . "hints_end") (view . 1) (id . ,id)
                          (activate . 1)))))))))

(ert-deftest ladybird-render-test-hint-prompt ()
  (ladybird-render-test-with-hints
    (ladybird-render-test-hint-start)
    (should (equal (ladybird-render-test-hint-messages (ladybird-render-test-keys "s"))
                   '("Hint: s  [2 left]")))
    (ladybird-render-test-keys "DEL")
    (let ((ladybird-render-test-hint-items
           (list (car ladybird-render-test-hint-items)
                 (nth 4 ladybird-render-test-hint-items))))
      (ladybird-render-test-keys "C-g")
      (ladybird-render-test-keys "C-c C-o")
      (should (equal (ladybird-render-test-hint-messages
                       (ladybird-test-receive conn (ladybird-render-test-hints-list))
                       (ladybird-render-test-keys "s"))
                     '("Hint:   [2 left]" "Hint: s  [1 left] https://example.org/bare")))
      (ladybird-render-test-keys "DEL")
      (should (equal (ladybird-render-test-hint-messages (ladybird-render-test-keys "a"))
                     '("Hint: a  [1 left] Home"))))
    ;; A list the server cut says so; a prefix argument says where links go.
    (ladybird-render-test-keys "C-g")
    (ladybird-render-test-keys "C-u C-c C-o")
    (should (equal (ladybird-render-test-hint-messages
                     (ladybird-test-receive
                      conn (ladybird-render-test-hints-list nil nil t)))
                   '("Hint (new buffer):   [5 left, more not labelled]")))
    ;; Hover and find messages leave the prompt alone.
    (should-not (ladybird-render-test-hint-messages
                  (ladybird-test-receive conn '((type . "link_hover") (view . 1)
                                                (url . "mock://hovered")))))))

(ert-deftest ladybird-render-test-hint-activate ()
  (ladybird-render-test-with-hints
    (let ((id (ladybird-render-test-hint-start)))
      (ladybird-render-test-keys "a")
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_narrow") (view . 1) (id . ,id)
                        (prefix . "a")))))
      (setq ladybird-test-sent nil)
      (ladybird-render-test-keys "s")
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_end") (view . 1) (id . ,id) (activate . 1)))))
      (should-not ladybird--hint)
      (should-not (ladybird-render-test-hint-map-active-p))
      (should-not (memq #'ladybird--hint-minibuffer minibuffer-setup-hook))
      (should-not ladybird-command-mode)
      ;; The keys go to the page again.
      (setq ladybird-test-sent nil)
      (ladybird-render-test-keys "n")
      (should (equal (alist-get 'key (car (ladybird-test-sent))) "N")))
    ;; Index 0 is activated as any other; a link loads in the page.
    (let ((id (ladybird-render-test-hint-start)))
      (ladybird-render-test-keys "aa")
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_narrow") (view . 1) (id . ,id) (prefix . "a"))
                       ((type . "hints_end") (view . 1) (id . ,id)
                        (activate . 0))))))))

(ert-deftest ladybird-render-test-hint-input ()
  ;; A text field leaves command mode, so that keys go to it.
  (ladybird-render-test-with-hints
    (ladybird-command-mode 1)
    (let ((id (ladybird-render-test-hint-start)))
      (ladybird-render-test-keys "ad")
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_narrow") (view . 1) (id . ,id) (prefix . "a"))
                       ((type . "hints_end") (view . 1) (id . ,id) (activate . 2)))))
      (should-not ladybird-command-mode)
      (setq ladybird-test-sent nil)
      (ladybird-render-test-keys "x")
      (should (equal (alist-get 'key (car (ladybird-test-sent))) "X")))
    (setq ladybird-test-sent nil)
    (let ((id (ladybird-render-test-hint-start "C-c C-o")))
      ;; Characters are the label's, not the page's, until it is complete.
      (ladybird-render-test-keys "sa")
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_narrow") (view . 1) (id . ,id) (prefix . "s"))
                       ((type . "hints_end") (view . 1) (id . ,id) (activate . 3)))))
      (should-not ladybird-command-mode))))

(ert-deftest ladybird-render-test-hint-new-buffer ()
  (ladybird-render-test-with-hints
    (let ((id (ladybird-render-test-hint-start "C-u C-c C-o")))
      (ladybird-render-test-keys "aa")
      (should (equal (ladybird-test-sent "hints_end")
                     `(((type . "hints_end") (view . 1) (id . ,id) (activate)))))
      (let ((create (car (ladybird-test-sent "create_view"))))
        (should (equal (alist-get 'url create) "https://example.org/home")))
      (should (= (length (ladybird--buffers conn)) 2))
      (should-not (eq (window-buffer) buffer))
      (set-window-buffer (selected-window) buffer))
    ;; Anything but a link is activated in the page.
    (setq ladybird-test-sent nil)
    (let ((id (ladybird-render-test-hint-start "C-u C-c C-o")))
      (ladybird-render-test-keys "as")
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_narrow") (view . 1) (id . ,id) (prefix . "a"))
                       ((type . "hints_end") (view . 1) (id . ,id) (activate . 1)))))
      (should-not (ladybird-test-sent "create_view")))))

(ert-deftest ladybird-render-test-hint-cancel ()
  (ladybird-render-test-with-hints
    (dolist (key (list "C-g" [escape]))
      (ert-info ((format "key %S" key))
        (let ((id (ladybird-render-test-hint-start)))
          (ladybird-render-test-keys "s")
          (setq ladybird-test-sent nil)
          (ladybird-render-test-keys key)
          (should (equal (ladybird-test-sent)
                         `(((type . "hints_end") (view . 1) (id . ,id)
                            (activate)))))
          (should-not ladybird--hint)
          (should-not (ladybird-render-test-hint-map-active-p))
          (setq ladybird-test-sent nil))))
    ;; While the labels are awaited too.
    (ladybird-render-test-keys "C-c C-o")
    (let ((id (ladybird-render-test-hint-id)))
      (setq ladybird-test-sent nil)
      (ladybird-render-test-keys "C-g")
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_end") (view . 1) (id . ,id) (activate)))))
      ;; Its list comes late and is ignored.
      (ladybird-test-receive conn (ladybird-render-test-hints-list id))
      (should-not ladybird--hint)
      (should-not (ladybird-render-test-hint-map-active-p)))))

(ert-deftest ladybird-render-test-hint-other-events ()
  ;; A key or event that is not a character ends the hints and does what
  ;; it does otherwise; mouse movement does not end them.
  (ladybird-render-test-with-hints
    (let ((id (ladybird-render-test-hint-start)))
      (ladybird-render-test-keys
       (vector (list 'mouse-movement (ladybird-render-test-posn 5 6))))
      (should ladybird--hint)
      (should (equal (mapcar (lambda (m) (alist-get 'kind m)) (ladybird-test-sent))
                     '("move")))
      (setq ladybird-test-sent nil)
      (ladybird-render-test-keys
       (vector (list 'wheel-down (ladybird-render-test-posn 5 6))))
      (should-not ladybird--hint)
      (should-not (ladybird-render-test-hint-map-active-p))
      (should (equal (mapcar (lambda (m) (or (alist-get 'kind m) (alist-get 'type m)))
                             (ladybird-test-sent))
                     '("hints_end" "wheel")))
      (should (equal (alist-get 'id (car (ladybird-test-sent))) id)))
    (setq ladybird-test-sent nil)
    (ladybird-render-test-hint-start)
    (ladybird-render-test-keys
     (vector (list 'down-mouse-1 (ladybird-render-test-posn 5 6))
             (list 'mouse-1 (ladybird-render-test-posn 5 6))))
    (should (equal (mapcar (lambda (m) (or (alist-get 'kind m) (alist-get 'type m)))
                           (ladybird-test-sent))
                   '("hints_end" "down" "up")))
    (setq ladybird-test-sent nil
          track-mouse nil)
    ;; A control key: RET goes to the page.
    (ladybird-render-test-hint-start)
    (ladybird-render-test-keys "RET")
    (should-not ladybird--hint)
    (should (equal (mapcar (lambda (m) (or (alist-get 'key m) (alist-get 'type m)))
                           (ladybird-test-sent))
                   '("hints_end" "Return" "Return")))))

(ert-deftest ladybird-render-test-hint-second ()
  ;; A second `ladybird-follow-hint' ends the first session.
  (ladybird-render-test-with-hints
    (let ((first (ladybird-render-test-hint-start)))
      (ladybird-render-test-keys "C-c C-o")
      (let ((second (ladybird-render-test-hint-id)))
        (should-not (equal first second))
        (should (equal (ladybird-test-sent)
                       `(((type . "hints_end") (view . 1) (id . ,first) (activate))
                         ((type . "hints") (view . 1) (id . ,second)
                          (alphabet . "asdfghjkl")))))
        ;; A late answer for the first is ignored, the second's is taken.
        (ladybird-test-receive conn (ladybird-render-test-hints-list first))
        (should (ladybird--hint-waiting ladybird--hint))
        (ladybird-test-receive conn (ladybird-render-test-hints-list second))
        (should-not (ladybird--hint-waiting ladybird--hint))
        (should (= (length (ladybird--hint-items ladybird--hint)) 5))
        ;; Calling the command directly does the same.
        (setq ladybird-test-sent nil)
        (ladybird-follow-hint)
        (should (equal (mapcar (lambda (m) (alist-get 'type m)) (ladybird-test-sent))
                       '("hints_end" "hints")))
        (should (equal (alist-get 'id (car (ladybird-test-sent))) second))
        (should (= (seq-count (lambda (entry) (eq entry 'ladybird--hint-map-alist))
                              emulation-mode-map-alists)
                   1))))))

(ert-deftest ladybird-render-test-hint-typed-ahead ()
  ;; Characters typed before the labels arrive are taken up then.
  (ladybird-render-test-with-hints
    (ladybird-render-test-keys "C-c C-o")
    (let ((id (ladybird-render-test-hint-id)))
      (setq ladybird-test-sent nil)
      (should (equal (ladybird-render-test-hint-messages (ladybird-render-test-keys "a"))
                     '("Hint: a  [waiting for the labels]")))
      (ladybird-render-test-keys "DEL s x")
      (should-not (ladybird-test-sent))
      (should (equal (ladybird--hint-prefix ladybird--hint) "sx"))
      (ladybird-test-receive conn (ladybird-render-test-hints-list id))
      ;; They are taken up from a timer, not in the process filter.
      (should-not (ladybird-test-sent))
      (should (ladybird--hint-waiting ladybird--hint))
      (ladybird-render-test-take-up)
      (should (= ladybird-render-test-beeps 1))
      (should (equal (ladybird-test-sent)
                     `(((type . "hints_narrow") (view . 1) (id . ,id)
                        (prefix . "s")))))
      (should (equal (ladybird--hint-prefix ladybird--hint) "s"))
      (setq ladybird-test-sent nil)
      ;; Typed ahead in full, a label is activated at once.
      (ladybird-render-test-keys "C-g C-c C-o s d")
      (let ((id (ladybird-render-test-hint-id)))
        (setq ladybird-test-sent nil)
        (ladybird-test-receive conn (ladybird-render-test-hints-list id))
        (should-not (ladybird-test-sent))
        (ladybird-render-test-take-up)
        (should (equal (ladybird-test-sent)
                       `(((type . "hints_narrow") (view . 1) (id . ,id) (prefix . "s"))
                         ((type . "hints_end") (view . 1) (id . ,id)
                          (activate . 4)))))
        (should-not ladybird--hint)))))

(ert-deftest ladybird-render-test-hint-empty ()
  (ladybird-render-test-with-hints
    (ladybird-render-test-keys "C-c C-o")
    (setq ladybird-test-sent nil)
    (should (equal (ladybird-render-test-hint-messages
                     (ladybird-test-receive
                      conn `((type . "hints_list") (view . 1)
                             (id . ,(ladybird--hint-id ladybird--hint))
                             (items . []) (truncated . :false))))
                   '("No hints in view")))
    (should-not ladybird--hint)
    (should-not (ladybird-render-test-hint-map-active-p))
    ;; The session is over: nothing is sent.
    (should-not (ladybird-test-sent))))

(ert-deftest ladybird-render-test-hint-cancelled ()
  (ladybird-render-test-with-hints
    (let ((id (ladybird-render-test-hint-start)))
      (ladybird-render-test-keys "a")
      (setq ladybird-test-sent nil)
      ;; Another view's or another id's end is not the session's, and
      ;; `request_cancelled' is for prompts only.
      (ladybird-test-receive conn `((type . "hints_cancelled") (view . 2)
                                    (id . ,id)))
      (ladybird-test-receive conn `((type . "hints_cancelled") (view . 1)
                                    (id . ,(1+ id))))
      (ladybird-test-receive conn `((type . "request_cancelled") (view . 1)
                                    (id . ,id)))
      (should ladybird--hint)
      (should (ladybird-render-test-hint-map-active-p))
      (should (equal (ladybird-render-test-hint-messages
                       (ladybird-test-receive conn `((type . "hints_cancelled")
                                                     (view . 1) (id . ,id))))
                     '("The page ended the hint session")))
      (should-not ladybird--hint)
      (should-not (ladybird-render-test-hint-map-active-p))
      (should-not (ladybird-test-sent))
      ;; Keys go to the page again.
      (ladybird-render-test-keys "s")
      (should (equal (alist-get 'key (car (ladybird-test-sent))) "S")))
    ;; It can come in place of the labels.
    (setq ladybird-test-sent nil)
    (ladybird-render-test-keys "C-c C-o")
    (let ((id (ladybird-render-test-hint-id)))
      (setq ladybird-test-sent nil)
      (ladybird-test-receive conn `((type . "hints_cancelled") (view . 1)
                                    (id . ,id)))
      (should-not ladybird--hint)
      (should-not (ladybird-render-test-hint-map-active-p))
      (should-not (ladybird-test-sent))
      ;; A dialog prompt with the same id is left alone.
      (let ((ladybird--queued-prompts nil))
        (ladybird-test-receive
         conn `((type . "dialog") (view . 1) (id . ,id) (kind . "confirm")))
        (ladybird-test-receive conn `((type . "hints_cancelled") (view . 1)
                                      (id . ,id)))
        (should (= (length ladybird--queued-prompts) 1))
        (dolist (timer timer-list)
          (when (memq (timer--function timer)
                      '(ladybird--cancel-prompt ladybird--run-prompt))
            (cancel-timer timer)))))))

(ert-deftest ladybird-render-test-hint-error ()
  ;; An error with the session's id ends it; others are only reported.
  (ladybird-render-test-with-hints
    (let ((id (ladybird-render-test-hint-start)))
      (setq ladybird-test-sent nil)
      (dolist (error `(((type . "error") (view . 1) (message . "other"))
                       ((type . "error") (view . 1) (id . ,(1+ id))
                        (message . "other id"))
                       ((type . "error") (view . 2) (id . ,id)
                        (message . "other view"))))
        (should (equal (ladybird-render-test-hint-messages
                         (ladybird-test-receive conn error))
                       (list (concat "ladybird: test: "
                                     (alist-get 'message error)))))
        (should ladybird--hint))
      (should (equal (ladybird-render-test-hint-messages
                       (ladybird-test-receive
                        conn `((type . "error") (view . 1) (id . ,id)
                               (message . "not the view's hint session"))))
                     '("ladybird: test: not the view's hint session")))
      (should-not ladybird--hint)
      (should-not (ladybird-render-test-hint-map-active-p))
      (should-not (ladybird-test-sent)))
    ;; Also while the labels are awaited.
    (ladybird-render-test-keys "C-c C-o")
    (let ((id (ladybird-render-test-hint-id)))
      (setq ladybird-test-sent nil)
      (ladybird-test-receive conn `((type . "error") (view . 1) (id . ,id)
                                    (message . "bad hint alphabet")))
      (should-not ladybird--hint)
      (should-not (ladybird-test-sent)))))

(ert-deftest ladybird-render-test-hint-map-hidden ()
  ;; A session that ends while a prompt hides the keymaps, as `read-key'
  ;; does for an alert of `ladybird-alert-style' `prompt', leaves no
  ;; keymap behind: the next key goes to the page again.
  (dolist (end (list (lambda (id) `((type . "hints_cancelled") (view . 1) (id . ,id)))
                     (lambda (id) `((type . "error") (view . 1) (id . ,id)
                                    (message . "refused")))
                     (lambda (id) `((type . "hints_list") (view . 1) (id . ,id)
                                    (items . []) (truncated . :false)))
                     (lambda (_) 'drop)))
    (ladybird-render-test-with-hints
     (ert-info ((format "ended by %S" (funcall end 1)))
      (let ((ladybird-alert-style 'prompt)
            (ladybird--queued-prompts nil)
            (id nil))
        (if (eq (funcall end 0) 'drop)
            (ladybird-render-test-hint-start)
          ;; The empty list has to be the first answer.
          (ladybird-render-test-keys "C-c C-o")
          (unless (equal (alist-get 'type (funcall end 0)) "hints_list")
            (ladybird-test-receive conn (ladybird-render-test-hints-list))))
        (setq id (ladybird--hint-id ladybird--hint))
        (ladybird-render-test-prompting
          (cl-letf (((symbol-function 'read-key)
                     (lambda (&rest _)
                       (let ((overriding-terminal-local-map (make-sparse-keymap))
                             (overriding-local-map (make-sparse-keymap)))
                         (let ((msg (funcall end id)))
                           (if (eq msg 'drop)
                               (ladybird--drop conn)
                             (ladybird-test-receive conn msg))))
                       ?x)))
            (ladybird-test-receive
             conn '((type . "dialog") (view . 1) (id . 5) (kind . "alert")
                    (message . "Hi")))))
        (should-not ladybird--hint)
        (should-not (ladybird-render-test-hint-map-active-p))
        (unless (eq (funcall end 0) 'drop)
          (setq ladybird-test-sent nil)
          (ladybird-render-test-keys "n")
          (should (equal (alist-get 'key (car (ladybird-test-sent))) "N")))))))
  ;; A command of the map that finds no session drops its key.
  (ladybird-render-test-with-hints
    (let ((unread-command-events nil))
      (dolist (command '(ladybird-hint-add-char ladybird-hint-delete-char
                         ladybird-hint-quit))
        (let ((last-command-event ?a))
          (funcall command)))
      (should-not unread-command-events)
      (should-not (ladybird-test-sent)))))

(ert-deftest ladybird-render-test-hint-malformed ()
  ;; A list the client cannot use ends the session with `hints_end'.
  (ladybird-render-test-with-hints
    (dolist (items `("aa" [1] [nil] [((index . 0) (kind . "link"))]
                     [((index . 0) (label . "ax"))]
                     [((index . 0) (label . ""))]
                     [((index . 0) (label . 7))]
                     [((index . 1.5) (label . "aa"))]
                     [((label . "aa"))]
                     [((index . 0) (label . "aa") (text . 5))]
                     [((index . 0) (label . "aa") (url . ["x"]))]
                     [((index . 0) (label . "aa") (kind . t))]
                     ,(vconcat (append ladybird-render-test-hint-items
                                       '(((index . 5) (label . "Sd")))))))
      (ert-info ((format "items %S" items))
        (ladybird-render-test-keys "C-c C-o")
        (let ((id (ladybird-render-test-hint-id)))
          (setq ladybird-test-sent nil)
          (should (equal (ladybird-render-test-hint-messages
                           (ladybird-test-receive
                            conn `((type . "hints_list") (view . 1) (id . ,id)
                                   (items . ,items) (truncated . :false))))
                         '("ladybird: the page sent unusable hints")))
          (should-not ladybird--hint)
          (should-not (ladybird-render-test-hint-map-active-p))
          (should (equal (ladybird-test-sent)
                         `(((type . "hints_end") (view . 1) (id . ,id)
                            (activate))))))))
    ;; Nulls are fine, and so is a label of another session's alphabet's
    ;; characters as long as this one's has them.
    (ladybird-render-test-keys "C-c C-o")
    (ladybird-test-receive
     conn (ladybird-render-test-hints-list
           nil '(((index . 0) (label . "aa") (kind) (text) (url)))))
    (should (= (length (ladybird--hint-items ladybird--hint)) 1))))

(ert-deftest ladybird-render-test-hint-crossing ()
  ;; An error with the id of a session that is over is not shown.
  (ladybird-render-test-with-hints
    (let ((first (ladybird-render-test-hint-start)))
      (ladybird-render-test-keys "a")
      (ladybird-test-receive conn `((type . "hints_cancelled") (view . 1)
                                    (id . ,first)))
      (let ((second (ladybird-render-test-hint-start)))
        (ladybird-render-test-keys "as")
        (should-not ladybird--hint)
        (should-not (ladybird-render-test-hint-messages
                      (dolist (id (list first second))
                        (ladybird-test-receive
                         conn `((type . "error") (view . 1) (id . ,id)
                                (message . "not the view's hint session"))))))
        ;; Another id, or another view, is reported.
        (should (equal (ladybird-render-test-hint-messages
                         (ladybird-test-receive
                          conn `((type . "error") (view . 1) (id . ,(+ second 50))
                                 (message . "late")))
                         (ladybird-test-receive
                          conn `((type . "error") (view . 2) (id . ,first)
                                 (message . "elsewhere"))))
                       '("ladybird: test: late" "ladybird: test: elsewhere")))
        ;; The connection keeps the last 16.
        (dotimes (_ 20)
          (ladybird-render-test-keys "C-c C-o C-g"))
        (should (= (length (ladybird--conn-hints-ended conn)) 16))
        (should-not (member (cons 1 first) (ladybird--conn-hints-ended conn)))))))

(ert-deftest ladybird-render-test-hint-link-schemes ()
  ;; With a prefix argument a link opens in a new buffer only with http
  ;; or https, or with file from a page that is a file.
  (ladybird-render-test-with-hints
    (dolist (case '(("file:///etc/passwd" "https://example.org/" nil)
                    ("javascript:alert(1)" "https://example.org/" nil)
                    ("mock://x" "https://example.org/" nil)
                    ("http://example.org/a" "https://example.org/" t)
                    ("file:///tmp/b.html" "file:///tmp/a.html" t)))
      (pcase-let ((`(,url ,page ,opened) case))
        (ert-info ((format "%s from %s" url page))
          (setq ladybird--state `((url . ,page)))
          (ladybird-render-test-keys "C-u C-c C-o")
          (let ((id (ladybird-render-test-hint-id)))
            (ladybird-test-receive
             conn (ladybird-render-test-hints-list
                   id `(((index . 0) (label . "aa") (kind . "link") (text . "x")
                         (url . ,url))
                        ((index . 1) (label . "as") (kind . "button")))))
            (setq ladybird-test-sent nil)
            (let ((messages (ladybird-render-test-hint-messages
                              (ladybird-render-test-keys "aa"))))
              (should (equal (car (ladybird-test-sent "hints_end"))
                             `((type . "hints_end") (view . 1) (id . ,id)
                               (activate))))
              (if opened
                  (should (equal (alist-get 'url (car (ladybird-test-sent
                                                       "create_view")))
                                 url))
                (should-not (ladybird-test-sent "create_view"))
                (should (equal (car (last messages))
                             (concat "ladybird: not opening " url)))))
            (mapc #'kill-buffer (remq buffer (ladybird--buffers)))
            (set-window-buffer (selected-window) buffer)))))))

(ert-deftest ladybird-render-test-hint-no-feature ()
  (ladybird-render-test-with-hints
    (setf (ladybird--conn-server-info conn)
          (assq-delete-all 'features (copy-sequence
                                      (ladybird--conn-server-info conn))))
    (should (equal (cadr (should-error (ladybird-follow-hint) :type 'user-error))
                   "The server on test does not offer hints"))
    (setf (ladybird--conn-server-info conn)
          (cons '(features . ["other"]) (ladybird--conn-server-info conn)))
    (should-error (ladybird-follow-hint) :type 'user-error)
    (should-not (ladybird-test-sent))
    (should-not ladybird--hint)
    (should-not (ladybird-render-test-hint-map-active-p))))

(ert-deftest ladybird-render-test-hint-bad-alphabet ()
  (ladybird-render-test-with-hints
    (dolist (alphabet '("a" "aa" "Ab" "a-b" ""))
      (let ((ladybird-hint-alphabet alphabet))
        (should-error (ladybird-follow-hint) :type 'user-error)))
    (should-not (ladybird-test-sent))
    (should-not ladybird--hint)
    (let ((ladybird-hint-alphabet "ab"))
      (ladybird-follow-hint)
      (should (equal (alist-get 'alphabet (car (ladybird-test-sent))) "ab")))))

(ert-deftest ladybird-render-test-hint-connection-lost ()
  (ladybird-render-test-with-hints
    (ladybird-render-test-hint-start)
    (ladybird--drop conn)
    (should-not ladybird--hint)
    (should-not (ladybird-render-test-hint-map-active-p))
    (should-not (ladybird-test-sent "hints_end"))
    (should-error (ladybird-follow-hint) :type 'user-error))
  ;; A second client replacing this one ends it too.
  (ladybird-render-test-with-hints
    (ladybird-render-test-hint-start)
    (ladybird-test-receive conn '((type . "replaced")))
    (should-not ladybird--hint)
    (should-not (ladybird-test-sent "hints_end"))))

(ert-deftest ladybird-render-test-hint-kill ()
  (ladybird-render-test-with-hints
    (let ((id (ladybird-render-test-hint-start))
          (other (ladybird--make-view-buffer conn 2 "mock://2")))
      ;; Another page buffer's death leaves the session alone.
      (kill-buffer other)
      (should ladybird--hint)
      (setq ladybird-test-sent nil)
      (kill-buffer buffer)
      (should (equal (mapcar (lambda (m) (alist-get 'type m)) (ladybird-test-sent))
                     '("hints_end" "close_view")))
      (should (equal (alist-get 'id (car (ladybird-test-sent))) id))
      (should-not ladybird--hint)
      (should-not (ladybird-render-test-hint-map-active-p))))
  ;; A view the server closed gets no `hints_end'.
  (ladybird-render-test-with-hints
    (ladybird-render-test-hint-start)
    (ladybird-test-receive conn '((type . "view_closed") (view . 1)
                                  (reason . "closed")))
    (should-not (buffer-live-p buffer))
    (should-not ladybird--hint)
    (should-not (ladybird-test-sent "hints_end"))))

(ert-deftest ladybird-render-test-hint-elsewhere ()
  ;; A window that shows another buffer, or the minibuffer, ends the hints.
  (ladybird-render-test-with-hints
    (ladybird-render-test-hint-start)
    (with-temp-buffer
      (let ((other (current-buffer)))
        (set-window-buffer (selected-window) other)
        (ladybird-render-test-keys "a")
        (should-not ladybird--hint)
        (should (equal (mapcar (lambda (m) (alist-get 'type m))
                               (ladybird-test-sent))
                       '("hints_end")))
        ;; The key went to the buffer the window shows.
        (should (equal (with-current-buffer other (buffer-string)) "a"))
        (set-window-buffer (selected-window) buffer)))
    (setq ladybird-test-sent nil)
    (ladybird-render-test-hint-start)
    (run-hooks 'minibuffer-setup-hook)
    (should-not ladybird--hint)
    (should-not (ladybird-render-test-hint-map-active-p))
    (should (equal (mapcar (lambda (m) (alist-get 'type m)) (ladybird-test-sent))
                   '("hints_end")))))

(ert-deftest ladybird-render-test-hint-frames ()
  ;; Frames are painted while a label is typed.
  (ladybird-render-test-with-hints
    (ladybird-render-test-hint-start)
    (ladybird-render-test-keys "a")
    (setq ladybird-test-sent nil)
    (let ((canvas ladybird--canvas))
      (ladybird-test-receive conn (ladybird-test-frame 2 1 40 30 '(0 0 4 4) 3))
      (should (equal (ladybird-test-sent "frame_ack")
                     '(((type . "frame_ack") (view . 1) (seq . 2)))))
      (should (eq ladybird--canvas canvas))
      (should (= ladybird--dropped-frames 0))
      (should ladybird--hint)
      (should (equal (ladybird--hint-prefix ladybird--hint) "a")))))


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

(defun ladybird-render-test-one-page-server (conn)
  "Make CONN's server one that holds one page, as one without `max_views'."
  (setf (ladybird--conn-server-info conn)
        (assq-delete-all 'max_views (copy-alist (ladybird--conn-server-info conn)))))

(defun ladybird-render-test-max-views (conn max)
  "Make CONN's server one that holds MAX pages."
  (ladybird-render-test-one-page-server conn)
  (push (cons 'max_views max) (ladybird--conn-server-info conn)))

(ert-deftest ladybird-render-test-create-refused ()
  ;; A server whose welcome has no `max_views' holds one page: a further
  ;; page is not asked for and its URL loads in the page there is.
  (ladybird-render-test-with-view
    (let ((ladybird-program "ladybird-no-such-program")
          (ladybird-hosts '(("test" . "/nonexistent/ladybird")))
          (ladybird-default-host nil))
     (save-window-excursion
      (set-window-buffer (selected-window) buffer)
      (setq ladybird--last-buffer buffer)
      (ladybird-render-test-one-page-server conn)
      (should (= (ladybird--max-views conn) 1))
      (let ((messages (ladybird-render-test-messages
                        (should (eq (ladybird-new-buffer) buffer)))))
        (should (equal messages
                       '("ladybird: test holds one page; mock://one loaded in \
*ladybird: mock://one*"))))
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
      ;; A refusal of a server that holds one page loads the URL there too.
      (let ((second (ladybird--make-view-buffer conn nil "mock://2")))
        (with-current-buffer second (ladybird--create-view))
        (set-window-buffer (selected-window) second)
        (ladybird-test-receive
         conn `((type . "error")
                (request . ,(alist-get 'request (car (ladybird-test-sent "create_view"))))
                (message . "only one view is supported")))
        (should-not (buffer-live-p second))
        (should (eq (window-buffer) buffer))
        (should (equal (car (last (ladybird-test-sent "load")))
                       '((type . "load") (view . 1) (url . "mock://2")))))))))

(ert-deftest ladybird-render-test-create-refused-unnamed ()
  ;; A server that does not name the request: an error about no view
  ;; fails the buffer that has waited longest.
  (ladybird-render-test-with-view
    (ladybird-render-test-one-page-server conn)
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
      (should (= (hash-table-count (ladybird--conn-pending conn)) 0))
      ;; A view a page opened answers no request.
      (let ((four (ladybird--make-view-buffer conn nil "mock://4")))
        (with-current-buffer four (ladybird--create-view))
        (ladybird-test-receive conn '((type . "view_created") (view . 6)
                                      (opener . 1)))
        (should-not (buffer-local-value 'ladybird--view four))))))

(ert-deftest ladybird-render-test-several-pages ()
  ;; A server that holds several pages gets a view for each new page,
  ;; until its `max_views'; then the command says so and asks for nothing.
  (ladybird-render-test-with-view
    (save-window-excursion
      (ladybird-render-test-max-views conn 3)
      (set-window-buffer (selected-window) buffer)
      (let* ((second (ladybird-new-buffer))
             (third (with-current-buffer second (ladybird-goto-url "mock://3" t))))
        (should-not (memq buffer (list second third)))
        (should (eq (window-buffer) third))
        (should (equal (mapcar (lambda (m) (alist-get 'url m))
                               (ladybird-test-sent "create_view"))
                       '("mock://one" "mock://3")))
        ;; Those still being made count.
        (should (= (ladybird--view-count conn) 3))
        (setq ladybird-test-sent nil)
        (should (equal (cadr (should-error (ladybird "mock://4" ladybird-test-host)
                                           :type 'user-error))
                       "ladybird: test has 3 pages open, the most it holds; \
close one first"))
        (with-current-buffer third
          (should-error (ladybird--follow-link "https://example.org/" t)
                        :type 'user-error))
        (should-not (ladybird-test-sent))
        (should (= (length (ladybird--buffers conn)) 3))
        ;; Each page gets its own view.
        (dolist (page (list second third))
          (ladybird-test-receive
           conn `((type . "view_created")
                  (request . ,(cdr (assq page (ladybird--conn-creating conn))))
                  (view . ,(if (eq page second) 2 3)))))
        (should (equal (mapcar (lambda (page) (buffer-local-value 'ladybird--view page))
                               (list buffer second third))
                       '(1 2 3)))
        ;; Frames go to their own views.
        (ladybird-test-receive conn (ladybird-test-frame 1 2 4 3 nil 1 t)
                               (ladybird-test-frame 1 3 4 3 nil 2 t)
                               (ladybird-test-frame 2 3 4 3 '(0 0 1 1) 3))
        (should (equal (mapcar (lambda (page)
                                 (with-current-buffer page
                                   (list ladybird--frame-count ladybird--full-frame-count)))
                               (list buffer second third))
                       '((0 0) (1 1) (2 1))))
        ;; A page closed makes room; one left on the server does not.
        (let ((ladybird-keep-view-on-kill t))
          (kill-buffer second))
        (should (equal (mapcar #'car (ladybird--conn-kept conn)) '(2)))
        (should-error (ladybird "mock://4" ladybird-test-host) :type 'user-error)
        (kill-buffer third)
        (should (ladybird--ready-p conn))
        (should (equal (ladybird-test-sent "close_view")
                       '(((type . "close_view") (view . 3)))))
        (let ((fourth (ladybird "mock://4" ladybird-test-host)))
          (should (buffer-live-p fourth))
          ;; A refusal there is reported, and loads nothing elsewhere.
          (setq ladybird-test-sent nil)
          (should (equal (ladybird-render-test-messages
                           (ladybird-test-receive
                            conn `((type . "error")
                                   (request . ,(cdr (assq fourth
                                                          (ladybird--conn-creating conn))))
                                   (message . "only 3 views are supported"))))
                         '("ladybird: test opened no page: only 3 views are supported")))
          (should-not (buffer-live-p fourth))
          (should-not (ladybird-test-sent "load")))))))

(ert-deftest ladybird-render-test-kept-pages ()
  ;; Pages left on a connected server by killed buffers count against the
  ;; limit, keep their state, can be got back, and go when the server
  ;; closes them.
  (ladybird-render-test-with-view
    (save-window-excursion
      (set-window-buffer (selected-window) buffer)
      (ladybird-render-test-max-views conn 2)
      (let ((second (ladybird--make-view-buffer conn 2 "mock://2")))
        (with-current-buffer second
          (ladybird--apply-state '((view . 2) (url . "mock://2") (title . "Two"))))
        (let ((ladybird-keep-view-on-kill t))
          (kill-buffer second)))
      (should (equal (mapcar #'car (ladybird--conn-kept conn)) '(2)))
      (should (equal (cadr (should-error (ladybird "mock://3" ladybird-test-host)
                                         :type 'user-error))
                     "ladybird: test has 2 pages open, the most it holds, 1 of them \
left by killed buffers, which C-c C-s or M-x ladybird-connect shows again; close one first"))
      ;; The server's state of the kept page is kept up to date.
      (ladybird-test-receive conn '((type . "state") (view . 2) (url . "mock://2b")
                                    (title . "Two later") (loading . :false)))
      (should (equal (alist-get 'title (cdr (assq 2 (ladybird--conn-kept conn))))
                     "Two later"))
      ;; C-c C-s offers it and gives it a buffer again.
      (should (equal (mapcar #'car (ladybird--page-candidates))
                     '("mock://one" "Two later  mock://2b")))
      (setq ladybird-test-sent nil)
      (ladybird-switch-to-page (cdr (assoc "Two later  mock://2b" (ladybird--page-candidates))))
      (let ((again (window-buffer)))
        (should (eq (gethash 2 (ladybird--conn-views conn)) again))
        (should (equal (buffer-name again) "*ladybird: Two later*"))
        (should-not (ladybird--conn-kept conn))
        ;; Shown, it is told it is visible, which brings its frame.
        (ladybird--update)
        (should (member '((type . "set_visibility") (view . 2) (visible . t))
                        (ladybird-test-sent "set_visibility")))
        (let ((ladybird-keep-view-on-kill t))
          (kill-buffer again)))
      ;; `ladybird-connect' on the open connection gives it a buffer too.
      (ladybird-connect ladybird-test-host)
      (should (gethash 2 (ladybird--conn-views conn)))
      (should-not (ladybird--conn-kept conn))
      ;; A kept page the server closes is forgotten.
      (let ((ladybird-keep-view-on-kill t))
        (kill-buffer (gethash 2 (ladybird--conn-views conn))))
      (should (ladybird--conn-kept conn))
      (ladybird-test-receive conn '((type . "view_closed") (view . 2) (reason . "closed")))
      (should-not (ladybird--conn-kept conn))
      (should (= (ladybird--view-count conn) 1)))))

(ert-deftest ladybird-render-test-clean-page-strings ()
  ;; Page strings lose control and bidi override characters wherever
  ;; they are shown; a long title does not push the URL out of a candidate.
  (ladybird-render-test-with-view
    (let ((evil (concat "Pay‮" "lmth.exe‬" "\n\ttail\a⁦x⁩")))
      (should (equal (ladybird--clean evil) "Paylmth.exe  tailx"))
      (ladybird--apply-state `((url . "https://example.org/‮abc") (title . ,evil)))
      (should (equal (buffer-name) "*ladybird: Paylmth.exe  tailx*"))
      (should (string-match-p "https://example.org/abc — Paylmth.exe tailx"
                              (substring-no-properties (ladybird--header-line))))
      (should-not (string-match-p "[‮\n\a]" (ladybird--echo-line evil)))
      (should (equal (ladybird--page-name conn `((origin . ,evil))) "Paylmth.exe  tailx"))
      ;; Candidates: the title is cut, the URL kept, look-alikes numbered.
      (let ((long (make-string 200 ?T))
            (second (ladybird--make-view-buffer conn 2 "mock://2")))
        (ladybird--apply-state `((url . "https://example.org/one") (title . ,long)))
        (with-current-buffer second
          (ladybird--apply-state `((url . "https://example.org/two") (title . ,long))))
        (let ((names (mapcar #'car (ladybird--page-candidates))))
          (should (= (length names) 2))
          (dolist (name names)
            (should (< (string-width name) 90)))
          (should (seq-find (lambda (name) (string-suffix-p "https://example.org/one" name))
                            names))
          (should (seq-find (lambda (name) (string-suffix-p "https://example.org/two" name))
                            names)))))))

(ert-deftest ladybird-render-test-opener-closed ()
  ;; A view a page opened is closed until such views are taken.
  (ladybird-render-test-with-view
    (ladybird-test-receive conn '((type . "view_created") (view . 4) (opener . 1)
                                  (url . "about:blank")))
    (should (equal (ladybird-test-sent "close_view")
                   '(((type . "close_view") (view . 4)))))
    (should-not (gethash 4 (ladybird--conn-views conn)))))

(ert-deftest ladybird-render-test-one-page-background ()
  ;; On a server that holds one page, a new page in the background loads
  ;; in that page without showing it.
  (ladybird-render-test-with-view
    (save-window-excursion
      (ladybird-render-test-one-page-server conn)
      (with-temp-buffer
        (set-window-buffer (selected-window) (current-buffer))
        (let ((ladybird-new-page-display 'background))
          (should (eq (ladybird "mock://bg" ladybird-test-host) buffer)))
        (should (eq (window-buffer) (current-buffer)))
        (should-not (get-buffer-window buffer t))
        (should (equal (car (ladybird-test-sent "load"))
                       '((type . "load") (view . 1) (url . "mock://bg"))))))))

(ert-deftest ladybird-render-test-hint-refusal-message ()
  ;; A label typed ahead that opens a page the server has no room for is
  ;; refused with a message, not a timer error.
  (ladybird-render-test-with-hints
    (ladybird-render-test-max-views conn 2)
    (puthash 9 (ladybird--make-view-buffer conn 9 "mock://9") (ladybird--conn-views conn))
    (setq ladybird--state '((url . "https://example.org/")))
    (ladybird-render-test-keys "C-u C-c C-o a a")
    (ladybird-test-receive conn (ladybird-render-test-hints-list))
    (let ((messages (ladybird-render-test-messages (ladybird-render-test-take-up))))
      (should (member "ladybird: test has 2 pages open, the most it holds; close one first"
                      messages)))))

(ert-deftest ladybird-render-test-viewport-refused ()
  ;; A server that refuses a viewport, as one over its area cap does,
  ;; leaves the page as it was.
  (ladybird-render-test-with-view
    (ladybird-render-test-show)
    (let ((canvas ladybird--canvas))
      (should (equal (ladybird-render-test-messages
                       (ladybird-test-receive conn '((type . "error") (view . 1)
                                                     (message . "viewport area over the cap"))))
                     '("ladybird: test: viewport area over the cap")))
      (should (eq ladybird--canvas canvas))
      (should (ladybird--ready-p conn))
      (ladybird-test-receive conn (ladybird-test-frame 2 1 40 30 '(0 0 2 2) 1))
      (should (= ladybird--frame-count 2)))))

(ert-deftest ladybird-render-test-frame-visibility-events ()
  ;; Iconifying a frame or showing it again schedules an update, and
  ;; runs what the event ran before.
  (ladybird-render-test-with-view
    (let ((special-event-map (copy-keymap special-event-map))
          (ladybird--special-events nil)
          (ran nil))
      (define-key special-event-map [iconify-frame] (lambda (_e) (interactive "e") (setq ran t)))
      (ladybird--follow-frame-visibility)
      (should (eq (lookup-key special-event-map [iconify-frame])
                  #'ladybird--frame-visibility-changed))
      (should (eq (lookup-key special-event-map [make-frame-visible])
                  #'ladybird--frame-visibility-changed))
      (setq ladybird--update-timer nil)
      (ladybird--frame-visibility-changed (list 'iconify-frame (selected-frame)))
      (should (timerp ladybird--update-timer))
      (should ran))))

(ert-deftest ladybird-render-test-unload ()
  ;; `unload-feature' takes everything ladybird put outside its buffers.
  (skip-unless (executable-find (expand-file-name invocation-name invocation-directory)))
  (let* ((dir (file-name-directory (locate-library "ladybird")))
         (test-dir (file-name-directory (locate-library "ladybird-fake-module")))
         (output
          (with-temp-buffer
            (call-process
             (expand-file-name invocation-name invocation-directory) nil t nil
             "--batch" "-Q" "-L" dir "-L" test-dir
             "--eval"
             (prin1-to-string
              '(progn
                 (require 'ladybird-fake-module)
                 (require 'ladybird)
                 (with-current-buffer (get-buffer-create "page")
                   (ladybird-mode))
                 (setq ladybird--hint 'x)
                 (add-to-list 'emulation-mode-map-alists 'ladybird--hint-map-alist)
                 (setq ladybird--hint nil)
                 (ladybird--schedule-update)
                 (unload-feature 'ladybird t)
                 (let ((left nil))
                   (dolist (hook '(post-command-hook window-buffer-change-functions
                                   delete-frame-functions pre-command-hook
                                   minibuffer-setup-hook))
                     (dolist (f (default-value hook))
                       (when (and (symbolp f) (string-prefix-p "ladybird" (symbol-name f)))
                         (push (list hook f) left))))
                   (when (memq 'ladybird--hint-map-alist emulation-mode-map-alists)
                     (push 'emulation left))
                   (when (eq (lookup-key special-event-map [iconify-frame])
                             'ladybird--frame-visibility-changed)
                     (push 'special-event-map left))
                   (dolist (timer timer-list)
                     (when (and (symbolp (timer--function timer))
                                (string-prefix-p "ladybird"
                                                 (symbol-name (timer--function timer))))
                       (push 'timer left)))
                   (princ (format "LEFT %S" left))))))
            (buffer-string))))
    (should (string-match-p "LEFT nil" output))))

(ert-deftest ladybird-render-test-new-page-display ()
  ;; Where a new page appears.
  (ladybird-render-test-with-view
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer (selected-window) buffer)
      (setq ladybird--last-buffer buffer)
      (let ((ladybird-new-page-display 'selected-window)
            (page (ladybird-new-buffer)))
        (should (eq (window-buffer) page))
        (should (eq ladybird--last-buffer page))
        (should (= (length (window-list)) 1)))
      (set-window-buffer (selected-window) buffer)
      (let* ((ladybird-new-page-display 'other-window)
             (page (ladybird-new-buffer)))
        (should (eq (window-buffer) page))
        (should (= (length (window-list)) 2))
        (should (memq buffer (mapcar #'window-buffer (window-list)))))
      (delete-other-windows)
      (set-window-buffer (selected-window) buffer)
      (setq ladybird--last-buffer buffer)
      (let* ((ladybird-new-page-display 'background)
             (messages nil)
             (page nil))
        (setq messages (ladybird-render-test-messages
                         (setq page (ladybird-new-buffer))))
        (should (buffer-live-p page))
        (should (eq (window-buffer) buffer))
        (should-not (get-buffer-window page t))
        (should (eq ladybird--last-buffer buffer))
        (should (equal messages
                       (list (format "ladybird: %s opens in the background"
                                     (buffer-name page)))))
        ;; It still asked for a view, with the size of the selected window.
        (should (equal (alist-get 'url (car (last (ladybird-test-sent "create_view"))))
                       "mock://one")))
      ;; A rule of `display-buffer-alist' comes first.
      (let* ((ladybird-new-page-display 'selected-window)
             (display-buffer-alist
              '(("\\*ladybird" (display-buffer-pop-up-window)
                 (inhibit-same-window . t))))
             (page (ladybird-new-buffer)))
        (should (get-buffer-window page))
        (should (eq (window-buffer (frame-first-window)) buffer))))))

(ert-deftest ladybird-render-test-visibility-per-page ()
  ;; Each view hears whether a window shows its buffer.
  (ladybird-render-test-with-view
    (save-window-excursion
      (delete-other-windows)
      (let ((second (ladybird--make-view-buffer conn 2 "mock://2"))
            (visible (lambda ()
                       (mapcar (lambda (m) (list (alist-get 'view m)
                                                 (alist-get 'visible m)))
                               (ladybird-test-sent "set_visibility")))))
        (set-window-buffer (selected-window) buffer)
        (setq ladybird-test-sent nil)
        (ladybird--update)
        (should (equal (sort (funcall visible) (lambda (a b) (< (car a) (car b))))
                       '((1 t) (2 nil))))
        ;; The global hook schedules an update when a window changes.
        (should (memq #'ladybird--window-buffer-changed
                      (default-value 'window-buffer-change-functions)))
        (setq ladybird-test-sent nil)
        (set-window-buffer (selected-window) second)
        (ladybird--update)
        (should (equal (sort (funcall visible) (lambda (a b) (< (car a) (car b))))
                       '((1 nil) (2 t))))
        ;; Two windows on one buffer: still one visible view, told once.
        (setq ladybird-test-sent nil)
        (set-window-buffer (split-window) second)
        (ladybird--update)
        (should-not (funcall visible))
        ;; A buffer in no window at all is hidden; shown again, visible.
        (with-temp-buffer
          (dolist (window (window-list))
            (set-window-buffer window (current-buffer)))
          (ladybird--update)
          (should (equal (funcall visible) '((2 nil)))))
        (setq ladybird-test-sent nil)
        (delete-other-windows)
        (set-window-buffer (selected-window) buffer)
        (ladybird--update)
        (should (equal (funcall visible) '((1 t))))))))

(ert-deftest ladybird-render-test-reattach-pages ()
  ;; Connecting to a server with several pages gives each a buffer and
  ;; shows the one used last, else the first.
  (ladybird-test-with-env
    (let ((ladybird--frame-function #'ladybird--on-frame)
          (ladybird--welcome-function #'ladybird--on-welcome)
          (ladybird--change-function #'ladybird--on-conn-change)
          (ladybird--viewport-function #'ladybird--hello-viewport)
          (ladybird-device-pixel-ratio 1.0)
          (ladybird--last-buffer nil)
          (ladybird--update-timer nil)
          (views '(((view . 3) (url . "mock://c") (title . "C"))
                   ((view . 1) (url . "mock://a") (title . "A"))
                   ((view . 2) (url . "mock://b") (title . "B")))))
      (unwind-protect
          (save-window-excursion
            (ladybird-connect ladybird-test-host)
            (let* ((conn (car ladybird--conns))
                   (messages (ladybird-render-test-messages
                               (ladybird-test-receive conn (ladybird-test-welcome views)))))
              (should (= (length (ladybird--buffers conn)) 3))
              (should (equal (buffer-local-value 'ladybird--view (window-buffer)) 1))
              ;; Each view is told its visibility once, the shown one visible.
              (setq ladybird-test-sent nil)
              (ladybird--update)
              (should (equal (sort (mapcar (lambda (m) (list (alist-get 'view m)
                                                             (alist-get 'visible m)))
                                           (ladybird-test-sent "set_visibility"))
                                   (lambda (a b) (< (car a) (car b))))
                             '((1 t) (2 nil) (3 nil))))
              (should (equal messages
                             '("ladybird: 3 pages found on test"
                               "ladybird: 3 pages on test; C-c C-s switches")))
              ;; Each buffer has its page's state.
              (should (equal (sort (mapcar (lambda (b) (buffer-local-value 'ladybird--state b))
                                           (ladybird--buffers conn))
                                   (lambda (a b) (< (alist-get 'view a) (alist-get 'view b))))
                             (sort (copy-sequence views)
                                   (lambda (a b) (< (alist-get 'view a) (alist-get 'view b))))))
              ;; Again, with the page of view 2 used last.
              (setq ladybird--last-buffer (gethash 2 (ladybird--conn-views conn)))
              (ladybird--drop conn)
              (ladybird-test-run-timer (ladybird--conn-timer conn))
              (ladybird-connect ladybird-test-host)
              (ladybird-test-receive conn (ladybird-test-welcome views))
              (should (= (length (ladybird--buffers conn)) 3))
              (should (equal (buffer-local-value 'ladybird--view (window-buffer)) 2))))
        (when (timerp ladybird--update-timer)
          (cancel-timer ladybird--update-timer))
        (mapc #'kill-buffer (ladybird--buffers))))))

(ert-deftest ladybird-render-test-last-page-on-socket ()
  ;; The last page of a socket server closed: the server keeps running.
  (ladybird-render-test-with-view
    (cl-letf (((symbol-function 'process-type) (lambda (_) 'network)))
      (let ((second (ladybird--make-view-buffer conn 2 "mock://2")))
        (should-not (ladybird-render-test-messages (kill-buffer second)))
        (should (ladybird--ready-p conn))
        (should (equal (ladybird-render-test-messages
                         (let ((ladybird-keep-view-on-kill t))
                           (kill-buffer buffer)))
                       '("ladybird: no page is open here on test; its server keeps \
running with 1 page, which `ladybird-connect' shows again"))))))
  (ladybird-render-test-with-view
    (cl-letf (((symbol-function 'process-type) (lambda (_) 'network)))
      (should (equal (ladybird-render-test-messages (kill-buffer buffer))
                     '("ladybird: no page is open here on test; its server keeps \
running until it is stopped where it runs"))))))

(ert-deftest ladybird-render-test-switch-to-page ()
  ;; C-c C-s reads a page by its title and URL.
  (ladybird-render-test-with-view
    (save-window-excursion
      (set-window-buffer (selected-window) buffer)
      (should (eq (key-binding (kbd "C-c C-s")) #'ladybird-switch-to-page))
      (let ((second (ladybird--make-view-buffer conn 2 "mock://2"))
            (third (ladybird--make-view-buffer conn 3 "mock://3"))
            (asked nil))
        (with-current-buffer second
          (ladybird--apply-state '((url . "mock://2") (title . "Second"))))
        (with-current-buffer third
          (ladybird--apply-state '((url . "mock://3") (title . "Second"))))
        (should (equal (mapcar #'car (ladybird--page-candidates))
                       '("Second  mock://2" "Second  mock://3" "mock://one")))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt table &rest args)
                     (setq asked (list prompt (all-completions "" table)
                                       (completion-metadata-get
                                        (funcall table "" nil 'metadata)
                                        'annotation-function)
                                       (nth 4 args)
                                       (completion-metadata-get
                                        (funcall table "" nil 'metadata)
                                        'category)
                                       ;; A part of a URL completes.
                                       (completion-all-completions
                                        "mock://3" table nil 8
                                        (completion-metadata
                                         "" table nil))))
                     "Second  mock://3")))
          (call-interactively #'ladybird-switch-to-page))
        (should (eq (window-buffer) third))
        (should (eq ladybird--last-buffer third))
        (should (equal (take 2 asked)
                       '("Page: " ("Second  mock://2" "Second  mock://3" "mock://one"))))
        ;; One server: no host annotation; the default is the first.
        (should-not (nth 2 asked))
        (should (equal (nth 3 asked) "Second  mock://2"))
        (should (eq (nth 4 asked) 'ladybird-page))
        (should (member "Second  mock://3" (nth 5 asked)))
        ;; Several servers: each page says its host.
        (let* ((other (ladybird-test-connect '("elsewhere" (:kind unix :path "/x"))))
               (page (ladybird--make-view-buffer other 1 "mock://far")))
          (ignore page)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _)
                       (setq asked (funcall (completion-metadata-get
                                             (funcall table "" nil 'metadata)
                                             'annotation-function)
                                            "mock://far"))
                       "mock://far")))
            (call-interactively #'ladybird-switch-to-page))
          (should (equal asked "  [elsewhere]")))))))

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
                (dolist (last-command-event '(?H ?i ?! ?\r))
                  (ladybird-send-key))
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
  ;; A server whose welcome has no max_views shows one page: the second
  ;; page loads in the first and is not asked for.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird--last-buffer nil)
         (ladybird-device-pixel-ratio 1.0)
         (inhibit-message t)
         (host (ladybird-test-mock-host log "--no-max-views"))
         buffer)
    (save-window-excursion
      (unwind-protect
          (progn
            (setq buffer (ladybird "mock://one" host))
            (let ((conn (buffer-local-value 'ladybird--conn buffer)))
              (ladybird-test-wait conn (lambda ()
                                         (buffer-local-value 'ladybird--canvas
                                                             buffer)))
              (should (= (ladybird--max-views conn) 1))
              (should (eq (ladybird "mock://two" host) buffer))
              (ladybird-test-wait
               conn (lambda ()
                      (equal (alist-get 'url (buffer-local-value 'ladybird--state
                                                                 buffer))
                             "mock://two")))
              (should (= (length (seq-filter
                                  (lambda (m)
                                    (equal (alist-get 'type m) "create_view"))
                                  (ladybird-test-log log)))
                         1))
              (should (= (length (ladybird--buffers)) 1))))
        (mapc #'kill-buffer (ladybird--buffers))
        (delete-file log)))))

(ert-deftest ladybird-mock-test-several-pages ()
  ;; Two pages on one server: each paints, a hidden one gets no frames
  ;; while the other animates, and a full frame when it is shown again;
  ;; the limit is the welcome's; the pages share the cookie.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird--last-buffer nil)
         (ladybird-device-pixel-ratio 1.0)
         (ladybird-resize-delay 0.01)
         (inhibit-message t)
         (host (ladybird-test-mock-host log "--max-views" "2" "--fps" "20"))
         (logged (lambda (type &rest fields)
                   (seq-filter (lambda (m)
                                 (and (equal (alist-get 'type m) type)
                                      (cl-loop for (key value) on fields by #'cddr
                                               always (equal (alist-get key m) value))))
                               (ladybird-test-log log))))
         one two)
    (save-window-excursion
      (unwind-protect
          (progn
            (delete-other-windows)
            (setq one (ladybird "mock://cookie/set/xyz" host))
            (let ((conn (buffer-local-value 'ladybird--conn one)))
              (ladybird-test-wait conn (lambda () (buffer-local-value 'ladybird--canvas one)))
              (should (= (ladybird--max-views conn) 2))
              (setq two (ladybird "mock://cookie" host))
              (should (eq (window-buffer) two))
              (ladybird-test-wait conn (lambda () (buffer-local-value 'ladybird--canvas two)))
              (should-not (= (buffer-local-value 'ladybird--view one)
                             (buffer-local-value 'ladybird--view two)))
              ;; The second page reads what the first set.
              (should (equal (alist-get 'title (buffer-local-value 'ladybird--state two))
                             "Mock: cookie=xyz"))
              ;; The limit.
              (should-error (ladybird "mock://three" host) :type 'user-error)
              (should (= 2 (length (funcall logged "create_view"))))
              ;; One is shown, the other is not: only the shown one animates.
              ;; Batch Emacs does no redisplay, which runs the window hooks.
              (ladybird--update)
              (ladybird-test-wait conn (lambda ()
                                         (funcall logged "set_visibility"
                                                  'view (buffer-local-value 'ladybird--view one)
                                                  'visible nil)))
              ;; A frame the server sent before it read that may be unread.
              (let ((until (+ (float-time) 0.5)))
                (while (< (float-time) until)
                  (accept-process-output (ladybird--conn-process conn) 0.05)))
              (let ((hidden (buffer-local-value 'ladybird--frame-count one))
                    (shown (buffer-local-value 'ladybird--frame-count two)))
                (ladybird-test-wait conn (lambda ()
                                           (> (buffer-local-value 'ladybird--frame-count two)
                                              (+ shown 5))))
                (should (= (buffer-local-value 'ladybird--frame-count one) hidden))
                ;; Shown again it starts with a full frame.
                (let ((full (buffer-local-value 'ladybird--full-frame-count one)))
                  (set-window-buffer (selected-window) one)
                  (ladybird--update)
                  (ladybird-test-wait conn (lambda ()
                                             (> (buffer-local-value 'ladybird--full-frame-count one)
                                                full)))))
              ;; Killing one page leaves the other working.
              (kill-buffer two)
              (ladybird-test-wait conn (lambda () (funcall logged "close_view")))
              (should (ladybird--ready-p conn))
              (let ((count (buffer-local-value 'ladybird--frame-count one)))
                (ladybird-test-wait conn (lambda ()
                                           (> (buffer-local-value 'ladybird--frame-count one)
                                              (+ count 3)))))))
        (mapc #'kill-buffer (ladybird--buffers))
        (delete-file log)))))

(ert-deftest ladybird-mock-test-interrupted-bands ()
  ;; A page hidden or closed while its frame is in bands: the server drops
  ;; the rest, the other page goes on, and shown again the page gets a
  ;; whole frame, painted right.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird--last-buffer nil)
         (ladybird-device-pixel-ratio 1.0)
         (inhibit-message t)
         (host (ladybird-test-mock-host log "--band-rows" "8" "--band-pause" "0.3"))
         (sent (lambda (view &rest fields)
                 (seq-filter (lambda (m)
                               (and (equal (alist-get 'type m) "_frame_sent")
                                    (eql (alist-get 'view m) view)
                                    (cl-loop for (key value) on fields by #'cddr
                                             always (equal (alist-get key m) value))))
                             (ladybird-test-log log))))
         (dropped (lambda (why)
                    (seq-filter (lambda (m) (and (equal (alist-get 'type m) "_bands_dropped")
                                                 (equal (alist-get 'why m) why)))
                                (ladybird-test-log log))))
         (show (lambda (buffer)
                 (set-window-buffer (selected-window) buffer)
                 (ladybird--update)))
         one two)
    (save-window-excursion
      (unwind-protect
          (progn
            (delete-other-windows)
            (setq one (ladybird "mock://one" host))
            (let* ((conn (buffer-local-value 'ladybird--conn one))
                   (a (progn (ladybird-test-wait
                              conn (lambda () (buffer-local-value 'ladybird--view one)))
                             (buffer-local-value 'ladybird--view one))))
              (ladybird-test-wait conn (lambda () (funcall sent a 'more nil)))
              (setq two (ladybird "mock://two" host))
              (ladybird--update)
              (let ((b (progn (ladybird-test-wait
                               conn (lambda () (buffer-local-value 'ladybird--view two)))
                              (buffer-local-value 'ladybird--view two))))
                (ladybird-test-wait conn (lambda () (funcall sent b 'more nil)))
                ;; Shown again, the first page's whole frame starts; hidden
                ;; after its first band, the rest is dropped.
                (let ((before (length (funcall sent a 'full t))))
                  (funcall show one)
                  (ladybird-test-wait conn (lambda () (> (length (funcall sent a 'full t))
                                                         before)))
                  (funcall show two)
                  (ladybird-test-wait conn (lambda () (funcall dropped "hidden"))))
                ;; The second page is not held up.
                (let ((count (length (funcall sent b))))
                  (ladybird-test-wait conn (lambda () (> (length (funcall sent b 'more nil))
                                                         1)))
                  (should (> (length (funcall sent b)) count)))
                ;; Shown again, the first page gets its whole frame, all bands.
                (let ((full (buffer-local-value 'ladybird--full-frame-count one))
                      (done (length (funcall sent a 'more nil))))
                  (funcall show one)
                  (ladybird-test-wait conn (lambda () (> (length (funcall sent a 'more nil))
                                                         done)))
                  (ladybird-test-wait conn (lambda ()
                                             (> (buffer-local-value 'ladybird--full-frame-count one)
                                                full)))
                  (with-current-buffer one
                    (let ((h (cdr ladybird--canvas-size))
                          (w (car ladybird--canvas-size)))
                      (ladybird-test-wait
                       conn (lambda ()
                              (= (ladybird-module-canvas-pixel ladybird--canvas 3 (1- h))
                                 (ladybird-test-pixel 3 (1- h) 0 w h)))))))
                ;; Closed after the first band of a whole frame: the rest is
                ;; dropped and the other page goes on.
                (funcall show two)
                (ladybird-test-wait conn (lambda () (> (length (funcall sent b 'full t)) 1)))
                (kill-buffer two)
                (ladybird-test-wait conn (lambda () (funcall dropped "closed")))
                (should (ladybird--ready-p conn))
                (set-window-buffer (selected-window) one)
                (ladybird--update)
                (let ((count (buffer-local-value 'ladybird--frame-count one)))
                  (ladybird--send conn `((type . "mouse") (view . ,a) (kind . "down")
                                         (x . 5) (y . 5) (button . "left")
                                         (buttons . ["left"]) (modifiers . 0) (clicks . 1)))
                  (ladybird-test-wait conn (lambda ()
                                             (> (buffer-local-value 'ladybird--frame-count one)
                                                count)))))))
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

(ert-deftest ladybird-mock-test-hints ()
  ;; Keys typed through the command loop choose what the mock server's
  ;; page labels; the labels arrive as frames while they are typed.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird--last-buffer nil)
         (ladybird--hint nil)
         (ladybird-hint-alphabet "asdfghjkl")
         (ladybird-device-pixel-ratio 1.0)
         (inhibit-message t)
         (logged (lambda (type &rest fields)
                   (seq-find (lambda (m)
                               (and (equal (alist-get 'type m) type)
                                    (cl-loop for (key value) on fields by #'cddr
                                             always (equal (alist-get key m)
                                                           value))))
                             (reverse (ladybird-test-log log)))))
         (label-pixel (lambda ()
                        ;; Inside the box of the first item's label.
                        (ladybird-module-canvas-pixel ladybird--canvas 3 3)))
         buffer)
    (save-window-excursion
      (unwind-protect
          (progn
            (setq buffer (ladybird "mock://one" (ladybird-test-mock-host log)))
            (with-current-buffer buffer
              (let ((conn ladybird--conn))
                (ladybird-test-wait conn (lambda () ladybird--canvas))
                (should-not (= (funcall label-pixel) #xffffffff))
                (execute-kbd-macro (kbd "C-c C-o"))
                (ladybird-test-wait conn (lambda () (and ladybird--hint
                                                         (ladybird--hint-items
                                                          ladybird--hint))))
                (should (= (length (ladybird--hint-items ladybird--hint)) 12))
                (ladybird-test-wait
                 conn (lambda () (= (funcall label-pixel) #xffffffff)))
                ;; Narrowing to s hides the label of the first item.
                (execute-kbd-macro "s")
                (ladybird-test-wait
                 conn (lambda () (funcall logged "hints_narrow" 'prefix "s")))
                (ladybird-test-wait
                 conn (lambda () (/= (funcall label-pixel) #xffffffff)))
                (should ladybird--hint)
                (execute-kbd-macro "a")
                (ladybird-test-wait
                 conn (lambda () (funcall logged "_hint_activated"
                                          'index 9 'kind "button")))
                ;; A link loads in the page.
                (execute-kbd-macro (kbd "C-c C-o a a"))
                (ladybird-test-wait
                 conn (lambda () (equal (alist-get 'url ladybird--state)
                                        "https://mock.invalid/link/1")))
                ;; With a prefix argument it opens in a new buffer.
                (execute-kbd-macro (kbd "C-u C-c C-o a g"))
                (ladybird-test-wait
                 conn (lambda () (funcall logged "create_view"
                                          'url "https://mock.invalid/link/5")))
                (should (funcall logged "hints_end" 'activate nil))
                (should (= (length (ladybird--buffers conn)) 2))
                (set-window-buffer (selected-window) buffer)
                ;; A field leaves command mode.
                (ladybird-command-mode 1)
                (execute-kbd-macro (kbd "C-c C-o a d"))
                (ladybird-test-wait
                 conn (lambda () (funcall logged "_hint_activated" 'index 2)))
                (should-not ladybird-command-mode)
                ;; The server ends a session through the real timers.
                (ladybird-goto-url "mock://hints-expire")
                (ladybird-test-wait
                 conn (lambda () (equal (alist-get 'url ladybird--state)
                                        "mock://hints-expire")))
                (execute-kbd-macro (kbd "C-c C-o"))
                (ladybird-test-wait conn (lambda () (and ladybird--hint
                                                         (ladybird--hint-items
                                                          ladybird--hint))))
                (let ((id (ladybird--hint-id ladybird--hint)))
                  (execute-kbd-macro "a")
                  (ladybird-test-wait conn (lambda () (null ladybird--hint)))
                  (should-not (funcall logged "hints_end" 'id id)))
                ;; A page that does not answer in time ends it before the
                ;; labels arrive.
                (ladybird-goto-url "mock://hints-timeout")
                (ladybird-test-wait
                 conn (lambda () (equal (alist-get 'url ladybird--state)
                                        "mock://hints-timeout")))
                (execute-kbd-macro (kbd "C-c C-o"))
                (should (ladybird--hint-waiting ladybird--hint))
                (let ((id (ladybird--hint-id ladybird--hint)))
                  (ladybird-test-wait conn (lambda () (null ladybird--hint)))
                  (should-not (funcall logged "hints_end" 'id id)))
                ;; The server refuses a session: its error ends it.
                (cl-letf (((symbol-function 'ladybird--hint-alphabet-p) #'always))
                  (let ((ladybird-hint-alphabet "aa"))
                    (execute-kbd-macro (kbd "C-c C-o"))))
                (let ((id (ladybird--hint-id ladybird--hint)))
                  (ladybird-test-wait conn (lambda () (null ladybird--hint)))
                  (should (funcall logged "hints" 'id id 'alphabet "aa"))
                  (should-not (funcall logged "hints_end" 'id id)))
                (should-not (eq (key-binding "z") #'ladybird-hint-add-char))
                (should-not (funcall logged "error")))))
        (ladybird--hint-stop)
        (mapc #'kill-buffer (ladybird--buffers))
        (delete-file log)))))

(ert-deftest ladybird-mock-test-no-hints ()
  ;; A server whose welcome lacks the feature gets nothing.
  :tags '(mock)
  (skip-unless (executable-find "python3"))
  (let* ((log (make-temp-file "ladybird-mock" nil ".log"))
         (ladybird--conns nil)
         (ladybird--keepalive-timer nil)
         (ladybird--last-buffer nil)
         (ladybird-device-pixel-ratio 1.0)
         (inhibit-message t)
         buffer)
    (save-window-excursion
      (unwind-protect
          (progn
            (setq buffer (ladybird "mock://one"
                                   (ladybird-test-mock-host log "--no-hints")))
            (with-current-buffer buffer
              (ladybird-test-wait ladybird--conn (lambda () ladybird--canvas))
              (should-error (ladybird-follow-hint) :type 'user-error)
              (should-not ladybird--hint)
              (ladybird--request ladybird--conn "request_selection"
                                 `((view . ,ladybird--view)) #'ignore)
              (ladybird-test-wait
               ladybird--conn
               (lambda () (seq-find (lambda (m) (equal (alist-get 'type m)
                                                       "request_selection"))
                                    (ladybird-test-log log))))
              (should-not (seq-find (lambda (m) (equal (alist-get 'type m) "hints"))
                                    (ladybird-test-log log)))))
        (mapc #'kill-buffer (ladybird--buffers))
        (delete-file log)))))

(provide 'ladybird-render-test)

;;; ladybird-render-test.el ends here
