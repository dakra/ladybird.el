;;; ladybird.el --- Ladybird browser in a canvas image -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ladybird
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.1"))
;; Keywords: comm, hypermedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Show web pages rendered by a Ladybird server in an Emacs canvas image.
;;
;; `ladybird' opens a page in a new buffer.  The server runs locally
;; (`ladybird-program') or on another machine (`ladybird-hosts'); it renders
;; the page and sends the changed pixels, and the native module
;; `ladybird-module' paints them into the buffer's canvas.
;;
;; In a page buffer the keys are Emacs commands: n and p scroll, SPC and
;; DEL page, q buries the buffer, Q closes the page.  `ladybird-insert-mode'
;; (i or RET) sends typed keys to the page; C-c C-c leaves it.  The mouse
;; and the wheel always go to the page.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'format-spec)
(require 'face-remap)
(require 'ladybird-conn)
(require 'ladybird-keys)
(require 'ladybird-module-load nil t)

(declare-function ladybird-load-module "ladybird-module-load")
(declare-function ladybird-module-attach-canvas "ext:ladybird-module"
                  (session view canvas))
(declare-function ladybird-module-register-view "ext:ladybird-module"
                  (session view))
(declare-function ladybird-module-forget-view "ext:ladybird-module"
                  (session view))
(declare-function ladybird-module-repaint "ext:ladybird-module" (session view))

(declare-function browse-url-interactive-arg "browse-url" (prompt))

(defvar tooltip-mode)


;;; Options

(defcustom ladybird-home-url "about:blank"
  "URL `ladybird' opens when it is given none."
  :type 'string
  :group 'ladybird)

(defcustom ladybird-default-host nil
  "Host new pages open on.
nil is the local server, or the only host there is; a string is a
label of `ladybird-hosts'; `ask' prompts when there are several hosts."
  :type '(choice (const :tag "Local server" nil)
                 (const :tag "Ask" ask)
                 (string :tag "Host label"))
  :group 'ladybird)

(defcustom ladybird-device-pixel-ratio (if (featurep 'ns) 1.0 nil)
  "Device pixels the server renders per Emacs pixel.
With nil this is the frame's scale factor (`frame-scale-factor'): the
page is rendered at the display's resolution and the canvas is shown
scaled down by that factor.  A number sets the ratio; with 1.0 the
canvas is shown unscaled.

On macOS Emacs draws a canvas unscaled, which shows only a part of a
page rendered at a higher ratio, so the default there is 1.0.  Set
this to nil on an Emacs whose NS port applies the image transform to
canvases."
  :type '(choice (const :tag "The frame's scale factor" nil)
                 (number :tag "Ratio"))
  :group 'ladybird)

(defcustom ladybird-resize-delay 0.05
  "Seconds to wait after a window change before resizing the page."
  :type 'number
  :group 'ladybird)

(defcustom ladybird-hover-interval 0.016
  "Minimum seconds between two mouse movements sent to the page."
  :type 'number
  :group 'ladybird)

(defcustom ladybird-track-hover t
  "Whether the page sees the mouse moving with no button held.
This sets the variables `track-mouse' and
`mouse-fine-grained-tracking' while a page
buffer's window is selected."
  :type 'boolean
  :group 'ladybird)

(defcustom ladybird-show-link-hover t
  "Whether the echo area shows the URL of the link under the mouse."
  :type 'boolean
  :group 'ladybird)

(defcustom ladybird-header-line t
  "Whether page buffers show the icon, title and URL in a header line."
  :type 'boolean
  :group 'ladybird)

(defcustom ladybird-buffer-name-format "*ladybird: %t*"
  "Format of page buffer names.
%t is the page's title, %u its URL and %h the label of its host."
  :type 'string
  :group 'ladybird)

(defcustom ladybird-alert-style 'echo
  "How a page's alert is shown.
`echo' shows it in the echo area and lets the page continue at once;
`prompt' waits for a key."
  :type '(choice (const echo) (const prompt))
  :group 'ladybird)

(defcustom ladybird-scroll-step nil
  "Pixels the line scroll commands move, or nil for three text lines."
  :type '(choice (const :tag "Three lines" nil) integer)
  :group 'ladybird)

(defcustom ladybird-console-max-lines 10000
  "Lines the console buffer keeps; older output is deleted."
  :type 'integer
  :group 'ladybird)

(defcustom ladybird-console-buffer "*ladybird-console*"
  "Name of the buffer that collects the pages' console output."
  :type 'string
  :group 'ladybird)

(defcustom ladybird-keep-view-on-kill nil
  "Whether killing a page buffer leaves its page open on the server.
A page left open shows up again with the next connection to a server
that outlives its clients."
  :type 'boolean
  :group 'ladybird)


;;; State

(defvar-local ladybird--conn nil "The buffer's connection.")
(defvar-local ladybird--host nil "The buffer's host, a (LABEL ENDPOINT...) list.")
(defvar-local ladybird--view nil "Id of the buffer's view on the server.")
(defvar-local ladybird--creating nil
  "Non-nil while the buffer awaits the answer to its `create_view'.")
(defvar-local ladybird--url-at-create nil "URL the buffer's view opens with.")
(defvar-local ladybird--canvas nil "The buffer's canvas image spec.")
(defvar-local ladybird--canvas-size nil
  "Size of the buffer's canvas, (WIDTH . HEIGHT) in device pixels.")
(defvar-local ladybird--dpr 1.0
  "Device pixels per Emacs pixel of the buffer's canvas.")
(defvar-local ladybird--requested-size nil
  "The (WIDTH HEIGHT DPR) last requested from the server.")
(defvar-local ladybird--visible 'unknown
  "Visibility last sent to the server, or `unknown'.")
(defvar-local ladybird--focused 'unknown
  "Focus last sent to the server, or `unknown'.")
(defvar-local ladybird--state nil "The view's last `state' message.")
(defvar-local ladybird--favicon nil "The page's icon as an image, or nil.")
(defvar-local ladybird--cursor 'arrow "Pointer shape over the canvas.")
(defvar-local ladybird--hover-url nil
  "The link URL last shown in the echo area, as it was shown.")
(defvar-local ladybird--buttons nil "Names of the mouse buttons held on the page.")
(defvar-local ladybird--clicks 1 "Click count of the last button press.")
(defvar-local ladybird--inside nil
  "Non-nil while the page has seen the mouse and no `leave' since.")
(defvar-local ladybird--last-xy '(0 . 0)
  "The last mouse position on the canvas, in device pixels.")
(defvar-local ladybird--last-move 0.0 "Time the last mouse movement was sent.")
(defvar-local ladybird--move-timer nil "Timer that sends a held-back movement.")
(defvar-local ladybird--pending-move nil "The mouse movement event held back.")
(defvar-local ladybird--bg-cookie nil "Face remapping of the page's background.")
(defvar-local ladybird--blocked-popup nil "URL of the last popup the page tried.")
(defvar-local ladybird--console nil
  "Non-nil while the page sends its console output.")
(defvar-local ladybird--find-string nil "The string last searched for in the page.")
(defvar-local ladybird--find-result nil
  "The (INDEX . TOTAL) of the last search result, or nil.
INDEX counts from 1 and is 0 without a match; TOTAL can be nil.")
(defvar-local ladybird--dropped-frames 0
  "Number of frames of this view the module could not use.")

(defvar ladybird--canvas-serial 0 "Counter that makes canvas ids unique.")
(defvar ladybird--update-timer nil "Timer that syncs views with their windows.")
(defvar ladybird--saved-tracking nil
  "The mouse tracking settings to restore.
A list of the values the variables `track-mouse' and
`mouse-fine-grained-tracking' had before ladybird set them, while it
has them set for a selected page window or a drag; else nil.")
(defvar ladybird--dragging nil
  "Non-nil while a mouse button pressed on a page is held.")
(defvar ladybird--last-buffer nil "The page buffer used last.")
(defvar ladybird-url-history nil "History of URLs read by ladybird commands.")
(defvar ladybird-find-history nil "History of strings searched for in pages.")
(defvar ladybird--find-buffer nil "The page buffer `ladybird-find' searches.")
(defvar ladybird--find-timer nil "Timer that sends the search string typed.")
(defvar ladybird--find-overlay nil
  "Overlay that shows the match count in the minibuffer.")

(defvar ladybird-insert-mode)


;;; Module

(defun ladybird--ensure-module ()
  "Load the native module unless its functions are defined."
  (unless (ladybird--module-available-p)
    (when (fboundp 'ladybird-load-module)
      (ladybird-load-module))))


;;; Buffers and views

(defun ladybird--buffers (&optional conn)
  "Return the live page buffers, or only those of CONN."
  (seq-filter (lambda (buffer)
                (and (eq (buffer-local-value 'major-mode buffer) 'ladybird-mode)
                     (or (null conn)
                         (eq (buffer-local-value 'ladybird--conn buffer) conn))))
              (buffer-list)))

(defun ladybird--view-buffer (conn msg)
  "Return the live buffer of the view MSG names on CONN, or nil."
  (let ((buffer (gethash (alist-get 'view msg) (ladybird--conn-views conn))))
    (and (buffer-live-p buffer) buffer)))

(defmacro ladybird--with-view (conn msg &rest body)
  "Run BODY in the buffer of the view MSG names on CONN, if it is live."
  (declare (indent 2) (debug t))
  `(when-let* ((buffer (ladybird--view-buffer ,conn ,msg)))
     (with-current-buffer buffer ,@body)))

(defun ladybird--send-view (type &rest fields)
  "Send a message of TYPE about the current buffer's view.
FIELDS are the other fields, an alist.  Return non-nil if it was sent."
  (and ladybird--view
       (ladybird--send ladybird--conn `((type . ,type) (view . ,ladybird--view)
                                    ,@fields))))

(defun ladybird--url ()
  "Return the URL of the current buffer's page."
  (or (alist-get 'url ladybird--state) ladybird--url-at-create))

(defun ladybird--buffer-name ()
  "Return the current buffer's name as `ladybird-buffer-name-format' says."
  (let ((title (alist-get 'title ladybird--state))
        (url (or (ladybird--url) "")))
    (format-spec ladybird-buffer-name-format
                 `((?t . ,(if (or (null title) (string-empty-p title)) url title))
                   (?u . ,url)
                   (?h . ,(or (car ladybird--host) "local"))))))

(defun ladybird--rename ()
  "Rename the current buffer after its page."
  (let ((name (ladybird--buffer-name)))
    (unless (or (equal name (buffer-name))
                (string-match-p (concat "\\`" (regexp-quote name) "<[0-9]+>\\'")
                                (buffer-name)))
      (rename-buffer name t))))

(defun ladybird--insert-canvas ()
  "Fill the current buffer with the character that shows the canvas."
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (erase-buffer)
      (insert (propertize " " 'pointer ladybird--cursor 'rear-nonsticky t) "\n")
      (when ladybird--canvas
        (put-text-property 1 2 'display ladybird--canvas))
      (unless (or (display-graphic-p) noninteractive)
        (insert "ladybird needs a graphical frame\n"))
      (goto-char (point-min)))))

(defun ladybird--make-view-buffer (conn view url &optional host)
  "Return a new page buffer for VIEW on CONN, opening with URL.
VIEW is nil for a view not yet created.  HOST is the (LABEL
ENDPOINT...) list CONN was dialled with."
  (let ((buffer (generate-new-buffer " *ladybird*")))
    (with-current-buffer buffer
      (ladybird-mode)
      (setq ladybird--conn conn
            ladybird--view view
            ladybird--url-at-create url
            ladybird--host (or host
                             (and conn (cons (ladybird--conn-host conn)
                                             (ladybird--conn-endpoints conn)))))
      (when (and conn view)
        (puthash view buffer (ladybird--conn-views conn))
        (ladybird-module-register-view (ladybird--conn-decoder conn) view))
      (ladybird--insert-canvas)
      (ladybird--rename))
    buffer))

(defun ladybird--make-canvas (width height dpr)
  "Return a canvas image spec of WIDTH x HEIGHT device pixels.
It is shown scaled down by DPR, the device pixels per Emacs pixel."
  (append (list 'image :type 'canvas
                :id (intern (format "ladybird-%s-%d" ladybird--view
                                    (cl-incf ladybird--canvas-serial)))
                :data-width width :data-height height)
          (unless (= dpr 1)
            (list :scale (/ 1.0 dpr)))
          (list :ascent 100 :margin 0)))

(defun ladybird--replace-canvas (width height dpr)
  "Show the current view in a new canvas of WIDTH x HEIGHT device pixels.
DPR is the device pixel ratio the frames are rendered at.  The module
paints the view's last frame into the new canvas."
  (let ((canvas (ladybird--make-canvas width height dpr))
        (decoder (ladybird--conn-decoder ladybird--conn))
        (inhibit-read-only t))
    (ladybird-module-attach-canvas decoder ladybird--view canvas)
    (setq ladybird--canvas canvas
          ladybird--canvas-size (cons width height)
          ladybird--dpr (float dpr))
    (with-silent-modifications
      (put-text-property 1 2 'display canvas))
    (ladybird-module-repaint decoder ladybird--view)))

(defun ladybird--on-frame (conn event)
  "Handle the frame EVENT the module returned on CONN.
A frame the module kept without painting it has another size than the
canvas, or there is no canvas yet, or Emacs rejected the canvas: the
view gets a canvas of the frame's size."
  (pcase-let ((`(frame ,view ,_seq ,width ,height ,dpr ,_ ,_ ,_ ,_ ,_ ,status)
               event))
    (let ((buffer (and view (gethash view (ladybird--conn-views conn)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (pcase status
            ((or 'stored 'size-mismatch 'canvas-error)
             (ladybird--replace-canvas width height dpr))
            ('painted nil)
            (_ (cl-incf ladybird--dropped-frames))))))))

(defun ladybird--dpr (window)
  "Return the device pixel ratio to render at for WINDOW."
  (float (or ladybird-device-pixel-ratio
             (frame-scale-factor (window-frame window)))))

(defun ladybird--desired-size (&optional buffer)
  "Return the (WIDTH HEIGHT DPR) BUFFER's view should have, or nil.
The size is in device pixels and fits every window showing BUFFER, by
default the current buffer; it is nil when no window shows it."
  (when-let* ((windows (get-buffer-window-list (or buffer (current-buffer))
                                               nil t)))
    (let ((dpr (ladybird--dpr (car windows))))
      (list (max 1 (round (* dpr (apply #'min (mapcar
                                               (lambda (w) (window-body-width w t))
                                               windows)))))
            (max 1 (round (* dpr (apply #'min (mapcar
                                               (lambda (w) (window-body-height w t))
                                               windows)))))
            dpr))))

(defun ladybird--hello-viewport ()
  "Return the (WIDTH HEIGHT DPR) of the selected window for a hello."
  (let ((dpr (ladybird--dpr (selected-window))))
    (list (max 1 (round (* dpr (window-body-width nil t))))
          (max 1 (round (* dpr (window-body-height nil t))))
          dpr)))

(defun ladybird--mini-window-excess (frame)
  "Return the pixels FRAME's mini-window is taller than one line."
  (let ((window (minibuffer-window frame)))
    (if (and (window-live-p window) (eq (window-frame window) frame))
        (max 0 (- (window-pixel-height window) (frame-char-height frame)))
      0)))

(defun ladybird--mini-window-took-p (size)
  "Return non-nil if SIZE is the requested size less what a mini-window took.
SIZE is the (WIDTH HEIGHT DPR) the current buffer's windows have now.
A mini-window that grows for a long prompt or message takes its lines
from the other windows of its frame and gives them back when it
shrinks: a height that is smaller than the one requested by no more
than the mini-window has grown, at the same width, is such a loan."
  (when-let* ((requested ladybird--requested-size)
              (windows (get-buffer-window-list nil nil t)))
    (let ((lost (- (nth 1 requested) (nth 1 size)))
          (excess (apply #'max (mapcar (lambda (window)
                                         (ladybird--mini-window-excess
                                          (window-frame window)))
                                       windows))))
      (and (> excess 0)
           (> lost 0)
           (<= lost (ceiling (* excess (nth 2 size))))
           (= (nth 0 size) (nth 0 requested))
           (= (nth 2 size) (nth 2 requested))))))

(defun ladybird--sync-viewport (buffer)
  "Tell the server the size and visibility of BUFFER's view if they changed.
The page keeps its size while a grown mini-window borrows lines from
its windows."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and ladybird--view (ladybird--ready-p ladybird--conn))
        (let ((size (ladybird--desired-size))
              (visible (and (get-buffer-window buffer 'visible) t)))
          (when (and size
                     (not (equal size ladybird--requested-size))
                     (not (ladybird--mini-window-took-p size)))
            (setq ladybird--requested-size size)
            (ladybird--send-view "set_viewport"
                               `(width . ,(nth 0 size))
                               `(height . ,(nth 1 size))
                               `(dpr . ,(nth 2 size))))
          (unless (eq visible ladybird--visible)
            (setq ladybird--visible visible)
            (ladybird--send-view "set_visibility"
                               `(visible . ,(ladybird--bool visible)))))))))

(defun ladybird--sync-focus (buffer)
  "Tell the server whether BUFFER's view has the focus if that changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and ladybird--view (ladybird--ready-p ladybird--conn))
        (let ((focused (and (eq (window-buffer (selected-window)) buffer)
                            (frame-focus-state)
                            t)))
          (unless (eq focused ladybird--focused)
            (setq ladybird--focused focused)
            (ladybird--send-view "set_focus"
                               `(focused . ,(ladybird--bool focused)))))))))

(defun ladybird--sync-tracking (&optional after-command)
  "Report mouse movement to a selected page window and during a drag.
The variable `track-mouse' is `dragging' while a button pressed on a
page is held and t while a page buffer's window is selected with
`ladybird-track-hover' set; what it and `mouse-fine-grained-tracking'
were before is saved once, when neither held, and put back when
neither holds any more.

A command or a recursive edit can have the variable bound: its value is
neither saved nor put back inside a recursive edit or, unless
AFTER-COMMAND is non-nil, while a command runs.  `post-command-hook'
calls this with AFTER-COMMAND and so catches up."
  (let* ((top (and (= (recursion-depth) 0)
                   (or after-command (null this-command))))
         (hover (and ladybird-track-hover
                     (eq (buffer-local-value 'major-mode
                                             (window-buffer (selected-window)))
                         'ladybird-mode)))
         (active (or hover ladybird--dragging)))
    (cond
     ((and active (or top ladybird--saved-tracking))
      (unless ladybird--saved-tracking
        (setq ladybird--saved-tracking
              (list track-mouse mouse-fine-grained-tracking)))
      (let ((wanted (if ladybird--dragging 'dragging t)))
        (unless (eq track-mouse wanted)
          (setq track-mouse wanted)))
      (when hover
        (setq mouse-fine-grained-tracking t)))
     ((and (not active) top ladybird--saved-tracking)
      (setq track-mouse (nth 0 ladybird--saved-tracking)
            mouse-fine-grained-tracking (nth 1 ladybird--saved-tracking)
            ladybird--saved-tracking nil)))
    (unless (or ladybird--saved-tracking ladybird--dragging (ladybird--buffers))
      (remove-hook 'post-command-hook #'ladybird--after-command))))

(defun ladybird--after-command ()
  "Bring mouse tracking in line once a command has ended."
  (ladybird--sync-tracking t))

(defun ladybird--update ()
  "Bring every view in line with the windows showing it."
  (setq ladybird--update-timer nil)
  (dolist (buffer (ladybird--buffers))
    (ladybird--sync-viewport buffer)
    (ladybird--sync-focus buffer))
  (ladybird--sync-tracking))

(defun ladybird--schedule-update (&rest _)
  "Run `ladybird--update' once the windows have been quiet for a moment.
Window change hooks run during redisplay, where nothing may be sent."
  (when (timerp ladybird--update-timer)
    (cancel-timer ladybird--update-timer))
  (setq ladybird--update-timer
        (run-at-time ladybird-resize-delay nil #'ladybird--update)))

(defalias 'ladybird--window-size-changed #'ladybird--schedule-update)
(defalias 'ladybird--window-buffer-changed #'ladybird--schedule-update)
(defalias 'ladybird--selection-changed #'ladybird--schedule-update)

(defun ladybird--focus-changed ()
  "Follow a change of the frames' focus."
  (unless (frame-focus-state)
    (dolist (buffer (ladybird--buffers))
      (with-current-buffer buffer
        (ladybird--leave))))
  (when (ladybird--buffers)
    (ladybird--schedule-update)))

(defun ladybird--create-view ()
  "Ask the server for a view for the current buffer.
The view opens the buffer's URL at the size of its windows.  The
request carries an id that the server's answer names."
  (unless (or ladybird--view ladybird--creating)
    (let* ((size (or (ladybird--desired-size) (ladybird--hello-viewport)))
           (conn ladybird--conn)
           (buffer (current-buffer))
           (request (ladybird--request
                     conn "create_view"
                     `((url . ,(or (ladybird--url) ladybird-home-url))
                       (width . ,(nth 0 size))
                       (height . ,(nth 1 size))
                       (dpr . ,(nth 2 size)))
                     (lambda (msg)
                       (ladybird--create-answered conn buffer msg)))))
      ;; The request is pending only if it was sent.
      (when (gethash request (ladybird--conn-pending conn))
        (setq ladybird--creating t
              ladybird--requested-size size)
        (setf (ladybird--conn-creating conn)
              (append (ladybird--conn-creating conn)
                      (list (cons buffer request))))))))

(defun ladybird--create-answered (conn buffer msg)
  "Handle MSG, the server's answer to the `create_view' of BUFFER on CONN.
It is a `view_created', or an `error' when the server opens no view."
  (setf (ladybird--conn-creating conn)
        (seq-remove (lambda (entry) (eq (car entry) buffer))
                    (ladybird--conn-creating conn)))
  (if (equal (alist-get 'type msg) "view_created")
      (ladybird--view-created conn buffer msg)
    (ladybird--create-failed conn buffer (alist-get 'message msg))))

(defun ladybird--pop-creating (conn)
  "Return the buffer that has waited longest for a view on CONN.
Its request is no longer pending.  This matches an answer of a server
that does not name the request."
  (pcase-let ((`(,buffer . ,request) (pop (ladybird--conn-creating conn))))
    (when request
      (remhash request (ladybird--conn-pending conn)))
    buffer))

(defun ladybird--view-created (conn buffer msg)
  "Give BUFFER the view the `view_created' message MSG announces on CONN.
A view whose buffer was killed meanwhile is closed."
  (let ((view (alist-get 'view msg)))
    (if (not (buffer-live-p buffer))
        (ladybird--send conn `((type . "close_view") (view . ,view)))
      (with-current-buffer buffer
        (setq ladybird--creating nil
              ladybird--view view)
        (puthash view buffer (ladybird--conn-views conn))
        (ladybird-module-register-view (ladybird--conn-decoder conn) view)
        (when ladybird--canvas
          (ladybird-module-attach-canvas (ladybird--conn-decoder conn) view
                                         ladybird--canvas))
        (ladybird--apply-state (append msg ladybird--state))
        (ladybird--sync-viewport buffer)
        (ladybird--sync-focus buffer)))))

(defun ladybird--page-buffer (conn)
  "Return a buffer of CONN that shows a page: the one used last, or any."
  (let ((buffers (seq-filter (lambda (buffer)
                               (buffer-local-value 'ladybird--view buffer))
                             (ladybird--buffers conn))))
    (if (memq ladybird--last-buffer buffers)
        ladybird--last-buffer
      (car buffers))))

(defun ladybird--load-in-page (conn buffer url)
  "Load URL in BUFFER, the page CONN's server shows instead of a new one."
  (with-current-buffer buffer
    (ladybird--send-view "load" `(url . ,url)))
  (message "ladybird: %s opens no further page; %s loaded in %s"
           (ladybird--conn-name conn) url (buffer-name buffer)))

(defun ladybird--create-failed (conn buffer reason)
  "Give up on BUFFER, for which CONN's server opened no view.
REASON is the server's message.  A server that has pages open and
refuses another has reached its limit, which CONN remembers; the URL
is then loaded in a page it has, shown where BUFFER was."
  (let* ((count (hash-table-count (ladybird--conn-views conn)))
         (page (ladybird--page-buffer conn))
         (url (and (buffer-live-p buffer)
                   (buffer-local-value 'ladybird--url-at-create buffer))))
    (when (> count 0)
      (setf (ladybird--conn-view-limit conn) count))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq ladybird--creating nil))
      (when page
        (dolist (window (get-buffer-window-list buffer nil t))
          (set-window-buffer window page))
        (when (eq ladybird--last-buffer buffer)
          (setq ladybird--last-buffer page)))
      (kill-buffer buffer))
    (if (and page url)
        (ladybird--load-in-page conn page url)
      (message "ladybird: %s opened no page: %s" (ladybird--conn-name conn)
               (or reason "no reason given")))))

(defun ladybird--forget-view ()
  "Detach the current buffer from its view without closing the view.
The module drops the view's frame, canvas and shared memory."
  (when (and ladybird--conn ladybird--view)
    (remhash ladybird--view (ladybird--conn-views ladybird--conn))
    (when-let* ((decoder (ladybird--conn-decoder ladybird--conn)))
      (ignore-errors (ladybird-module-forget-view decoder ladybird--view))))
  (setq ladybird--view nil
        ladybird--creating nil
        ladybird--requested-size nil
        ladybird--visible 'unknown
        ladybird--focused 'unknown))

(defun ladybird--adopt (buffer conn)
  "Make BUFFER a page buffer of the ready CONN and give it a view."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless (eq ladybird--conn conn)
        (ladybird--forget-view)
        (setq ladybird--conn conn))
      (ladybird--create-view)
      (force-mode-line-update))))

(defun ladybird--apply-state (state)
  "Take the alist STATE as the state of the current buffer's page."
  (setq ladybird--state state)
  (ladybird--rename)
  (force-mode-line-update))

(defun ladybird--on-welcome (conn msg)
  "Line the page buffers of CONN up with the views in the welcome MSG.
A listed view keeps its buffer or gets a new one; a buffer whose view
is gone asks for a new view with its URL.  The views of another server
process than the one CONN had before are all new, whatever their ids.
Views whose buffers were killed while the connection was down are
closed."
  (let* ((changed (ladybird--conn-server-changed conn))
         (closing (and (not changed) (ladybird--conn-closing conn)))
         (views (seq-remove
                 (lambda (view)
                   (let ((id (alist-get 'view view)))
                     (when (memq id closing)
                       (ladybird--send conn `((type . "close_view")
                                              (view . ,id)))
                       t)))
                 (alist-get 'views msg)))
         (listed (mapcar (lambda (view) (alist-get 'view view)) views))
         (new 0))
    (setf (ladybird--conn-creating conn) nil
          (ladybird--conn-closing conn) nil)
    (when changed
      (setf (ladybird--conn-view-limit conn) nil))
    (dolist (buffer (ladybird--buffers conn))
      (with-current-buffer buffer
        (setq ladybird--creating nil
              ladybird--requested-size nil
              ladybird--visible 'unknown
              ladybird--focused 'unknown
              ladybird--buttons nil
              ladybird--inside nil)
        (unless (and ladybird--view (not changed) (memq ladybird--view listed))
          (ladybird--forget-view)
          (ladybird--create-view))))
    (dolist (view views)
      (let ((id (alist-get 'view view)))
        (unless (buffer-live-p (gethash id (ladybird--conn-views conn)))
          (cl-incf new)
          (with-current-buffer (ladybird--make-view-buffer
                                conn id (alist-get 'url view))
            (ladybird--apply-state view)))))
    (when (> new 0)
      (message "ladybird: %d view%s on %s" new (if (= new 1) "" "s")
               (ladybird--conn-name conn)))
    (dolist (buffer (ladybird--buffers conn))
      (ladybird--sync-viewport buffer)
      (ladybird--sync-focus buffer))
    ;; A connection redialled only to close views has nothing left to do.
    (when (and closing (null (ladybird--buffers conn)))
      (ladybird--linger conn))))

(defun ladybird--linger (conn)
  "Close CONN in a moment unless it is in use again by then.
What was just written to it gets time to leave; a `view_closed' ends
the wait."
  (unless (timerp (ladybird--conn-lingering conn))
    (setf (ladybird--conn-lingering conn)
          (run-at-time 1 nil #'ladybird--linger-end conn))))

(defun ladybird--linger-end (conn)
  "Close CONN, which was left unused, if it still is."
  (when (timerp (ladybird--conn-lingering conn))
    (cancel-timer (ladybird--conn-lingering conn)))
  (setf (ladybird--conn-lingering conn) nil)
  (when (and (memq conn ladybird--conns)
             (null (ladybird--buffers conn))
             (null (ladybird--conn-on-ready conn)))
    (ladybird--disconnect conn)))

(defun ladybird--on-conn-change (conn)
  "Show CONN's new state in its page buffers."
  (dolist (buffer (ladybird--buffers conn))
    (with-current-buffer buffer
      (force-mode-line-update))))

(setq ladybird--frame-function #'ladybird--on-frame
      ladybird--welcome-function #'ladybird--on-welcome
      ladybird--change-function #'ladybird--on-conn-change
      ladybird--viewport-function #'ladybird--hello-viewport)

(ladybird--defhandler "view_created" (conn msg)
  "Give the buffer that has waited longest the view the server created.
This handles a `view_created' that does not name its request."
  (ladybird--view-created conn (ladybird--pop-creating conn) msg))

(ladybird--defhandler "state" (conn msg)
  "Record the state of a view on CONN."
  (ladybird--with-view conn msg
    (ladybird--apply-state msg)))

(ladybird--defhandler "view_closed" (conn msg)
  "Kill the buffer of a view the server closed on CONN."
  (ladybird--with-view conn msg
    (unless (equal (alist-get 'reason msg) "client")
      (message "ladybird: %s closed (%s)" (buffer-name)
               (alist-get 'reason msg)))
    (ladybird--forget-view)
    (kill-buffer buffer))
  (when (ladybird--conn-lingering conn)
    (ladybird--linger-end conn)))

(ladybird--defhandler "crashed" (conn msg)
  "Report that the page of a view on CONN crashed."
  (ladybird--with-view conn msg
    (message "ladybird: the page in %s crashed: %s" (buffer-name)
             (alist-get 'reason msg))))

(ladybird--defhandler "background_color" (conn msg)
  "Give the buffer of a view on CONN the page's background colour."
  (ladybird--with-view conn msg
    (when ladybird--bg-cookie
      (face-remap-remove-relative ladybird--bg-cookie))
    (setq ladybird--bg-cookie
          (and-let* ((rgb (alist-get 'rgb msg)))
            (face-remap-add-relative 'default :background rgb)))))

(defun ladybird--kill ()
  "Close the view of the page buffer being killed.
An error is reported and does not keep the buffer from being killed."
  (condition-case err
      (ladybird--kill-view)
    (error (message "ladybird: closing %s: %S" (buffer-name) err))))

(defun ladybird--kill-view ()
  "Close the view of the current buffer and, with its last buffer, the connection.
With `ladybird-keep-view-on-kill' the view stays open on the server,
hidden and without focus.  A view that cannot be closed now because the
connection is being dialled again is closed when it is back."
  (let ((conn ladybird--conn)
        (view ladybird--view)
        (closed nil))
    (ladybird--drop-pending-move)
    (when (and conn view)
      (cond
       (ladybird-keep-view-on-kill
        (when (ladybird--ready-p conn)
          (ladybird--send-view "set_visibility" '(visible . :false))
          (ladybird--send-view "set_focus" '(focused . :false))))
       ((ladybird--ready-p conn)
        (setq closed (ladybird--send conn `((type . "close_view")
                                            (view . ,view)))))
       ((memq (ladybird--conn-state conn) '(redialing dialing hello))
        (cl-pushnew view (ladybird--conn-closing conn))))
      (ladybird--forget-view))
    (when (eq ladybird--last-buffer (current-buffer))
      (setq ladybird--last-buffer nil))
    (ladybird--schedule-update)
    (when (and conn
               (memq conn ladybird--conns)
               (not (remq (current-buffer) (ladybird--buffers conn)))
               (not (ladybird--conn-on-ready conn))
               (not (ladybird--conn-closing conn)))
      (if (and closed
               (eq (process-type (ladybird--conn-process conn)) 'network))
          (ladybird--linger conn)
        (ladybird--disconnect conn)))))


;;; Header and mode line

(defun ladybird--conn-tag ()
  "Return a header line tag for the state of the buffer's connection."
  (pcase (and ladybird--conn (ladybird--conn-state ladybird--conn))
    ('ready (and (not ladybird--view) " [opening]"))
    ('replaced " [detached]")
    ('redialing
     (format " [reconnecting in %ds]"
             (max 0 (round (- (or (ladybird--conn-retry-at ladybird--conn)
                                  (float-time))
                              (float-time))))))
    ((or 'dialing 'hello) " [connecting]")
    (_ " [disconnected]")))

(defun ladybird--url-origin (url)
  "Return the start of URL that names its scheme and host."
  (cond ((string-match "\\`[[:alpha:]][[:alnum:]+.-]*://[^/?#]*" url)
         (match-string 0 url))
        ((string-match "\\`[[:alpha:]][[:alnum:]+.-]*:" url)
         (match-string 0 url))
        (t url)))

(defun ladybird--header-line ()
  "Return the header line of a page buffer.
The URL comes first and always shows at least its scheme and host; the
page's title follows in the room that is left before the tags."
  (let* ((url (or (ladybird--url) ""))
         (title (alist-get 'title ladybird--state))
         (title (and title (string-trim (replace-regexp-in-string
                                         "[\n\t\r ]+" " " title))))
         (icon (if ladybird--favicon
                   (concat " " (propertize " " 'display ladybird--favicon) " ")
                 " "))
         (tags (concat (and (alist-get 'loading ladybird--state) " [loading]")
                       (ladybird--conn-tag)))
         ;; The icon is about two columns wide.
         (room (max 0 (- (window-width) (string-width icon) (string-width tags)
                         (if ladybird--favicon 2 0))))
         (url-width (string-width url))
         ;; The origin and the mark that more follows.
         (least (min url-width room
                     (max 20 (1+ (string-width (ladybird--url-origin url))))))
         (title-room (- room least 3))
         (title (and title (not (string-empty-p title)) (> title-room 3)
                     (truncate-string-to-width title title-room nil nil t)))
         (url-room (max least (- room (if title (+ 3 (string-width title)) 0)))))
    (string-replace
     "%" "%%"
     (concat icon
             (truncate-string-to-width url url-room nil nil t)
             (and title (concat " — " (propertize title 'face 'bold)))
             tags))))

(defun ladybird--mode-line-process ()
  "Return the mode line tags of a page buffer."
  (concat
   (and ladybird-insert-mode
        (propertize ":Insert"
                    'mouse-face 'mode-line-highlight
                    'help-echo "mouse-1: leave insert mode"
                    'local-map (make-mode-line-mouse-map
                                'mouse-1 #'ladybird-insert-mode)))
   (and (alist-get 'loading ladybird--state) ":Loading")))


;;; Mouse

(defun ladybird--event-buffer (posn)
  "Return the page buffer of the window POSN is in, or nil."
  (let ((window (posn-window posn)))
    (and (windowp window)
         (eq (buffer-local-value 'major-mode (window-buffer window))
             'ladybird-mode)
         (window-buffer window))))

(defun ladybird--mouse-posn-xy (posn &optional clamp)
  "Return POSN as (X . Y) in device pixels of the current buffer's canvas.
Return nil for a position off the canvas, unless CLAMP is non-nil: then
it is moved to the nearest canvas pixel, and a position in another
window gives the last position on the canvas."
  (when ladybird--canvas-size
    (let* ((window (posn-window posn))
           (here (and (windowp window)
                      (eq (window-buffer window) (current-buffer))))
           (xy (cond ((and here (posn-image posn) (not (posn-area posn)))
                      (posn-object-x-y posn))
                     ((and clamp here (not (posn-area posn)))
                      (posn-x-y posn)))))
      (cond
       (xy (setq ladybird--last-xy
                 (cons (max 0 (min (1- (car ladybird--canvas-size))
                                   (round (* (car xy) ladybird--dpr))))
                       (max 0 (min (1- (cdr ladybird--canvas-size))
                                   (round (* (cdr xy) ladybird--dpr)))))))
       (clamp ladybird--last-xy)))))

(defun ladybird--drop-pending-move ()
  "Forget the mouse movement held back in the current buffer."
  (when (timerp ladybird--move-timer)
    (cancel-timer ladybird--move-timer))
  (setq ladybird--move-timer nil
        ladybird--pending-move nil))

(defun ladybird--send-mouse (kind xy &rest fields)
  "Send a mouse message of KIND at XY, device pixels (X . Y).
FIELDS are further fields, an alist.  XY is nil for a `leave'."
  (setq ladybird--inside (not (equal kind "leave")))
  (apply #'ladybird--send-view "mouse" `(kind . ,kind)
         (append (and xy `((x . ,(car xy)) (y . ,(cdr xy))))
                 fields)))

(defun ladybird--leave ()
  "Tell the page that the mouse left it and holds no button."
  (setq ladybird--buttons nil)
  (when ladybird--inside
    (ladybird--send-mouse "leave" nil)))

(defvar ladybird--drag-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-movement] #'ladybird-mouse-move)
    map)
  "Keymap active while a mouse button is held on a page.")

(defun ladybird--begin-drag-tracking ()
  "Report mouse movement until the next command that is not one."
  (setq ladybird--dragging t)
  (ladybird--sync-tracking t)
  (set-transient-map ladybird--drag-map
                     (lambda () (eq this-command 'ladybird-mouse-move))
                     (lambda ()
                       (setq ladybird--dragging nil)
                       (ladybird--sync-tracking t))))

(defun ladybird-mouse-down (event)
  "Send the button press EVENT to the page."
  (interactive "e")
  (when-let* ((posn (event-start event))
              (buffer (ladybird--event-buffer posn)))
    (select-window (posn-window posn))
    (with-current-buffer buffer
      (when-let* ((button (ladybird-keys-button event))
                  (xy (ladybird--mouse-posn-xy posn)))
        (ladybird--drop-pending-move)
        (setq ladybird--last-buffer buffer
              ladybird--clicks (max 1 (min 3 (event-click-count event))))
        (cl-pushnew button ladybird--buttons :test #'equal)
        (ladybird--send-mouse
         "down" xy
         `(button . ,button)
         `(buttons . ,(vconcat ladybird--buttons))
         `(modifiers . ,(ladybird-keys-modifiers (event-modifiers event)))
         `(clicks . ,ladybird--clicks))
        (ladybird--begin-drag-tracking)))))

(defun ladybird-mouse-up (event)
  "Send the button release EVENT to the page that saw the press.
A release away from the last position sent is preceded by a movement
to it."
  (interactive "e")
  (when-let* ((button (ladybird-keys-button event))
              (buffer (or (seq-find (lambda (buffer)
                                      (member button
                                              (buffer-local-value
                                               'ladybird--buttons buffer)))
                                    (ladybird--buffers))
                          (ladybird--event-buffer (event-start event)))))
    (with-current-buffer buffer
      (when (member button ladybird--buttons)
        (ladybird--drop-pending-move)
        (let* ((sent ladybird--last-xy)
               (xy (ladybird--mouse-posn-xy (event-end event) t))
               (modifiers (ladybird-keys-modifiers (event-modifiers event))))
          ;; The page extends a selection or a drag on movements only.
          (unless (equal xy sent)
            (ladybird--send-mouse "move" xy
                                `(buttons . ,(vconcat ladybird--buttons))
                                `(modifiers . ,modifiers)))
          (setq ladybird--buttons (remove button ladybird--buttons))
          (ladybird--send-mouse "up" xy
                              `(button . ,button)
                              `(buttons . ,(vconcat ladybird--buttons))
                              `(modifiers . ,modifiers)
                              `(clicks . ,ladybird--clicks)))))))

(defun ladybird--send-move (event)
  "Send the mouse movement EVENT to the page of the current buffer.
A movement off the canvas with no button held is sent as a `leave'."
  (setq ladybird--last-move (float-time)
        ladybird--pending-move nil)
  (let ((xy (ladybird--mouse-posn-xy (event-start event) ladybird--buttons)))
    (cond
     (xy (ladybird--send-mouse
          "move" xy
          `(buttons . ,(vconcat ladybird--buttons))
          `(modifiers . ,(ladybird-keys-modifiers (event-modifiers event)))))
     (ladybird--inside (ladybird--send-mouse "leave" nil)))))

(defun ladybird--flush-move (buffer)
  "Send the mouse movement held back in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ladybird--move-timer nil)
      (when ladybird--pending-move
        (ladybird--send-move ladybird--pending-move)))))

(defun ladybird-mouse-move (event)
  "Send the mouse movement EVENT to the page.
Movements closer together than `ladybird-hover-interval' are held back;
the last one is always sent."
  (interactive "e")
  (let ((buffer (or (seq-find (lambda (buffer)
                                (buffer-local-value 'ladybird--buttons buffer))
                              (ladybird--buffers))
                    (ladybird--event-buffer (event-start event)))))
    (dolist (other (ladybird--buffers))
      (unless (eq other buffer)
        (with-current-buffer other
          (when (and ladybird--inside (not ladybird--buttons))
            (ladybird--send-mouse "leave" nil)))))
    (when buffer
      (with-current-buffer buffer
        (let ((wait (- (+ ladybird--last-move ladybird-hover-interval)
                       (float-time))))
          (if (<= wait 0)
              (ladybird--send-move event)
            (setq ladybird--pending-move event)
            (unless (timerp ladybird--move-timer)
              (setq ladybird--move-timer
                    (run-at-time wait nil #'ladybird--flush-move buffer)))))))))

(defun ladybird--canvas-center ()
  "Return the middle of the current buffer's canvas, (X . Y)."
  (if ladybird--canvas-size
      (cons (/ (car ladybird--canvas-size) 2) (/ (cdr ladybird--canvas-size) 2))
    (cons 0 0)))

(defun ladybird--send-wheel (xy dx dy modifiers &optional precise)
  "Scroll the page at XY by DX and DY Emacs pixels.
Positive DY scrolls the content down, positive DX to the right.
MODIFIERS is the modifier bitmask; PRECISE marks pixel deltas of a
touchpad."
  (let ((inside ladybird--inside))
    (ladybird--send-mouse "wheel" xy
                        `(dx . ,(round (* dx ladybird--dpr)))
                        `(dy . ,(round (* dy ladybird--dpr)))
                        `(modifiers . ,modifiers)
                        `(precise . ,(ladybird--bool precise)))
    (setq ladybird--inside inside)))

(defun ladybird-wheel (event)
  "Send the wheel EVENT to the page."
  (interactive "e")
  (when-let* ((posn (event-start event))
              (buffer (ladybird--event-buffer posn)))
    (with-current-buffer buffer
      (let ((delta (ladybird-keys-wheel-delta
                    event (with-selected-window (posn-window posn)
                            (default-line-height)))))
        (ladybird--send-wheel (or (ladybird--mouse-posn-xy posn)
                                (ladybird--canvas-center))
                            (car delta) (cdr delta)
                            (ladybird-keys-modifiers (event-modifiers event))
                            (consp (nth 4 event)))))))

(defun ladybird--scroll (dx dy)
  "Scroll the page by DX and DY Emacs pixels at the canvas's middle."
  (ladybird--send-wheel (ladybird--canvas-center) dx dy 0))

(defun ladybird--scroll-step ()
  "Return the pixels a line scroll command moves."
  (or ladybird-scroll-step (* 3 (frame-char-height))))

(defun ladybird--scroll-page ()
  "Return the pixels a page scroll command moves."
  (max 1 (- (window-body-height nil t) (frame-char-height))))

(defun ladybird-scroll-down-line (&optional n)
  "Scroll the page's content down by N steps of `ladybird-scroll-step'."
  (interactive "p")
  (ladybird--scroll 0 (* (or n 1) (ladybird--scroll-step))))

(defun ladybird-scroll-up-line (&optional n)
  "Scroll the page's content up by N steps of `ladybird-scroll-step'."
  (interactive "p")
  (ladybird--scroll 0 (- (* (or n 1) (ladybird--scroll-step)))))

(defun ladybird-scroll-right (&optional n)
  "Scroll the page's content right by N steps of `ladybird-scroll-step'."
  (interactive "p")
  (ladybird--scroll (* (or n 1) (ladybird--scroll-step)) 0))

(defun ladybird-scroll-left (&optional n)
  "Scroll the page's content left by N steps of `ladybird-scroll-step'."
  (interactive "p")
  (ladybird--scroll (- (* (or n 1) (ladybird--scroll-step))) 0))

(defun ladybird-scroll-down-page ()
  "Scroll the page's content down by nearly a window height."
  (interactive)
  (ladybird--scroll 0 (ladybird--scroll-page)))

(defun ladybird-scroll-up-page ()
  "Scroll the page's content up by nearly a window height."
  (interactive)
  (ladybird--scroll 0 (- (ladybird--scroll-page))))

(defun ladybird-scroll-top ()
  "Scroll to the top of the page."
  (interactive)
  (ladybird--scroll 0 -1000000))

(defun ladybird-scroll-bottom ()
  "Scroll to the bottom of the page."
  (interactive)
  (ladybird--scroll 0 1000000))


;;; Keys

(defconst ladybird--modifier-prefixes
  (let ((prefixes '("")))
    (dolist (modifier '("s-" "S-" "M-" "C-"))
      (setq prefixes (append prefixes
                             (mapcar (lambda (p) (concat modifier p)) prefixes))))
    prefixes)
  "Every combination of the C-, M-, S- and s- event prefixes.")

(defconst ladybird--insert-function-keys
  '(return tab backspace delete escape insert left right up down home end
    prior next f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
    kp-0 kp-1 kp-2 kp-3 kp-4 kp-5 kp-6 kp-7 kp-8 kp-9 kp-add kp-subtract
    kp-multiply kp-divide kp-decimal kp-enter kp-equal kp-space kp-tab
    kp-left kp-right kp-up kp-down kp-home kp-end kp-prior kp-next
    kp-insert kp-delete)
  "Function keys `ladybird-insert-mode' sends to the page, with any modifiers.")

(defvar ladybird--input-method-events nil
  "The events an input method made of a key.")

(defun ladybird--read-input-method ()
  "Let the input method translate the next key, in the minibuffer."
  (interactive)
  (let ((key (pop unread-command-events)))
    (setq ladybird--input-method-events (funcall input-method-function key))
    (exit-minibuffer)))

(defun ladybird--input-method-events (event)
  "Return the events the current input method makes of EVENT.
An input method works in a buffer it can insert into, so it runs in
the minibuffer."
  (if (and current-input-method input-method-function (characterp event))
      (let ((ladybird--input-method-events nil)
            (minibuffer-local-map (make-keymap)))
        (define-key minibuffer-local-map [ladybird-input-method]
                    #'ladybird--read-input-method)
        (push event unread-command-events)
        (push 'ladybird-input-method unread-command-events)
        (read-from-minibuffer "" nil nil nil nil nil t)
        ladybird--input-method-events)
    (list event)))

(defun ladybird--send-key (spec)
  "Send SPEC, a value of `ladybird-keys-event', to the page.
A key is pressed and released at once."
  (pcase spec
    (`(text ,text) (ladybird--send-view "text" `(text . ,text)))
    (`(,key ,code-point ,modifiers)
     (ladybird--send-view "key" '(kind . "down") `(key . ,key)
                        `(code_point . ,code-point)
                        `(modifiers . ,modifiers) '(repeat . :false))
     (ladybird--send-view "key" '(kind . "up") `(key . ,key)
                        `(code_point . ,code-point)
                        `(modifiers . ,modifiers)))))

(defun ladybird-insert-key ()
  "Send the key that invoked this command to the page.
With an input method the characters it produces are sent."
  (interactive)
  (setq ladybird--last-buffer (current-buffer))
  (let* ((keys (this-command-keys-vector))
         ;; In a terminal M-x arrives as ESC x.
         (meta (and (> (length keys) 1) (eq (aref keys 0) ?\e))))
    (dolist (event (ladybird--input-method-events last-command-event))
      (when-let* ((spec (ladybird-keys-event event meta)))
        (ladybird--send-key spec)))))

(defun ladybird--platform ()
  "Return the platform of the current buffer's server: `macos' or `other'."
  (if (equal (alist-get 'platform
                        (alist-get 'host (and ladybird--conn
                                              (ladybird--conn-server-info
                                               ladybird--conn))))
             "macos")
      'macos
    'other))

(defun ladybird-insert-edit-key ()
  "Do in the page's text field what the invoking key does in Emacs.
The key is translated for the server's platform by
`ladybird-keys-editing'; a key that has no translation is sent as it is."
  (interactive)
  (setq ladybird--last-buffer (current-buffer))
  (let* ((keys (this-command-keys-vector))
         (event last-command-event)
         ;; In a terminal M-x arrives as ESC x.
         (event (if (and (> (length keys) 1) (eq (aref keys 0) ?\e)
                         (integerp event))
                    (event-convert-list (list 'meta event))
                  event))
         (actions (ladybird-keys-editing event (ladybird--platform))))
    (if (null actions)
        (ladybird-insert-key)
      (dolist (action actions)
        (pcase action
          (`(edit ,op) (ladybird--send-view "edit" `(op . ,op)))
          (_ (ladybird--send-key action)))))))

(defun ladybird-self-insert-hint ()
  "Say how to type into the page."
  (interactive)
  (user-error "Press i to type into the page"))

(defun ladybird--paste (text)
  "Paste the string TEXT into the page."
  (ladybird--send-view "paste" `(text . ,(substring-no-properties text))))

(defun ladybird-yank ()
  "Paste the latest kill into the page."
  (interactive)
  (ladybird--paste (current-kill 0)))

(defun ladybird-xterm-paste (event)
  "Paste the text of the terminal's paste EVENT into the page."
  (interactive "e")
  (when-let* ((text (nth 1 event))
              ((stringp text)))
    (ladybird--paste text)))

(defun ladybird-copy-selection ()
  "Copy the page's selected text to the kill ring."
  (interactive)
  (unless (and ladybird--view (ladybird--ready-p ladybird--conn))
    (user-error "This page is not connected"))
  (ladybird--request ladybird--conn "request_selection" `((view . ,ladybird--view))
                   (lambda (msg)
                     (let ((text (or (alist-get 'text msg) "")))
                       (if (string-empty-p text)
                           (message "The page has no selection")
                         (kill-new text)
                         (message "Copied the page's selection"))))))

(defun ladybird-select-all ()
  "Select everything in the page, or in its focused field."
  (interactive)
  (ladybird--send-view "edit" '(op . "select_all")))

(defcustom ladybird-insert-mode-forward-keys
  '("C-a" "C-e" "C-k" "C-d" "M-b" "M-f" "M-d" "M-DEL" "M-<backspace>"
    "C-<backspace>" "C-z" "C-/" "C-_" "C-?")
  "Emacs editing keys that edit the page's text field in `ladybird-insert-mode'.
Each is a string for `kbd'.  A key is translated to what does the same
in a text field of the server's platform: \\`C-a' and \\`C-e' move to the
start and the end of the line, \\`C-d' deletes a character, \\`C-k' the
rest of the line, \\`M-b' and \\`M-f' move by words, \\`M-d', \\`M-DEL' and
\\`C-<backspace>' delete a word, \\`C-z', \\`C-/' and \\`C-_' undo and
\\`C-?' redoes.  \\`C-b', \\`C-f', \\`C-p', \\`C-n', \\`C-M-_' and \\`C-S-z' can be
added.  A key without a translation is sent as it is.  With nil all of
these keep their Emacs meaning.  Set this with `setopt' or Custom,
which rebuild the mode's keymap."
  :type '(repeat string)
  :group 'ladybird
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'ladybird--rebuild-insert-map)
           (ladybird--rebuild-insert-map))))

(defun ladybird--build-insert-map ()
  "Return the keymap of `ladybird-insert-mode'.
Self-inserting keys and the function keys with any modifiers go to the
page; `ladybird-insert-mode-forward-keys' edit its text field."
  (let ((map (make-sparse-keymap)))
    (substitute-key-definition 'self-insert-command #'ladybird-insert-key
                               map global-map)
    (dolist (key '("RET" "TAB" "DEL" "<backtab>"))
      (define-key map (kbd key) #'ladybird-insert-key))
    (dolist (prefix ladybird--modifier-prefixes)
      (dolist (key ladybird--insert-function-keys)
        (define-key map (vector (intern (concat prefix (symbol-name key))))
                    #'ladybird-insert-key)))
    (dolist (key ladybird-insert-mode-forward-keys)
      (define-key map (kbd key) #'ladybird-insert-edit-key))
    (define-key map (kbd "C-y") #'ladybird-yank)
    (define-key map (kbd "M-w") #'ladybird-copy-selection)
    (define-key map (kbd "C-c C-c") #'ladybird-insert-mode)
    (define-key map [xterm-paste] #'ladybird-xterm-paste)
    map))

(defvar ladybird-insert-mode-map (ladybird--build-insert-map)
  "Keymap of `ladybird-insert-mode'.")

(defun ladybird--rebuild-insert-map ()
  "Build `ladybird-insert-mode-map' again from the options."
  (when (boundp 'ladybird-insert-mode-map)
    (setcdr ladybird-insert-mode-map (cdr (ladybird--build-insert-map)))))

(define-minor-mode ladybird-insert-mode
  "Send typed keys to the page instead of running Emacs commands.
Keys that insert themselves, the function keys and
`ladybird-insert-mode-forward-keys' act on the page; other keys, such as
\\`C-x', \\`C-c', \\`M-x' and \\`C-g', keep their Emacs meaning.
\\<ladybird-insert-mode-map>\\[ladybird-yank] pastes the latest kill, \
\\[ladybird-copy-selection] copies the page's selection
and \\[ladybird-insert-mode] leaves the mode."
  :lighter nil
  :keymap ladybird-insert-mode-map
  :interactive (ladybird-mode)
  (force-mode-line-update))


;;; Major mode

(defvar ladybird-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (prefix ladybird--modifier-prefixes)
      (dolist (button '("1" "2" "3" "8" "9"))
        (dolist (count '("" "double-" "triple-"))
          (define-key map (vector (intern (concat prefix count "down-mouse-"
                                                  button)))
                      #'ladybird-mouse-down)
          (define-key map (vector (intern (concat prefix count "mouse-" button)))
                      #'ladybird-mouse-up)
          (define-key map (vector (intern (concat prefix count "drag-mouse-"
                                                  button)))
                      #'ladybird-mouse-up)))
      (dolist (wheel '("wheel-up" "wheel-down" "wheel-left" "wheel-right"
                       "mouse-4" "mouse-5" "mouse-6" "mouse-7"))
        (define-key map (vector (intern (concat prefix wheel))) #'ladybird-wheel)))
    (define-key map [mouse-movement] #'ladybird-mouse-move)
    (define-key map [remap self-insert-command] #'ladybird-self-insert-hint)
    (define-key map "n" #'ladybird-scroll-down-line)
    (define-key map [down] #'ladybird-scroll-down-line)
    (define-key map "p" #'ladybird-scroll-up-line)
    (define-key map [up] #'ladybird-scroll-up-line)
    (define-key map [left] #'ladybird-scroll-left)
    (define-key map [right] #'ladybird-scroll-right)
    (define-key map " " #'ladybird-scroll-down-page)
    (define-key map [next] #'ladybird-scroll-down-page)
    (define-key map (kbd "DEL") #'ladybird-scroll-up-page)
    (define-key map (kbd "S-SPC") #'ladybird-scroll-up-page)
    (define-key map [prior] #'ladybird-scroll-up-page)
    (define-key map "<" #'ladybird-scroll-top)
    (define-key map ">" #'ladybird-scroll-bottom)
    (define-key map [remap scroll-up-command] #'ladybird-scroll-down-page)
    (define-key map [remap scroll-down-command] #'ladybird-scroll-up-page)
    (define-key map [remap scroll-up-line] #'ladybird-scroll-down-line)
    (define-key map [remap scroll-down-line] #'ladybird-scroll-up-line)
    (define-key map [remap next-line] #'ladybird-scroll-down-line)
    (define-key map [remap previous-line] #'ladybird-scroll-up-line)
    (define-key map [remap forward-char] #'ladybird-scroll-right)
    (define-key map [remap backward-char] #'ladybird-scroll-left)
    (define-key map [remap beginning-of-buffer] #'ladybird-scroll-top)
    (define-key map [remap end-of-buffer] #'ladybird-scroll-bottom)
    (define-key map "i" #'ladybird-insert-mode)
    (define-key map (kbd "RET") #'ladybird-insert-mode)
    (define-key map (kbd "M-w") #'ladybird-copy-selection)
    (define-key map (kbd "C-y") #'ladybird-yank)
    (define-key map [remap mark-whole-buffer] #'ladybird-select-all)
    (define-key map [xterm-paste] #'ladybird-xterm-paste)
    (define-key map "l" #'ladybird-goto-url)
    (define-key map "g" #'ladybird-goto-url)
    (define-key map "r" #'ladybird-reload)
    (define-key map "R" #'ladybird-reload-bypass-cache)
    (define-key map "s" #'ladybird-stop)
    (define-key map "b" #'ladybird-back)
    (define-key map "f" #'ladybird-forward)
    (define-key map "+" #'ladybird-zoom-in)
    (define-key map "=" #'ladybird-zoom-in)
    (define-key map "-" #'ladybird-zoom-out)
    (define-key map "0" #'ladybird-zoom-reset)
    (define-key map "w" #'ladybird-copy-url)
    (define-key map "c" #'ladybird-new-buffer)
    (define-key map "S" #'ladybird-screenshot)
    (define-key map (kbd "C-c C-l") #'ladybird-toggle-console)
    (define-key map (kbd "C-s") #'ladybird-find)
    (define-key map (kbd "C-r") #'ladybird-find-backward)
    (define-key map (kbd "M-s n") #'ladybird-find-next)
    (define-key map (kbd "M-s p") #'ladybird-find-previous)
    (define-key map "q" #'ladybird-quit)
    (define-key map "Q" #'ladybird-close)
    map)
  "Keymap of `ladybird-mode'.")

(define-derived-mode ladybird-mode special-mode "Ladybird"
  "Major mode of buffers that show a page rendered by a Ladybird server.
The mouse and the wheel act on the page.  Keys are Emacs commands;
\\[ladybird-insert-mode] sends typed keys to the page.

\\{ladybird-mode-map}"
  :interactive nil
  (setq-local cursor-type nil
              cursor-in-non-selected-windows nil
              truncate-lines t
              line-spacing nil
              show-trailing-whitespace nil
              scroll-margin 0
              left-fringe-width 0
              right-fringe-width 0
              left-margin-width 0
              right-margin-width 0
              fringe-indicator-alist nil
              mode-line-process '(:eval (ladybird--mode-line-process)))
  (when ladybird-header-line
    (setq-local header-line-format '(:eval (ladybird--header-line))))
  (add-hook 'window-size-change-functions #'ladybird--window-size-changed nil t)
  (add-hook 'window-buffer-change-functions #'ladybird--window-buffer-changed
            nil t)
  (add-hook 'window-selection-change-functions #'ladybird--selection-changed
            nil t)
  (add-hook 'kill-buffer-hook #'ladybird--kill nil t)
  (add-hook 'post-command-hook #'ladybird--after-command)
  (remove-function after-focus-change-function #'ladybird--focus-changed)
  (add-function :after after-focus-change-function #'ladybird--focus-changed))


;;; Commands

(defun ladybird--host (label)
  "Return the host with LABEL, a (LABEL ENDPOINT...) list.
A nil LABEL is the host `ladybird-default-host' says."
  (let ((hosts (ladybird--hosts)))
    (unless hosts
      (user-error "No server: %s is not installed and `ladybird-hosts' is empty"
                  ladybird-program))
    (cond
     ((stringp label)
      (or (assoc label hosts) (user-error "No host %s in `ladybird-hosts'" label)))
     ((stringp ladybird-default-host)
      (or (assoc ladybird-default-host hosts)
          (user-error "No host %s in `ladybird-hosts'" ladybird-default-host)))
     ((and (eq ladybird-default-host 'ask) (cdr hosts))
      (ladybird--read-host hosts))
     (t (car hosts)))))

(defun ladybird--read-host (&optional hosts)
  "Read one of HOSTS, by default all hosts, and return it."
  (let* ((hosts (or hosts (ladybird--hosts)))
         (names (mapcar (lambda (host) (cons (or (car host) "local") host))
                        hosts)))
    (unless hosts
      (user-error "No server: %s is not installed and `ladybird-hosts' is empty"
                  ladybird-program))
    (cdr (assoc (completing-read "Host: " names nil t nil nil (caar names))
                names))))

(defun ladybird--open (url host)
  "Open URL in a new page buffer on HOST and return the buffer.
HOST is a (LABEL ENDPOINT...) list.  On a server that has refused to
open a further page, URL is loaded in the page it has."
  (ladybird--ensure-module)
  (unless (ladybird--module-available-p)
    (user-error "The ladybird-module is not loaded"))
  (let* ((conn (ladybird--find-conn host))
         (limit (and (ladybird--ready-p conn) (ladybird--conn-view-limit conn)))
         (page (and limit
                    (>= (hash-table-count (ladybird--conn-views conn)) limit)
                    (ladybird--page-buffer conn))))
    (if page
        ;; The server has refused a further page before.
        (progn
          (pop-to-buffer-same-window page)
          (setq ladybird--last-buffer page)
          (ladybird--load-in-page conn page url)
          page)
      (let ((buffer (ladybird--make-view-buffer nil nil url host)))
        (pop-to-buffer-same-window buffer)
        (setq ladybird--last-buffer buffer)
        (condition-case err
            (let ((conn (ladybird--connect host
                                           (lambda (conn)
                                             (ladybird--adopt buffer conn)))))
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (unless ladybird--conn
                    (setq ladybird--conn conn)))))
          (error (kill-buffer buffer)
                 (signal (car err) (cdr err))))
        buffer))))

;;;###autoload
(defun ladybird (&optional url host)
  "Open URL in a new page buffer.
URL defaults to `ladybird-home-url'.  HOST is a label of `ladybird-hosts',
or a (LABEL ENDPOINT...) list, and defaults to `ladybird-default-host';
with a prefix argument it is read."
  (interactive
   (list (read-string (format-prompt "URL" ladybird-home-url) nil
                      'ladybird-url-history ladybird-home-url)
         (and current-prefix-arg (ladybird--read-host))))
  (ladybird--open (if (or (null url) (string-empty-p url)) ladybird-home-url url)
                (if (consp host) host (ladybird--host host))))

(defun ladybird-connect (&optional host)
  "Connect to HOST without opening a page.
The pages open on the server get buffers, and the one with the lowest
view id is shown.  HOST is a label of `ladybird-hosts' or a (LABEL
ENDPOINT...) list; interactively it is read."
  (interactive (list (ladybird--read-host)))
  (ladybird--ensure-module)
  (ladybird--connect
   (if (consp host) host (ladybird--host host))
   (lambda (conn)
     (let ((buffers (sort (seq-filter (lambda (buffer)
                                        (buffer-local-value 'ladybird--view buffer))
                                      (ladybird--buffers conn))
                          (lambda (a b)
                            (< (buffer-local-value 'ladybird--view a)
                               (buffer-local-value 'ladybird--view b))))))
       (if (null buffers)
           (message "ladybird: connected to %s, which has no page open"
                    (ladybird--conn-name conn))
         (setq ladybird--last-buffer (car buffers))
         (pop-to-buffer-same-window (car buffers)))))))

(defun ladybird-reconnect ()
  "Dial the connection of the current page buffer again now."
  (interactive nil ladybird-mode)
  (unless ladybird--host
    (user-error "This buffer has no host"))
  (let ((buffer (current-buffer)))
    (if (ladybird--ready-p ladybird--conn)
        (message "ladybird: %s is connected" (ladybird--conn-name ladybird--conn))
      (ladybird--ensure-module)
      (ladybird--connect ladybird--host
                       (lambda (conn) (ladybird--adopt buffer conn))))))

(defun ladybird-quit ()
  "Bury the page buffer; its page stays open."
  (interactive nil ladybird-mode)
  (quit-window))

(defun ladybird-close ()
  "Close the page and kill its buffer."
  (interactive nil ladybird-mode)
  (let ((ladybird-keep-view-on-kill nil))
    (kill-buffer (current-buffer))))


;;; Navigation

(defun ladybird--check-view ()
  "Signal an error unless the current buffer has a connected view."
  (unless (derived-mode-p 'ladybird-mode)
    (user-error "Not a page buffer"))
  (unless (and ladybird--view (ladybird--ready-p ladybird--conn))
    (user-error "This page is not connected")))

(defun ladybird-goto-url (url)
  "Load URL in the current page buffer.
Text that is no URL is searched for or taken as a host name, as the
server sees fit."
  (interactive
   (list (read-string "URL: " (ladybird--url) 'ladybird-url-history))
   ladybird-mode)
  (ladybird--check-view)
  (when (string-empty-p url)
    (user-error "No URL"))
  (ladybird--send-view "load" `(url . ,url)))

(defun ladybird-reload ()
  "Load the page again."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (ladybird--send-view "reload" '(bypass_cache . :false)))

(defun ladybird-reload-bypass-cache ()
  "Load the page again without using the cache."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (ladybird--send-view "reload" '(bypass_cache . t)))

(defun ladybird-stop ()
  "Stop loading the page."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (ladybird--send-view "stop"))

(defun ladybird-back ()
  "Go back in the page's history."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (unless (alist-get 'can_go_back ladybird--state)
    (user-error "No page to go back to"))
  (ladybird--send-view "history" '(delta . -1)))

(defun ladybird-forward ()
  "Go forward in the page's history."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (unless (alist-get 'can_go_forward ladybird--state)
    (user-error "No page to go forward to"))
  (ladybird--send-view "history" '(delta . 1)))

(defun ladybird-zoom-in ()
  "Make the page larger."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (ladybird--send-view "zoom" '(op . "in")))

(defun ladybird-zoom-out ()
  "Make the page smaller."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (ladybird--send-view "zoom" '(op . "out")))

(defun ladybird-zoom-reset ()
  "Show the page at its normal size."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (ladybird--send-view "zoom" '(op . "reset")))

(defun ladybird-copy-url ()
  "Copy the page's URL to the kill ring."
  (interactive nil ladybird-mode)
  (let ((url (or (ladybird--url) (user-error "This page has no URL"))))
    (kill-new url)
    (message "%s" url)))

(defun ladybird-new-buffer ()
  "Open the current page's URL in a new page buffer on the same host."
  (interactive nil ladybird-mode)
  (ladybird--open (or (ladybird--url) ladybird-home-url) ladybird--host))

(defun ladybird-screenshot (path kind)
  "Have the server save a screenshot of the page as the PNG file PATH.
PATH names a file on the server's machine; if it is empty the server
chooses one.  KIND is \"visible\" for what the window shows or \"full\"
for the whole page."
  (interactive
   (progn
     (ladybird--check-view)
     (list (read-string (format "Save screenshot on %s as (empty: its choice): "
                                (ladybird--conn-name ladybird--conn)))
           (cadr (read-multiple-choice "Screenshot of"
                                       '((?v "visible" "What the window shows")
                                         (?f "full" "The whole page"))))))
   ladybird-mode)
  (ladybird--check-view)
  (let ((conn ladybird--conn))
    (ladybird--request conn "screenshot"
                     `((view . ,ladybird--view) (kind . ,kind)
                       ,@(unless (string-empty-p path)
                           `((path . ,(if (ladybird--local-server-p conn)
                                          (expand-file-name path)
                                        path)))))
                     (lambda (msg)
                       (ladybird--recv-screenshot-saved conn msg)))))

(defun ladybird-toggle-console ()
  "Turn the page's console output on or off.
The output is collected in the buffer `ladybird-console-buffer'."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (setq ladybird--console (not ladybird--console))
  (ladybird--send-view "set_console" `(enabled . ,(ladybird--bool ladybird--console)))
  (if (not ladybird--console)
      (message "Console output off")
    (with-current-buffer (get-buffer-create ladybird-console-buffer)
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    (display-buffer ladybird-console-buffer)))

;;;###autoload
(defun ladybird-browse-url (url &optional new-session)
  "Show URL in a page buffer; a function for `browse-url-browser-function'.
The page buffer used last loads URL, unless there is none or
NEW-SESSION is non-nil: then URL opens in a new page buffer on
`ladybird-default-host'."
  (interactive (progn (require 'browse-url)
                      (browse-url-interactive-arg "URL: ")))
  (let ((buffer (and (not new-session)
                     (buffer-live-p ladybird--last-buffer)
                     (with-current-buffer ladybird--last-buffer
                       (and ladybird--view (ladybird--ready-p ladybird--conn)))
                     ladybird--last-buffer)))
    (if (not buffer)
        (ladybird--open url (ladybird--host nil))
      (pop-to-buffer-same-window buffer)
      (ladybird--send-view "load" `(url . ,url))
      buffer)))

;;;###autoload
(function-put 'ladybird-browse-url 'browse-url-browser-kind 'internal)


;;; Find

(defun ladybird--send-find (query)
  "Search the current buffer's page for QUERY; an empty QUERY ends the search.
The search ignores case unless QUERY has an upper case letter."
  (setq ladybird--find-string (and (not (string-empty-p query)) query)
        ladybird--find-result nil)
  (ladybird--send-view "find" `(query . ,query)
                     `(case_sensitive
                       . ,(ladybird--bool
                           (let ((case-fold-search nil))
                             (string-match-p "[[:upper:]]" query))))
                     '(highlight_all . t)))

(defun ladybird--find-step (direction)
  "Move to the next match in DIRECTION, \"next\" or \"previous\"."
  (unless ladybird--find-string
    (user-error "No search in this page"))
  (ladybird--send-view "find_step" `(direction . ,direction)))

(defun ladybird-find-next ()
  "Move to the next match of the last search in the page."
  (interactive nil ladybird-mode)
  (ladybird--find-step "next"))

(defun ladybird-find-previous ()
  "Move to the previous match of the last search in the page."
  (interactive nil ladybird-mode)
  (ladybird--find-step "previous"))

(defun ladybird--find-show (text)
  "Show TEXT, the match count, after the minibuffer's contents."
  (when-let* ((window (active-minibuffer-window)))
    (with-current-buffer (window-buffer window)
      (unless (overlayp ladybird--find-overlay)
        (setq ladybird--find-overlay (make-overlay (point-max) (point-max) nil t t)))
      (move-overlay ladybird--find-overlay (point-max) (point-max) (current-buffer))
      (overlay-put ladybird--find-overlay 'after-string
                   (and text (propertize text 'face 'minibuffer-prompt
                                         'cursor t))))))

(defun ladybird--find-update ()
  "Search the page for what the minibuffer holds, if that changed."
  (when (timerp ladybird--find-timer)
    (cancel-timer ladybird--find-timer))
  (setq ladybird--find-timer nil)
  (when-let* ((window (active-minibuffer-window))
              ((buffer-live-p ladybird--find-buffer)))
    (let ((query (with-current-buffer (window-buffer window)
                   (minibuffer-contents-no-properties))))
      (with-current-buffer ladybird--find-buffer
        (unless (equal query (or ladybird--find-string ""))
          (ladybird--find-show nil)
          (ladybird--send-find query))))))

(defun ladybird--find-changed (&rest _)
  "Search for the minibuffer's contents once typing pauses."
  (when (timerp ladybird--find-timer)
    (cancel-timer ladybird--find-timer))
  (setq ladybird--find-timer (run-at-time 0.1 nil #'ladybird--find-update)))

(defun ladybird--find-step-in-minibuffer (direction)
  "Move to the next match in DIRECTION while the search string is read.
With nothing typed yet the last search string is taken up again."
  (when (and (string-empty-p (minibuffer-contents)) (car ladybird-find-history))
    (insert (car ladybird-find-history)))
  (let ((sent (buffer-local-value 'ladybird--find-string ladybird--find-buffer)))
    (ladybird--find-update)
    (when (equal sent (minibuffer-contents-no-properties))
      (with-current-buffer ladybird--find-buffer
        (ladybird--find-step direction)))))

(defun ladybird-find-minibuffer-next ()
  "Move to the next match of the search string being typed."
  (interactive)
  (ladybird--find-step-in-minibuffer "next"))

(defun ladybird-find-minibuffer-previous ()
  "Move to the previous match of the search string being typed."
  (interactive)
  (ladybird--find-step-in-minibuffer "previous"))

(defvar ladybird--find-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map (kbd "C-s") #'ladybird-find-minibuffer-next)
    (define-key map (kbd "C-r") #'ladybird-find-minibuffer-previous)
    map)
  "Keymap of the minibuffer while `ladybird-find' reads the search string.")

(defun ladybird-find ()
  "Search the page for a string read in the minibuffer.
The page shows the matches while the string is typed.
\\<ladybird--find-minibuffer-map>\\[ladybird-find-minibuffer-next] and \
\\[ladybird-find-minibuffer-previous] move to the next and the previous match, \
\\[exit-minibuffer] ends
with the matches left highlighted and \\[abort-minibuffers] ends the search."
  (interactive nil ladybird-mode)
  (ladybird--check-view)
  (let ((buffer (current-buffer))
        (found nil))
    (setq ladybird--find-buffer buffer)
    (unwind-protect
        (let ((query (minibuffer-with-setup-hook
                         (lambda ()
                           (add-hook 'after-change-functions
                                     #'ladybird--find-changed nil t))
                       (read-from-minibuffer "Find in page: " nil
                                             ladybird--find-minibuffer-map nil
                                             'ladybird-find-history))))
          (setq found t)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (unless (equal query (or ladybird--find-string ""))
                (ladybird--send-find query)))))
      (when (timerp ladybird--find-timer)
        (cancel-timer ladybird--find-timer))
      (when (overlayp ladybird--find-overlay)
        (delete-overlay ladybird--find-overlay))
      (setq ladybird--find-timer nil
            ladybird--find-overlay nil
            ladybird--find-buffer nil)
      (when (and (not found) (buffer-live-p buffer))
        (with-current-buffer buffer
          (ladybird--send-find ""))))))

(defun ladybird-find-backward ()
  "Search the page for a string read in the minibuffer.
This is `ladybird-find'; \\<ladybird--find-minibuffer-map>\
\\[ladybird-find-minibuffer-previous] in the minibuffer moves backward."
  (interactive nil ladybird-mode)
  (ladybird-find))

(ladybird--defhandler "find_result" (conn msg)
  "Show the match count of a search in a page on CONN.
The index of the current match counts from 1 and is 0 without a match;
the total is nil when the server does not know it.  A result for
another string than the one searched for is dropped."
  (ladybird--with-view conn msg
    (when (equal (alist-get 'query msg) ladybird--find-string)
      (let* ((index (or (alist-get 'index msg) 0))
             (total (alist-get 'total msg))
             (text (cond ((= index 0) "no match")
                         (total (format "%d/%d" index total))
                         (t (format "%d/?" index)))))
        (setq ladybird--find-result (cons index total))
        (if (and (eq ladybird--find-buffer buffer) (active-minibuffer-window))
            (ladybird--find-show (format " [%s]" text))
          (when (ladybird--echo-free-p)
            (message "Find %s: %s" ladybird--find-string text)))))))


;;; Page events

(ladybird--defhandler "cursor" (conn msg)
  "Show the pointer shape the page on CONN asks for."
  (ladybird--with-view conn msg
    (setq ladybird--cursor (ladybird-keys-pointer (alist-get 'cursor msg)))
    (let ((inhibit-read-only t))
      (with-silent-modifications
        (put-text-property 1 2 'pointer ladybird--cursor)))))

(defun ladybird--echo-free-p ()
  "Return non-nil when the echo area may be used for a hover message."
  (not (or (active-minibuffer-window) cursor-in-echo-area)))

(defun ladybird--echo-line (text)
  "Return TEXT cut to one line of the echo area.
A longer message would grow the echo area and with it resize the page."
  (truncate-string-to-width
   (string-replace "\n" " " text)
   (max 1 (1- (window-width (minibuffer-window)))) nil nil t))

(ladybird--defhandler "link_hover" (conn msg)
  "Show the URL of the link under the mouse in a page on CONN."
  (ladybird--with-view conn msg
    (when ladybird-show-link-hover
      (let ((url (and-let* ((url (alist-get 'url msg)))
                   (ladybird--echo-line url)))
            (message-log-max nil))
        (cond
         ((not (ladybird--echo-free-p)))
         (url (message "%s" url))
         ((and ladybird--hover-url (equal (current-message) ladybird--hover-url))
          (message nil)))
        (setq ladybird--hover-url url)))))

(ladybird--defhandler "tooltip" (conn msg)
  "Show the tooltip of a page on CONN."
  (ladybird--with-view conn msg
    (let ((text (alist-get 'text msg))
          (message-log-max nil))
      (cond
       ((null text)
        (when (and (bound-and-true-p tooltip-mode) (display-graphic-p))
          (tooltip-hide)))
       ((and (bound-and-true-p tooltip-mode) (display-graphic-p))
        (tooltip-show text))
       ((ladybird--echo-free-p) (message "%s" (ladybird--echo-line text)))))))

(ladybird--defhandler "favicon" (conn msg)
  "Take the icon of a page on CONN."
  (ladybird--with-view conn msg
    (setq ladybird--favicon
          (ignore-errors
            (create-image (base64-decode-string (alist-get 'png msg)) 'png t
                          :height (frame-char-height) :ascent 'center
                          :scale 1)))
    (force-mode-line-update)))

(ladybird--defhandler "console" (conn msg)
  "Append console output of a page on CONN to the console buffer."
  (let ((name (if-let* ((buffer (ladybird--view-buffer conn msg)))
                  (buffer-name buffer)
                (format "view %s" (alist-get 'view msg)))))
    (with-current-buffer (get-buffer-create ladybird-console-buffer)
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (let ((inhibit-read-only t)
            (end (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert (format "%s [%s] %s\n" name (alist-get 'level msg)
                          (alist-get 'text msg)))
          (when (> (forward-line (- ladybird-console-max-lines)) -1)
            (delete-region (point-min) (point))))
        (when end
          (goto-char (point-max)))))))

(ladybird--defhandler "clipboard" (_conn msg)
  "Put text a page copied on the kill ring."
  (when-let* ((text (alist-get 'text msg))
              ((not (string-empty-p text))))
    (kill-new text)
    (message "Copied from the page")))

(ladybird--defhandler "selection" (_conn msg)
  "Put a page's selection nobody waits for on the kill ring."
  (when-let* ((text (alist-get 'text msg))
              ((not (string-empty-p text))))
    (kill-new text)))

(ladybird--defhandler "screenshot_saved" (conn msg)
  "Report where the server on CONN saved a screenshot."
  (message "ladybird: screenshot saved on %s as %s" (ladybird--conn-name conn)
           (alist-get 'path msg)))

(ladybird--defhandler "error" (conn msg)
  "Report a command the server on CONN could not carry out.
An error that names neither a request nor a view, while a buffer waits
for a view, is the answer to the oldest `create_view' of a server that
does not name the request."
  (if (and (ladybird--conn-creating conn) (null (alist-get 'view msg)))
      (ladybird--create-failed conn (ladybird--pop-creating conn)
                               (alist-get 'message msg))
    (message "ladybird: %s: %s" (ladybird--conn-name conn)
             (alist-get 'message msg))))

(ladybird--defhandler "popup_blocked" (conn msg)
  "Remember the window a page on CONN tried to open."
  (ladybird--with-view conn msg
    (setq ladybird--blocked-popup (alist-get 'url msg))
    (message "Popup blocked: %s%s" ladybird--blocked-popup
             (substitute-command-keys
              "  (\\[ladybird-open-blocked-popup] opens it)"))))

(defun ladybird-open-blocked-popup ()
  "Open the window the page last tried to open in a new page buffer."
  (interactive nil ladybird-mode)
  (unless ladybird--blocked-popup
    (user-error "The page tried to open no window"))
  (ladybird--open ladybird--blocked-popup ladybird--host))


;;; Dialogs and pickers

(defun ladybird--prompt-key (conn msg)
  "Return the key of the prompt for the request MSG on CONN."
  (list conn (alist-get 'view msg) (alist-get 'id msg)))

(defun ladybird--answer (conn msg type &rest fields)
  "Answer the request MSG on CONN with a message of TYPE and FIELDS."
  (setq ladybird--prompt-answered t)
  (ladybird--send conn `((type . ,type)
                       (view . ,(alist-get 'view msg))
                       (id . ,(alist-get 'id msg))
                       ,@fields)))

(defun ladybird--page-name (conn msg)
  "Return a name for the page of the request MSG on CONN."
  (let ((origin (alist-get 'origin msg)))
    (cond ((and origin (not (string-empty-p origin))) origin)
          ((ladybird--view-buffer conn msg)
           (buffer-name (ladybird--view-buffer conn msg)))
          (t "The page"))))

(ladybird--defhandler "dialog" (conn msg)
  "Show the alert, confirmation or prompt of a page on CONN."
  (let* ((kind (alist-get 'kind msg))
         (text (or (alist-get 'message msg) ""))
         (page (ladybird--page-name conn msg))
         (close (lambda (accepted &optional input)
                  (apply #'ladybird--answer conn msg "dialog_closed"
                         `(accepted . ,(ladybird--bool accepted))
                         (and input `((text . ,input)))))))
    (if (and (equal kind "alert") (eq ladybird-alert-style 'echo))
        (progn (message "%s: %s" page text)
               (funcall close t))
      (ladybird--later
       (lambda ()
         (pcase kind
           ("alert"
            (read-key (format "%s: %s  (press a key) " page text))
            (message nil)
            (funcall close t))
           ("confirm"
            (funcall close (y-or-n-p (format "%s: %s — OK? " page text))))
           ("beforeunload"
            (funcall close (y-or-n-p (format "%s: leave this page? " page))))
           ("prompt"
            (funcall close t (read-string (format "%s: %s: " page text)
                                          (alist-get 'default msg))))
           (_ (funcall close nil))))
       (lambda () (funcall close nil))
       (ladybird--prompt-key conn msg)))))

(defun ladybird--select-candidates (items)
  "Return an alist of labels and ids of the choosable select ITEMS.
An item's group prefixes its label; equal labels are numbered."
  (let (candidates)
    (seq-doseq (item items)
      (unless (or (alist-get 'separator item) (alist-get 'disabled item))
        (let* ((group (alist-get 'group item))
               (label (concat (and group (not (string-empty-p group))
                                   (concat group " / "))
                              (or (alist-get 'label item) "")))
               (name label)
               (n 1))
          (while (assoc name candidates)
            (setq name (format "%s (%d)" label (cl-incf n))))
          (push (list name (alist-get 'id item) (alist-get 'selected item))
                candidates))))
    (nreverse candidates)))

(ladybird--defhandler "select" (conn msg)
  "Read the choice for a select element of a page on CONN."
  (let ((close (lambda (item)
                 (ladybird--answer conn msg "select_closed"
                                 `(item . ,(or item :null))))))
    (ladybird--later
     (lambda ()
       (let* ((candidates (ladybird--select-candidates (alist-get 'items msg)))
              (default (car (seq-find (lambda (c) (nth 2 c)) candidates)))
              (completion-ignore-case t)
              (choice (completing-read
                       (format-prompt "Select" default)
                       (lambda (string predicate action)
                         (if (eq action 'metadata)
                             '(metadata (display-sort-function . identity)
                                        (cycle-sort-function . identity))
                           (complete-with-action action candidates string
                                                 predicate)))
                       nil t nil nil default)))
         (funcall close (cadr (assoc choice candidates)))))
     (lambda () (funcall close nil))
     (ladybird--prompt-key conn msg))))

(defun ladybird--local-server-p (conn)
  "Return non-nil if CONN's server sees this machine's files.
A server started here does.  A Unix socket can be one forwarded from
another machine: its server is local if the endpoint does not rule out
shared memory, no segment has failed to map and the server names this
machine as its host."
  (let* ((endpoint (or (ladybird--conn-endpoint conn) (ladybird--conn-dialed conn)))
         (host (alist-get 'hostname
                          (alist-get 'host (ladybird--conn-server-info conn)))))
    (pcase (plist-get endpoint :kind)
      ('local t)
      ('unix (and (ladybird--shm-p endpoint)
                  (not (ladybird--conn-shm-failed conn))
                  (stringp host)
                  (string= (downcase host) (downcase (system-name))))))))

(defun ladybird--local-directory (directory)
  "Return DIRECTORY if it is an absolute name of a local directory, else nil.
DIRECTORY is a hint of the server."
  (and (stringp directory)
       (file-name-absolute-p directory)
       (not (file-remote-p directory))
       directory))

(ladybird--defhandler "file_picker" (conn msg)
  "Read the files for a file input of a page on CONN.
The paths name files on the server's machine."
  (let ((close (lambda (paths)
                 (ladybird--answer conn msg "file_picker_closed"
                                 `(paths . ,(vconcat paths)))))
        (multiple (alist-get 'multiple msg))
        (directory (alist-get 'directory msg)))
    (ladybird--later
     (lambda ()
       (funcall
        close
        (if (ladybird--local-server-p conn)
            (let (paths)
              (while (progn
                       (push (expand-file-name
                              (read-file-name
                               (if multiple
                                   (format "File %d for the page: "
                                           (1+ (length paths)))
                                 "File for the page: ")
                               (ladybird--local-directory directory) nil t))
                             paths)
                       (and multiple (y-or-n-p "Add another file? "))))
              (nreverse paths))
          (let ((path (read-string
                       (format "Path on %s, the server's machine: "
                               (ladybird--conn-name conn))
                       directory)))
            (and (not (string-empty-p path)) (list path))))))
     (lambda () (funcall close nil))
     (ladybird--prompt-key conn msg))))

(defun ladybird--color-hex (color)
  "Return the colour named COLOR as \"#rrggbb\", or nil."
  (when-let* ((values (or (color-values-from-color-spec color)
                          (ignore-errors (color-values color)))))
    (apply #'format "#%02x%02x%02x" (mapcar (lambda (v) (ash v -8)) values))))

(ladybird--defhandler "color_picker" (conn msg)
  "Read the colour for a colour input of a page on CONN."
  (let ((close (lambda (color)
                 (ladybird--answer conn msg "color_picker_closed"
                                 `(color . ,(or color :null))))))
    (ladybird--later
     (lambda ()
       (funcall close (ladybird--color-hex
                       (read-color (format-prompt "Color"
                                                  (alist-get 'current msg))))))
     (lambda () (funcall close nil))
     (ladybird--prompt-key conn msg))))

(ladybird--defhandler "date_picker" (conn msg)
  "Read the value for a date or time input of a page on CONN."
  (let ((close (lambda (value)
                 (ladybird--answer conn msg "date_picker_closed"
                                 `(value . ,(or value :null))))))
    (ladybird--later
     (lambda ()
       (let ((value (read-string (format "%s: " (or (alist-get 'input_type msg)
                                                    "date"))
                                 (alist-get 'value msg))))
         (funcall close (and (not (string-empty-p value)) value))))
     (lambda () (funcall close nil))
     (ladybird--prompt-key conn msg))))

(defun ladybird--read-answer (prompt choices)
  "Read one of the strings CHOICES in the minibuffer and return it.
PROMPT asks the question.  Return nil if nothing was chosen.  Keys
typed before the prompt opened are discarded, and a choice has to be
typed or completed and confirmed: what PROMPT asks is the server's
question, and no stray key answers it."
  (discard-input)
  (let ((answer (completing-read
                 (format "%s (%s) " prompt (string-join choices ", "))
                 choices nil t)))
    (car (member answer choices))))

(ladybird--defhandler "permission" (conn msg)
  "Ask whether a page on CONN may use a device or feature."
  (let ((close (lambda (outcome)
                 (ladybird--answer conn msg "permission_closed"
                                 `(outcome . ,outcome)))))
    (ladybird--later
     (lambda ()
       (funcall
        close
        (pcase (ladybird--read-answer
                (format "Allow %s for %s?" (alist-get 'name msg)
                        (ladybird--page-name conn msg))
                '("allow once" "allow always" "deny"))
          ("allow once" "allow_once")
          ("allow always" "allow_always")
          ("deny" "deny")
          (_ "dismiss"))))
     (lambda () (funcall close "dismiss"))
     (ladybird--prompt-key conn msg))))

(ladybird--defhandler "permission_cancelled" (conn msg)
  "Close the prompt for a permission a page on CONN no longer wants."
  (ladybird--cancel-prompt-later (ladybird--prompt-key conn msg)))

(ladybird--defhandler "request_cancelled" (conn msg)
  "Close the prompt for a request the server on CONN withdrew.
No answer is sent; a request without a prompt is ignored."
  (ladybird--cancel-prompt-later (ladybird--prompt-key conn msg)))

(defun ladybird--open-here-p (url)
  "Return non-nil if URL may be handed to this machine's browser.
A page names the URL; only web and mail addresses are passed on."
  (let ((case-fold-search t))
    (and (stringp url)
         (string-match-p "\\`\\(?:https?\\|mailto\\):" url))))

(ladybird--defhandler "external_url" (conn msg)
  "Ask what to do with a URL a page on CONN hands to another program."
  (let ((close (lambda (open)
                 (ladybird--answer conn msg "external_url_closed"
                                 `(open . ,(ladybird--bool open)))))
        (url (alist-get 'url msg)))
    (ladybird--later
     (lambda ()
       (pcase (ladybird--read-answer
               (format "Open %s with %s?"
                       (ladybird--echo-line (or url ""))
                       (or (alist-get 'application msg) "its program"))
               `("open on server"
                 ,@(and (ladybird--open-here-p url) '("open here"))
                 "deny"))
         ("open on server" (funcall close t))
         ("open here"
          (funcall close nil)
          (if (ladybird--open-here-p url)
              (funcall (or (bound-and-true-p
                            browse-url-secondary-browser-function)
                           #'browse-url)
                       url)
            (message "ladybird: not opening %s here" url)))
         (_ (funcall close nil))))
     (lambda () (funcall close nil))
     (ladybird--prompt-key conn msg))))

(defun ladybird--context-menu-items (msg)
  "Return the context menu for MSG as a list of (LABEL . FUNCTION).
The functions run in the page's buffer."
  (let ((link (alist-get 'link_url msg))
        (image (alist-get 'image_url msg))
        (media (alist-get 'media_url msg))
        (selection (alist-get 'selection msg))
        (load (lambda (url) (lambda () (ladybird--send-view "load" `(url . ,url)))))
        (copy (lambda (text) (lambda () (kill-new text) (message "Copied %s" text))))
        (edit (lambda (op) (lambda () (ladybird--send-view "edit" `(op . ,op))))))
    (append
     (when link
       `(("Open Link" . ,(funcall load link))
         ("Open Link in New Buffer" . ,(lambda () (ladybird--open link ladybird--host)))
         ("Copy Link" . ,(funcall copy link))))
     (when image
       `(("Open Image" . ,(funcall load image))
         ("Copy Image URL" . ,(funcall copy image))))
     (when media
       `(("Copy Media URL" . ,(funcall copy media))))
     (when (and selection (not (string-empty-p selection)))
       `(("Copy" . ,(funcall copy selection))
         ("Search Selection" . ,(funcall load selection))))
     (when (alist-get 'editable msg)
       `(("Paste" . ladybird-yank)
         ("Cut" . ,(funcall edit "cut"))
         ("Select All" . ,(funcall edit "select_all"))
         ("Undo" . ,(funcall edit "undo"))
         ("Redo" . ,(funcall edit "redo"))))
     `(("Back" . ,(lambda () (ladybird--send-view "history" '(delta . -1))))
       ("Forward" . ,(lambda () (ladybird--send-view "history" '(delta . 1))))
       ("Reload" . ,(lambda () (ladybird--send-view "reload"
                                                  '(bypass_cache . :false))))))))

(ladybird--defhandler "context_menu" (conn msg)
  "Pop up the context menu of a page on CONN."
  (when-let* ((buffer (ladybird--view-buffer conn msg)))
    (ladybird--later
     (lambda ()
       (let* ((items (ladybird--context-menu-items msg))
              (choice (x-popup-menu
                       t (list "Page"
                               (cons "" (seq-map-indexed
                                         (lambda (item index)
                                           (cons (car item) index))
                                         items))))))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             ;; The menu can have taken the release of the button.
             (when (member "right" ladybird--buttons)
               (setq ladybird--buttons (remove "right" ladybird--buttons))
               (ladybird--send-mouse "up" ladybird--last-xy
                                     '(button . "right")
                                     `(buttons . ,(vconcat ladybird--buttons))
                                     '(modifiers . 0)
                                     `(clicks . ,ladybird--clicks)))
             (when (integerp choice)
               (funcall (cdr (nth choice items)))))))))))

(provide 'ladybird)

;;; ladybird.el ends here
