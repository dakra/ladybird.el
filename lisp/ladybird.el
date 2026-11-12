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
;; A page buffer starts in `ladybird-command-mode', where single keys
;; are commands: n and p scroll, g opens a URL, b and f go back and
;; forward, o activates a link, button or field by the label the page
;; puts on it.  i, or a text field of the page getting the focus, sends
;; the keys to the page, the Emacs editing and motion keys translated
;; to what does the same in a browser, while C-x, C-h, M-x and the like
;; keep their Emacs meaning; C-c C-e returns to command mode.  The
;; package's commands are also under C-c: C-c C-l opens a URL, C-c C-o
;; follows a label, C-c C-b and C-c C-f go back and forward.  The mouse
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

(defcustom ladybird-new-page-display 'selected-window
  "Where a page that a command opens in a new buffer appears.
`selected-window' shows it in the selected window, `other-window' in
another window, and `background' nowhere: the buffer is made and its
page loads.  The buffer goes through `display-buffer', so a rule of
`display-buffer-alist' that matches it comes first.

A page that a page opens appears nowhere unless such a rule shows it:
it goes through `display-buffer' with the category `ladybird-popup',
which the condition `(category . ladybird-popup)' matches."
  :type '(choice (const :tag "In the selected window" selected-window)
                 (const :tag "In another window" other-window)
                 (const :tag "Not shown" background))
  :group 'ladybird)

(defcustom ladybird-keep-view-on-kill nil
  "Whether killing a page buffer leaves its page open on the server.
A page left open shows up again with the next connection to a server
that outlives its clients."
  :type 'boolean
  :group 'ladybird)

(defcustom ladybird-hint-alphabet "asdfghjkl"
  "Characters the labels of `ladybird-follow-hint' are made of.
These are 2 to 36 different characters, each a lower case letter from
a to z or a digit."
  :type 'string
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
(defvar-local ladybird--field-focused nil
  "Whether a text field of the page has the focus, as `ime' last said.
nil when none has it, `user' when the page had user activation when
the field got the focus or since, `page' when not.")
(defvar-local ladybird--command-mode-was nil
  "The value `ladybird-command-mode' had before it was last called.")
(defvar-local ladybird--field-page-mode nil
  "How `ladybird-command-mode' relates to the focused text field.
t while the mode is off for the focused field, by the field or by hand;
`hand' when it was switched on by hand while a field had the focus; nil
otherwise.")
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
(defvar-local ladybird--opener nil "Id of the view whose page opened this one.")
(defvar-local ladybird--console nil
  "Non-nil while the page sends its console output.")
(defvar-local ladybird--find-string nil "The string last searched for in the page.")
(defvar-local ladybird--find-result nil
  "The (INDEX . TOTAL) of the last search result, or nil.
INDEX counts from 1 and is 0 without a match; TOTAL can be nil.")
(defvar-local ladybird--dropped-frames 0
  "Number of frames of this view the module could not use.")
(defvar-local ladybird--frame-count 0
  "Number of frames of this view the module painted or kept.")
(defvar-local ladybird--full-frame-count 0
  "Number of those frames that repainted the whole view.")

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

(cl-defstruct (ladybird--hint (:constructor ladybird--make-hint) (:copier nil))
  "A hint session: the page labels what can be activated, the user types a label."
  conn view buffer id alphabet
  new-buffer                     ; non-nil: a chosen link opens in a new buffer
  (waiting t)                    ; non-nil until the labels are taken up
  items                          ; the items of `hints_list'
  truncated                      ; non-nil when the page has more than it labelled
  (prefix ""))                   ; what has been typed of a label

(defvar ladybird--hint nil
  "The hint session of `ladybird-follow-hint' in progress, or nil.")
(defvar ladybird--hint-shown nil "The hint prompt last shown in the echo area.")

(defvar ladybird-command-mode)


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

(defun ladybird--clean (text)
  "Return TEXT, a string from a page, fit to show in Emacs.
Line breaks and tabs become spaces, other control characters and the
characters that override the direction of bidirectional text go: a
page could make the text that follows read backwards with them."
  (let ((text (replace-regexp-in-string "[\n\t\r]" " " (or text "") t t)))
    (replace-regexp-in-string
     "[\0-\37\177\x80-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"
     "" text t t)))

(defun ladybird--buffer-name ()
  "Return the current buffer's name as `ladybird-buffer-name-format' says."
  (let ((title (ladybird--clean (alist-get 'title ladybird--state)))
        (url (ladybird--clean (or (ladybird--url) ""))))
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
  (pcase-let ((`(frame ,view ,_seq ,width ,height ,dpr ,_ ,_ ,_ ,_ ,full ,status)
               event))
    (let ((buffer (and view (gethash view (ladybird--conn-views conn)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (if (memq status '(stored size-mismatch canvas-error painted))
              (progn (cl-incf ladybird--frame-count)
                     (when full
                       (cl-incf ladybird--full-frame-count)))
            (cl-incf ladybird--dropped-frames))
          (when (memq status '(stored size-mismatch canvas-error))
            (ladybird--replace-canvas width height dpr)))))))

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
      (remove-hook 'post-command-hook #'ladybird--after-command)
      (remove-hook 'window-buffer-change-functions #'ladybird--window-buffer-changed)
      (remove-hook 'delete-frame-functions #'ladybird--schedule-update))))

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

(defvar ladybird--special-events nil
  "The `special-event-map' bindings ladybird replaced, an alist.")

(defun ladybird--frame-visibility-changed (event)
  "Follow a frame iconified or made visible, then run what EVENT ran before."
  (interactive "e")
  (when (ladybird--buffers)
    (ladybird--schedule-update))
  (when-let* ((previous (cdr (assq (car-safe event) ladybird--special-events)))
              ((commandp previous)))
    (funcall-interactively previous event)))

(defun ladybird--follow-frame-visibility ()
  "Make the special events of frame visibility schedule an update.
A window system sends `iconify-frame' and `make-frame-visible'."
  (dolist (type '(iconify-frame make-frame-visible))
    (unless (assq type ladybird--special-events)
      (push (cons type (lookup-key special-event-map (vector type)))
            ladybird--special-events)
      (define-key special-event-map (vector type)
                  #'ladybird--frame-visibility-changed))))

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

(defun ladybird--max-views (conn)
  "Return the number of views CONN's server can hold at a time.
It is the welcome's `max_views'; a server that does not send it holds one."
  (let ((max (alist-get 'max_views (ladybird--conn-server-info conn))))
    (if (and (integerp max) (> max 0)) max 1)))

(defun ladybird--view-count (conn)
  "Return the number of views CONN's server holds or is making for it.
These are the views of CONN's buffers, those of killed buffers left on
the server and those asked for and not yet made."
  (+ (hash-table-count (ladybird--conn-views conn))
     (length (ladybird--conn-kept conn))
     (length (ladybird--conn-creating conn))))

(defun ladybird--page-buffer (conn)
  "Return a buffer of CONN that shows a page: the one used last, or any."
  (let ((buffers (seq-filter (lambda (buffer)
                               (buffer-local-value 'ladybird--view buffer))
                             (ladybird--buffers conn))))
    (if (memq ladybird--last-buffer buffers)
        ladybird--last-buffer
      (car buffers))))

(defun ladybird--load-in-page (conn buffer url)
  "Load URL in BUFFER, the page of CONN's server, which holds only one."
  (with-current-buffer buffer
    (ladybird--send-view "load" `(url . ,url)))
  (message "ladybird: %s holds one page; %s loaded in %s"
           (ladybird--conn-name conn) url (buffer-name buffer)))

(defun ladybird--full-message (conn)
  "Return the message that CONN's server holds all the pages it can."
  (let ((max (ladybird--max-views conn))
        (kept (length (ladybird--conn-kept conn))))
    (format "ladybird: %s has %d page%s open, the most it holds%s; close one first"
            (ladybird--conn-name conn) max (if (= max 1) "" "s")
            (if (> kept 0)
                (substitute-command-keys
                 (format ", %d of them left by killed buffers, which \\<ladybird-mode-map>\\[ladybird-switch-to-page] or M-x ladybird-connect shows again"
                         kept))
              ""))))

(defun ladybird--restore-kept (conn &optional view)
  "Give the views CONN's server keeps for killed buffers a buffer again.
With VIEW only that view.  A buffer gets the view's last state; its
frame comes when a window shows it.  Return the new buffers."
  (let (buffers)
    (dolist (entry (reverse (ladybird--conn-kept conn)))
      (when (or (null view) (eql view (car entry)))
        (setf (ladybird--conn-kept conn) (delq entry (ladybird--conn-kept conn)))
        (let ((buffer (ladybird--make-view-buffer
                       conn (car entry) (alist-get 'url (cdr entry)))))
          (with-current-buffer buffer
            (when (cdr entry)
              (ladybird--apply-state (cdr entry))))
          (push buffer buffers))))
    (when buffers
      (ladybird--schedule-update))
    (nreverse buffers)))

(defun ladybird--create-failed (conn buffer reason)
  "Give up on BUFFER, for which CONN's server opened no view.
REASON is the server's message.  On a server that holds one page and
has it, the URL is loaded in that page, shown where BUFFER was."
  (let* ((page (and (= (ladybird--max-views conn) 1)
                    (ladybird--page-buffer conn)))
         (url (and (buffer-live-p buffer)
                   (buffer-local-value 'ladybird--url-at-create buffer))))
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

(defun ladybird--forget-view (&optional killing)
  "Detach the current buffer from its view without closing the view.
The module drops the view's frame, canvas and shared memory.  A hint
session of the buffer ends.  Unless KILLING, a focused text field of the
view is reported gone to `ladybird-field-focus-functions'."
  (when (and ladybird--hint (eq (ladybird--hint-buffer ladybird--hint)
                                (current-buffer)))
    (ladybird--hint-stop))
  (when (and ladybird--conn ladybird--view)
    (remhash ladybird--view (ladybird--conn-views ladybird--conn))
    (when-let* ((decoder (ladybird--conn-decoder ladybird--conn)))
      (ignore-errors (ladybird-module-forget-view decoder ladybird--view))))
  (setq ladybird--view nil
        ladybird--opener nil
        ladybird--creating nil
        ladybird--requested-size nil
        ladybird--visible 'unknown
        ladybird--focused 'unknown)
  (if killing
      (setq ladybird--field-focused nil)
    (ladybird--set-field-focus nil nil)))

(defun ladybird--adopt (buffer conn)
  "Make BUFFER a page buffer of the ready CONN and give it a view."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless (eq ladybird--conn conn)
        (ladybird--forget-view))
      (when (buffer-live-p buffer)
        (setq ladybird--conn conn)
        (ladybird--create-view)
        (force-mode-line-update)))))

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
          (ladybird--conn-closing conn) nil
          (ladybird--conn-kept conn) nil)
    ;; A function of `ladybird-field-focus-functions' may kill buffers.
    (dolist (buffer (ladybird--buffers conn))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq ladybird--creating nil
                ladybird--requested-size nil
                ladybird--visible 'unknown
                ladybird--focused 'unknown
                ladybird--buttons nil
                ladybird--inside nil)
          (unless (and ladybird--view (not changed) (memq ladybird--view listed))
            (ladybird--forget-view)
            (when (buffer-live-p buffer)
              (ladybird--create-view))))))
    (dolist (view views)
      (let ((id (alist-get 'view view)))
        (unless (buffer-live-p (gethash id (ladybird--conn-views conn)))
          (cl-incf new)
          (with-current-buffer (ladybird--make-view-buffer
                                conn id (alist-get 'url view))
            (ladybird--apply-state view)))))
    (when (> new 0)
      (message "ladybird: %d page%s found on %s" new (if (= new 1) "" "s")
               (ladybird--conn-name conn)))
    ;; From a timer, so that what waits for the connection shows its
    ;; page first and every view is told its visibility once.
    (ladybird--schedule-update)
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
  "Show CONN's new state in its page buffers.
A hint session on CONN ends when CONN is no longer ready."
  (when (and ladybird--hint (eq (ladybird--hint-conn ladybird--hint) conn)
             (not (ladybird--ready-p conn)))
    (ladybird--hint-stop))
  (dolist (buffer (ladybird--buffers conn))
    (with-current-buffer buffer
      (force-mode-line-update))))

(setq ladybird--frame-function #'ladybird--on-frame
      ladybird--welcome-function #'ladybird--on-welcome
      ladybird--change-function #'ladybird--on-conn-change
      ladybird--viewport-function #'ladybird--hello-viewport)

(ladybird--defhandler "view_created" (conn msg)
  "Give the buffer that has waited longest the view the server created.
This handles a `view_created' that does not name its request.  One
that names an `opener' was made by a page and answers no request."
  (if (alist-get 'opener msg)
      (ladybird--page-opened conn msg)
    (ladybird--view-created conn (ladybird--pop-creating conn) msg)))

(defun ladybird--page-opened (conn msg)
  "Make a buffer for the view that a page on CONN opened.
MSG is the `view_created' that announces it.  The buffer goes through
`display-buffer' with the category `ladybird-popup' and appears in no
window unless a rule of `display-buffer-alist' shows it; no window is
selected.  The server learns at once whether it is shown, so a page in
the background does not render."
  (let* ((opener (ladybird--view-buffer conn `((view . ,(alist-get 'opener msg)))))
         (buffer (ladybird--make-view-buffer conn (alist-get 'view msg)
                                             (alist-get 'url msg))))
    (with-current-buffer buffer
      (setq ladybird--opener (alist-get 'opener msg))
      (ladybird--apply-state msg))
    (let (shown)
      (unwind-protect
          (setq shown (display-buffer buffer '(display-buffer-no-window
                                               (allow-no-window . t)
                                               (category . ladybird-popup))))
        (ladybird--sync-viewport buffer)
        (ladybird--sync-focus buffer))
      ;; The view starts at about:blank when it does not know its URL yet.
      (message "ladybird: %s opened %s%s"
               (if opener (buffer-name opener) "a page")
               (if (member (alist-get 'url msg) '(nil "" "about:blank"))
                   "a page"
                 (buffer-name buffer))
               (if shown
                   ""
                 (substitute-command-keys
                  " in the background; \\<ladybird-mode-map>\\[ladybird-switch-to-page] \
switches to it"))))))

(ladybird--defhandler "state" (conn msg)
  "Record the state of a view on CONN.
For a view left on the server by a killed buffer it is kept for the
buffer it gets again."
  (if-let* ((kept (assq (alist-get 'view msg) (ladybird--conn-kept conn))))
      (setcdr kept msg)
    (ladybird--with-view conn msg
      (ladybird--apply-state msg))))

(ladybird--defhandler "view_closed" (conn msg)
  "Kill the buffer of a view the server closed on CONN.
Each window that showed it is quit with `quit-restore-window': a window
made for the page is deleted, any other shows the buffer it showed
before.  The selected window stays selected if it is still live.  A
page closed before it had a URL goes without a message.  A view left on
the server by a killed buffer is forgotten."
  (setf (ladybird--conn-kept conn)
        (assq-delete-all (alist-get 'view msg) (ladybird--conn-kept conn)))
  (ladybird--with-view conn msg
    (pcase (alist-get 'reason msg)
      ("client")
      ;; Such as a window whose first navigation was a download, which
      ;; the server reports itself.
      ("closed" (unless (member (ladybird--url) '(nil "" "about:blank"))
                  (message "ladybird: %s was closed by its page" (buffer-name))))
      (reason (message "ladybird: %s closed (%s)" (buffer-name) reason)))
    (ladybird--forget-view t)
    ;; The page closes when it likes: the selection stays where the user
    ;; has it, unless that window goes.
    (save-selected-window
      (dolist (window (get-buffer-window-list buffer nil t))
        (quit-restore-window window)))
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
Its hint session ends.  An error is reported and does not keep the
buffer from being killed."
  (condition-case err
      (progn
        (when (and ladybird--hint (eq (ladybird--hint-buffer ladybird--hint)
                                      (current-buffer)))
          (ladybird--hint-stop t))
        (ladybird--kill-view))
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
        (push (cons view ladybird--state) (ladybird--conn-kept conn))
        (when (ladybird--ready-p conn)
          (ladybird--send-view "set_visibility" '(visible . :false))
          (ladybird--send-view "set_focus" '(focused . :false))))
       ((ladybird--ready-p conn)
        (setq closed (ladybird--send conn `((type . "close_view")
                                            (view . ,view)))))
       ((memq (ladybird--conn-state conn) '(redialing dialing hello))
        (cl-pushnew view (ladybird--conn-closing conn))))
      (ladybird--forget-view t))
    (when (eq ladybird--last-buffer (current-buffer))
      (setq ladybird--last-buffer nil))
    (ladybird--schedule-update)
    (when (and conn
               (memq conn ladybird--conns)
               (not (remq (current-buffer) (ladybird--buffers conn)))
               (not (ladybird--conn-on-ready conn))
               (not (ladybird--conn-closing conn)))
      (when (and (ladybird--ready-p conn)
                 (eq (process-type (ladybird--conn-process conn)) 'network))
        (message "ladybird: no page is open here on %s; its server keeps running%s"
                 (ladybird--conn-name conn)
                 (if (ladybird--conn-kept conn)
                     (format " with %d page%s, which `ladybird-connect' shows again"
                             (length (ladybird--conn-kept conn))
                             (if (cdr (ladybird--conn-kept conn)) "s" ""))
                   " until it is stopped where it runs")))
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
  (let* ((url (ladybird--clean (or (ladybird--url) "")))
         (title (alist-get 'title ladybird--state))
         (title (and title (string-trim (replace-regexp-in-string
                                         " +" " " (ladybird--clean title)))))
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
  "Return the mode line tags of a page buffer.
The first says where keys go and switches that when clicked."
  (concat
   (propertize (if ladybird-command-mode ":Command" ":Page")
               'mouse-face 'mode-line-highlight
               'help-echo (if ladybird-command-mode
                              "Keys are commands; mouse-1: send them to the page"
                            "Keys go to the page; mouse-1: command mode")
               'local-map (make-mode-line-mouse-map
                           'mouse-1 #'ladybird-mode-line-toggle))
   (and (alist-get 'loading ladybird--state) ":Loading")))

(defun ladybird-mode-line-toggle (event)
  "Switch `ladybird-command-mode' in the window of the mode line EVENT clicked."
  (declare (completion ignore))
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (ladybird-command-mode 'toggle)))


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

(defconst ladybird--function-keys
  '(return tab backspace delete deletechar escape insert left right up down home end
    prior next f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
    kp-0 kp-1 kp-2 kp-3 kp-4 kp-5 kp-6 kp-7 kp-8 kp-9 kp-add kp-subtract
    kp-multiply kp-divide kp-decimal kp-enter kp-equal kp-space kp-tab
    kp-left kp-right kp-up kp-down kp-home kp-end kp-prior kp-next
    kp-insert kp-delete)
  "Function keys that go to the page with any modifiers.")

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

(defun ladybird--meta-prefixed-p ()
  "Return non-nil if the current key arrived as ESC and a key.
A terminal sends a Meta key that way."
  (let ((keys (this-single-command-keys)))
    (and (> (length keys) 1) (eql (aref keys 0) ?\e))))

(defun ladybird-send-key (&optional n)
  "Send the key that invoked this command to the page, N times.
With an input method the characters it produces are sent."
  (declare (completion ignore))
  (interactive "p")
  (setq ladybird--last-buffer (current-buffer))
  (let* ((meta (ladybird--meta-prefixed-p))
         (specs (delq nil (mapcar (lambda (event) (ladybird-keys-event event meta))
                                  (ladybird--input-method-events
                                   last-command-event)))))
    (dotimes (_ (max 1 (or n 1)))
      (mapc #'ladybird--send-key specs))))

(defun ladybird--platform ()
  "Return the platform of the current buffer's server: `macos' or `other'."
  (if (equal (alist-get 'platform
                        (alist-get 'host (and ladybird--conn
                                              (ladybird--conn-server-info
                                               ladybird--conn))))
             "macos")
      'macos
    'other))

(defun ladybird-send-edit-key (&optional n)
  "Do in the page what the invoking Emacs key does, N times.
The key is translated for the server's platform by
`ladybird-keys-editing'; a key that has no translation is sent as it is."
  (declare (completion ignore))
  (interactive "p")
  (setq ladybird--last-buffer (current-buffer))
  (let* ((event last-command-event)
         (event (if (and (ladybird--meta-prefixed-p) (integerp event))
                    (event-convert-list (list 'meta event))
                  event))
         (actions (ladybird-keys-editing event (ladybird--platform))))
    (if (null actions)
        (ladybird-send-key n)
      (dotimes (_ (max 1 (or n 1)))
        (dolist (action actions)
          (pcase action
            (`(edit ,op) (ladybird--send-view "edit" `(op . ,op)))
            (_ (ladybird--send-key action))))))))

(defun ladybird--read-raw-key (prompt)
  "Read a key with PROMPT and return it; \\`C-g' is read as a key too.
A graphical frame gives the event as it is, passing over mouse
movement.  In a terminal `read-key' decodes the escape sequences of
function keys, and an ESC it reads with a key behind it, as a terminal
sends a Meta key, is that key with Meta."
  (let ((inhibit-quit t))
    (prog1 (if (display-graphic-p)
               (let (event)
                 (while (mouse-movement-p (setq event (read-event prompt))))
                 event)
             (let ((key (read-key prompt))
                   (keys (this-command-keys-vector)))
               (if (and (eql key ?\e) (= (length keys) 2))
                   (event-apply-modifier (aref keys 1) 'meta 27 "M-")
                 key)))
      (setq quit-flag nil))))

(defun ladybird-send-next-key (&optional n)
  "Read a key and send it to the page as it is, N times.
The key goes to the page whatever Emacs binds it to, so that \\`C-x',
\\`C-c', \\`C-g' or \\`C-s' reach it, untranslated.  A mouse or wheel
event is handled as usual."
  (interactive "p" ladybird-mode)
  (ladybird--check-view)
  (let* ((event (ladybird--read-raw-key "Key for the page: "))
         (spec (and (not (consp event)) (ladybird-keys-event event))))
    (cond
     ((consp event) (push event unread-command-events))
     ((null spec)
      (message "ladybird: %s has no key for the page"
               (key-description (vector event))))
     (t (setq ladybird--last-buffer (current-buffer))
        (dotimes (_ (max 1 (or n 1)))
          (ladybird--send-key spec))))))

(defun ladybird--paste (text)
  "Paste the string TEXT into the page."
  (ladybird--send-view "paste" `(text . ,(substring-no-properties text))))

(defun ladybird-yank ()
  "Paste the latest kill into the page."
  (interactive nil ladybird-mode)
  (ladybird--paste (current-kill 0)))

(defun ladybird-xterm-paste (event)
  "Paste the text of the terminal's paste EVENT into the page."
  (interactive "e")
  (when-let* ((text (nth 1 event))
              ((stringp text)))
    (ladybird--paste text)))

(defun ladybird-copy-selection ()
  "Copy the page's selected text to the kill ring."
  (interactive nil ladybird-mode)
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
  (interactive nil ladybird-mode)
  (ladybird--send-view "edit" '(op . "select_all")))

(defun ladybird-focus-next (&optional n)
  "Move the page's focus to the next link or field, N times.
This is the page's \\`TAB'."
  (interactive "p" ladybird-mode)
  (ladybird--check-view)
  (dotimes (_ (max 1 (or n 1)))
    (ladybird--send-key '("Tab" 9 0))))

(defun ladybird-focus-previous (&optional n)
  "Move the page's focus to the previous link or field, N times.
This is the page's \\`S-TAB'."
  (interactive "p" ladybird-mode)
  (ladybird--check-view)
  (dotimes (_ (max 1 (or n 1)))
    (ladybird--send-key `("Tab" 9 ,ladybird-keys-shift))))

(defcustom ladybird-translated-keys
  '("C-a" "C-e" "C-k" "C-d" "M-b" "M-f" "M-d" "M-DEL" "M-<backspace>"
    "C-<backspace>" "C-z" "C-/" "C-_" "C-?"
    "C-n" "C-p" "C-b" "C-f" "C-v" "M-v" "M-<" "M->")
  "Emacs editing and motion keys that do their job in the page.
Each is a string for `kbd'.  A key is translated to what does the same
in a browser on the server's platform: in a text field \\`C-a' and
\\`C-e' move to the start and the end of the line, \\`C-d' deletes a
character, \\`C-k' the rest of the line, \\`M-b' and \\`M-f' move by
words, \\`M-d', \\`M-DEL' and \\`C-<backspace>' delete a word, \\`C-z',
\\`C-/' and \\`C-_' undo and \\`C-?' redoes; \\`C-n', \\`C-p', \\`C-b' and
\\`C-f' are the cursor keys, \\`C-v' and \\`M-v' page down and up, and
\\`M-<' and \\`M->' go to the top and the bottom of the field or the
page.  Without a focused field the cursor keys, the page keys, \\`C-a'
and \\`C-e' scroll the page.  \\`C-M-_' and \\`C-S-z' (redo) can be added;
a key without a translation is sent as it is.  A key not in the list
keeps its Emacs meaning.  Set this with `setopt' or Custom, which
rebuild the keymap."
  :type '(repeat string)
  :group 'ladybird
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'ladybird--rebuild-page-map)
           (ladybird--rebuild-page-map))))

(defcustom ladybird-emacs-keys '("<f1>" "<f3>" "<f4>" "<f10>" "<f11>")
  "Keys that keep their Emacs meaning in a page buffer.
Each is a string for `kbd'.  The defaults are help, the keyboard macro
keys, the menu bar and full screen; without them these keys go to the
page.  A key here wins over `ladybird-translated-keys'.  Set this with
`setopt' or Custom, which rebuild the keymap."
  :type '(repeat string)
  :group 'ladybird
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'ladybird--rebuild-page-map)
           (ladybird--rebuild-page-map))))

(defun ladybird--build-page-map ()
  "Return the keymap of what `ladybird-mode' sends to the page.
That is the mouse and the wheel, the keys that insert themselves, the
function keys with any modifiers and `ladybird-translated-keys', less
`ladybird-emacs-keys'."
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
        (define-key map (vector (intern (concat prefix wheel))) #'ladybird-wheel))
      (dolist (key ladybird--function-keys)
        (define-key map (vector (intern (concat prefix (symbol-name key))))
                    #'ladybird-send-key)))
    (define-key map [mouse-movement] #'ladybird-mouse-move)
    (define-key map [remap self-insert-command] #'ladybird-send-key)
    ;; Without a binding of its own S-SPC would arrive as SPC.
    (dolist (key '("RET" "TAB" "DEL" "<backtab>" "S-SPC"))
      (define-key map (kbd key) #'ladybird-send-key))
    (dolist (key ladybird-translated-keys)
      (define-key map (kbd key) #'ladybird-send-edit-key))
    (define-key map [xterm-paste] #'ladybird-xterm-paste)
    (dolist (key ladybird-emacs-keys)
      (define-key map (kbd key) nil t))
    map))

(defvar ladybird--page-map (ladybird--build-page-map)
  "Keymap of what `ladybird-mode' sends to the page; the parent of its map.")

(defun ladybird--rebuild-page-map ()
  "Build `ladybird--page-map' again from the options."
  (when (boundp 'ladybird--page-map)
    (setcdr ladybird--page-map (cdr (ladybird--build-page-map)))))

(defun ladybird-zoom-adjust ()
  "Zoom the page by the last key typed, as `text-scale-adjust' does text.
\\`+' and \\`=' zoom in, \\`-' out and \\`0' back to the normal size; after
\\`C-x C-+', \\`C-x C--' or \\`C-x C-0' these keys alone zoom further."
  (interactive nil ladybird-mode)
  (pcase (event-basic-type last-command-event)
    ((or ?- 'kp-subtract) (ladybird-zoom-out))
    ((or ?0 'kp-0) (ladybird-zoom-reset))
    (_ (ladybird-zoom-in)))
  (set-transient-map
   (let ((map (make-sparse-keymap)))
     ;; The page map binds the keypad keys, which Emacs would otherwise
     ;; translate to these characters.
     (dolist (key '("+" "=" "-" "0" "<kp-add>" "<kp-equal>" "<kp-subtract>" "<kp-0>"))
       (define-key map (kbd key) #'ladybird-zoom-adjust))
     map)
   nil nil "Use %k for further zooming"))


;;; Command mode

(defun ladybird-command-mode-self-insert ()
  "Say how to type into the page again."
  (declare (completion ignore))
  (interactive)
  (user-error "%s" (substitute-command-keys
                    "Keys are commands here; \\`i' sends them to the page again")))

(defvar ladybird-command-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap self-insert-command] #'ladybird-command-mode-self-insert)
    (define-key map "i" #'ladybird-page-mode)
    (define-key map (kbd "RET") #'ladybird-page-mode)
    ;; The page map binds <return> and <backspace>, which Emacs would
    ;; otherwise translate to RET and DEL.
    (define-key map [return] #'ladybird-page-mode)
    (define-key map [kp-enter] #'ladybird-page-mode)
    (define-key map [backspace] #'ladybird-scroll-up-page)
    (define-key map "n" #'ladybird-scroll-down-line)
    (define-key map "p" #'ladybird-scroll-up-line)
    (define-key map " " #'ladybird-scroll-down-page)
    (define-key map (kbd "S-SPC") #'ladybird-scroll-up-page)
    (define-key map (kbd "DEL") #'ladybird-scroll-up-page)
    (define-key map "<" #'ladybird-scroll-top)
    (define-key map ">" #'ladybird-scroll-bottom)
    (dolist (binding '(([down] . ladybird-scroll-down-line)
                       ([up] . ladybird-scroll-up-line)
                       ([left] . ladybird-scroll-left)
                       ([right] . ladybird-scroll-right)
                       ([next] . ladybird-scroll-down-page)
                       ([prior] . ladybird-scroll-up-page)
                       ("\C-n" . ladybird-scroll-down-line)
                       ("\C-p" . ladybird-scroll-up-line)
                       ("\C-b" . ladybird-scroll-left)
                       ("\C-f" . ladybird-scroll-right)
                       ("\C-v" . ladybird-scroll-down-page)
                       ("\M-v" . ladybird-scroll-up-page)
                       ("\M-<" . ladybird-scroll-top)
                       ("\M->" . ladybird-scroll-bottom)))
      (define-key map (car binding) (cdr binding)))
    (define-key map "g" #'ladybird-goto-url)
    (define-key map "r" #'ladybird-reload)
    (define-key map "R" #'ladybird-reload-bypass-cache)
    (define-key map "k" #'ladybird-stop)
    (define-key map "s" #'ladybird-switch-to-page)
    (define-key map "b" #'ladybird-back)
    (define-key map "f" #'ladybird-forward)
    (define-key map "+" #'ladybird-zoom-in)
    (define-key map "=" #'ladybird-zoom-in)
    (define-key map "-" #'ladybird-zoom-out)
    (define-key map "0" #'ladybird-zoom-reset)
    (define-key map "w" #'ladybird-copy-url)
    (define-key map "c" #'ladybird-new-buffer)
    (define-key map "S" #'ladybird-screenshot)
    (define-key map "o" #'ladybird-follow-hint)
    (define-key map "q" #'ladybird-quit)
    (define-key map "Q" #'ladybird-close)
    map)
  "Keymap of `ladybird-command-mode'.")

(define-minor-mode ladybird-command-mode
  "Make single keys commands in a page buffer.
Keys that insert themselves and the motion keys are commands instead
of going to the page; other self-inserting keys say how to type into
the page again.  The page buffer's \\`C-c' commands, the mouse and the
wheel work as in page mode.

A text field of the page that gets the focus turns the mode off, and
it comes back when no field has the focus; see
`ladybird-field-focus-functions'.  The mode switched on by hand while a
field has the focus stays; page mode switched on by hand there also
ends when no field has the focus.

\\{ladybird-command-mode-map}"
  :lighter nil
  :keymap ladybird-command-mode-map
  :interactive (ladybird-mode)
  (unless (eq ladybird-command-mode ladybird--command-mode-was)
    (setq ladybird--command-mode-was ladybird-command-mode
          ladybird--field-page-mode
          (and ladybird--field-focused (if ladybird-command-mode 'hand t))))
  (force-mode-line-update))

(defcustom ladybird-field-focus-functions (list #'ladybird-follow-field-focus)
  "Functions called as the focus moves into or out of the page's text fields.
Each is called in the page buffer with two arguments: FOCUSED is
non-nil when a field got the focus and nil when no field has it any
more, and ACTIVATION is non-nil when the user pressed a key or a
mouse button in the page in the last few seconds, unlike a focus that
autofocus or a script moves on its own.  ACTIVATION is nil also for a
key that moves the focus into a frame of another site.  A field that
got the focus without user input calls them again with ACTIVATION
when the user first presses a key or button while a field has the
focus; otherwise a focus moving from one field to another calls
nothing.  A text field is an editable input or textarea, or an
element or document that is editable.  An error a function signals is
reported and the others still run; once one kills the buffer, the
rest are not called.

The default, `ladybird-follow-field-focus', turns `ladybird-command-mode'
off while a field has the focus."
  :type 'hook
  :options (list #'ladybird-follow-field-focus)
  :group 'ladybird)

(defun ladybird--enter-field (&optional force)
  "Turn `ladybird-command-mode' off for a text field that got the focus.
Unless FORCE, command mode switched on by hand while a field has the
focus stays."
  (when (and ladybird-command-mode
             (or force (not (eq ladybird--field-page-mode 'hand))))
    (ladybird-command-mode -1)
    (setq ladybird--field-page-mode t)))

(defun ladybird-follow-field-focus (focused &optional _activation)
  "Leave `ladybird-command-mode' while a text field of the page has the focus.
FOCUSED non-nil turns the mode off for the field that got the focus;
nil turns it on again if it was turned off while a field had the focus,
by the field or by hand.  Command mode switched on by hand while a
field has the focus stays.  For `ladybird-field-focus-functions'."
  (cond (focused (ladybird--enter-field))
        ((eq ladybird--field-page-mode t) (ladybird-command-mode 1))))

(defun ladybird--run-field-focus-function (function buffer &rest args)
  "Call FUNCTION with ARGS in BUFFER and report an error it signals.
Return non-nil once BUFFER is dead, which ends `run-hook-wrapped'."
  (if (not (buffer-live-p buffer))
      t
    (with-current-buffer buffer
      (with-demoted-errors "ladybird-field-focus-functions: %S"
        (apply function args)))
    nil))

(defun ladybird--set-field-focus (enabled activation)
  "Take ENABLED and ACTIVATION of `ime' as the state of the page's fields.
Run `ladybird-field-focus-functions' when that changes."
  (let ((focus (cond ((not enabled) nil)
                     ((or activation (eq ladybird--field-focused 'user)) 'user)
                     (t 'page))))
    (unless (eq focus ladybird--field-focused)
      (setq ladybird--field-focused focus)
      (when (and (not focus) (eq ladybird--field-page-mode 'hand))
        (setq ladybird--field-page-mode nil))
      (run-hook-wrapped 'ladybird-field-focus-functions
                        #'ladybird--run-field-focus-function
                        (current-buffer) (and focus t) activation))))

(ladybird--defhandler "ime" (conn msg)
  "Follow the focus into and out of the text fields of a page on CONN.
See `ladybird-field-focus-functions'."
  (ladybird--with-view conn msg
    (ladybird--set-field-focus (alist-get 'enabled msg)
                               (and (alist-get 'activation msg) t))))

(defun ladybird-page-mode ()
  "Send keys to the page again: turn `ladybird-command-mode' off."
  (interactive nil ladybird-mode)
  (when ladybird-command-mode
    (ladybird-command-mode -1)))


;;; Major mode

(defcustom ladybird-initial-mode 'command
  "Where the keys of a new page buffer go.
`command' starts the buffer in `ladybird-command-mode', where single
keys are commands; `page' sends them to the page."
  :type '(choice (const :tag "Command mode" command)
                 (const :tag "To the page" page))
  :group 'ladybird)

(defvar ladybird-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ladybird--page-map)
    (define-key map (kbd "C-c C-l") #'ladybird-goto-url)
    (define-key map (kbd "C-c C-o") #'ladybird-follow-hint)
    (define-key map (kbd "C-c C-b") #'ladybird-back)
    (define-key map (kbd "C-c C-f") #'ladybird-forward)
    (define-key map (kbd "C-c C-r") #'ladybird-reload)
    (define-key map (kbd "C-c C-k") #'ladybird-stop)
    (define-key map (kbd "C-c C-s") #'ladybird-switch-to-page)
    (define-key map (kbd "C-c C-w") #'ladybird-copy-url)
    (define-key map (kbd "C-c C-t") #'ladybird-toggle-console)
    (define-key map (kbd "C-c C-n") #'ladybird-focus-next)
    (define-key map (kbd "C-c C-p") #'ladybird-focus-previous)
    (define-key map (kbd "C-c C-q") #'ladybird-send-next-key)
    (define-key map [remap quoted-insert] #'ladybird-send-next-key)
    (define-key map (kbd "C-c C-y") #'ladybird-yank)
    (define-key map (kbd "C-y") #'ladybird-yank)
    (define-key map (kbd "C-c C-e") #'ladybird-command-mode)
    (define-key map (kbd "C-c C-j") #'ladybird-page-mode)
    (define-key map (kbd "C-s") #'ladybird-find)
    (define-key map (kbd "C-r") #'ladybird-find-backward)
    (define-key map (kbd "M-s n") #'ladybird-find-next)
    (define-key map (kbd "M-s p") #'ladybird-find-previous)
    (define-key map (kbd "M-w") #'ladybird-copy-selection)
    (define-key map [remap mark-whole-buffer] #'ladybird-select-all)
    (define-key map [remap text-scale-adjust] #'ladybird-zoom-adjust)
    map)
  "Keymap of `ladybird-mode'.
Its parent `ladybird--page-map' sends keys and mouse events to the page.")

(define-derived-mode ladybird-mode nil "Ladybird"
  "Major mode of buffers that show a page rendered by a Ladybird server.
A new buffer starts in `ladybird-command-mode' unless
`ladybird-initial-mode' says otherwise.  Outside it keys go to the
page: those that insert themselves, \\`RET', \\`TAB', \\`DEL', the cursor
and function keys, and the Emacs editing and motion keys of
`ladybird-translated-keys', translated for the server's platform.  The
mouse and the wheel act on the page.  Other keys, such as \\`C-x',
\\`C-h', \\`M-x', \\`C-u' and \\`C-g', keep their Emacs meaning.
\\<ladybird-mode-map>
  \\[ladybird-goto-url]  open a URL; with a prefix argument in a new buffer
  \\[ladybird-follow-hint]  activate a link, button or field by its label
  \\[ladybird-back], \\[ladybird-forward]  back, forward
  \\[ladybird-reload]  reload; with a prefix argument bypass the cache
  \\[ladybird-stop]  stop loading
  \\[ladybird-switch-to-page]  switch to another page by its title or URL
  \\[ladybird-copy-url]  copy the page's URL
  \\[ladybird-toggle-console]  console output on or off
  \\[ladybird-focus-next], \\[ladybird-focus-previous]  focus the next, the previous link or field
  \\[ladybird-send-next-key], \\`C-q'  send the next key to the page as it is
  \\[ladybird-yank]  paste the latest kill
  \\[ladybird-copy-selection]  copy the page's selection
  \\[ladybird-select-all]  select all
  \\[ladybird-find], \\[ladybird-find-backward]  find in the page
  \\[ladybird-find-next], \\[ladybird-find-previous]  next, previous match
  \\`C-x C-+', \\`C-x C--', \\`C-x C-0'  zoom in, out, back
  \\[ladybird-command-mode]  `ladybird-command-mode': single keys are commands
  \\[ladybird-page-mode]  send keys to the page again

Killing the buffer closes the page."
  :interactive nil
  (setq buffer-read-only t)
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
  ;; Global: a window that stops showing a page runs the hooks of the
  ;; buffer it shows now.
  (add-hook 'window-buffer-change-functions #'ladybird--window-buffer-changed)
  (add-hook 'delete-frame-functions #'ladybird--schedule-update)
  (ladybird--follow-frame-visibility)
  (add-hook 'window-selection-change-functions #'ladybird--selection-changed
            nil t)
  (add-hook 'kill-buffer-hook #'ladybird--kill nil t)
  (add-hook 'post-command-hook #'ladybird--after-command)
  (remove-function after-focus-change-function #'ladybird--focus-changed)
  (add-function :after after-focus-change-function #'ladybird--focus-changed)
  (when (eq ladybird-initial-mode 'command)
    (ladybird-command-mode 1)))

(put 'ladybird-mode 'mode-class 'special)


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

(defun ladybird--display-new-page (buffer)
  "Show BUFFER, a new page buffer, as `ladybird-new-page-display' says."
  (pcase ladybird-new-page-display
    ('background
     (unless (display-buffer buffer '(display-buffer-no-window
                                      (allow-no-window . t)))
       (message "ladybird: %s opens in the background" (buffer-name buffer))))
    ('other-window
     (pop-to-buffer buffer '(nil (inhibit-same-window . t)))
     (setq ladybird--last-buffer buffer))
    (_ (pop-to-buffer-same-window buffer)
       (setq ladybird--last-buffer buffer))))

(defun ladybird--open (url host)
  "Open URL in a new page buffer on HOST and return the buffer.
HOST is a (LABEL ENDPOINT...) list.  The buffer is shown as
`ladybird-new-page-display' says.  A connected server that holds as
many pages as it can and holds only one loads URL in it; one that
holds more is refused with a `user-error'."
  (ladybird--ensure-module)
  (unless (ladybird--module-available-p)
    (user-error "The ladybird-module is not loaded"))
  (let* ((conn (ladybird--find-conn host))
         (full (and (ladybird--ready-p conn)
                    (>= (ladybird--view-count conn) (ladybird--max-views conn))))
         (page (and full (= (ladybird--max-views conn) 1)
                    (ladybird--page-buffer conn))))
    (cond
     (page
      (ladybird--display-new-page page)
      (ladybird--load-in-page conn page url)
      page)
     (full (user-error "%s" (ladybird--full-message conn)))
     (t
      (let ((buffer (ladybird--make-view-buffer nil nil url host)))
        (ladybird--display-new-page buffer)
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
        buffer)))))

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
Every page open on the server gets a buffer, also on a connection that
is open already, where pages of buffers killed with
`ladybird-keep-view-on-kill' get one again.  The page buffer used last
is shown if it is one of them, else the one with the lowest view id.
HOST is a label of `ladybird-hosts' or a (LABEL ENDPOINT...) list;
interactively it is read."
  (interactive (list (ladybird--read-host)))
  (ladybird--ensure-module)
  (ladybird--connect
   (if (consp host) host (ladybird--host host))
   (lambda (conn)
     (ladybird--restore-kept conn)
     (let* ((buffers (sort (seq-filter (lambda (buffer)
                                         (buffer-local-value 'ladybird--view buffer))
                                       (ladybird--buffers conn))
                           (lambda (a b)
                             (< (buffer-local-value 'ladybird--view a)
                                (buffer-local-value 'ladybird--view b)))))
            (shown (if (memq ladybird--last-buffer buffers)
                       ladybird--last-buffer
                     (car buffers))))
       (if (null buffers)
           (message "ladybird: connected to %s, which has no page open"
                    (ladybird--conn-name conn))
         (setq ladybird--last-buffer shown)
         (pop-to-buffer-same-window shown)
         (message "ladybird: %d page%s on %s%s" (length buffers)
                  (if (cdr buffers) "s" "") (ladybird--conn-name conn)
                  (if (cdr buffers)
                      (substitute-command-keys
                       "; \\<ladybird-mode-map>\\[ladybird-switch-to-page] switches")
                    "")))))))

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

(defun ladybird--page-candidate (title url)
  "Return the completion string of a page with TITLE and URL.
The title is cut, the URL kept whole."
  (let ((title (string-trim (replace-regexp-in-string " +" " " (ladybird--clean title))))
        (url (ladybird--clean url)))
    (if (or (string-empty-p title) (equal title url))
        url
      (concat (truncate-string-to-width title 60 nil nil t) "  " url))))

(defun ladybird--page-candidates ()
  "Return an alist of completion strings and the pages they name.
A page is a buffer, or (CONN . VIEW) for a view CONN's server keeps for
a killed buffer.  A string has the page's title and URL; the buffer
used last comes first, the current one last."
  (let ((buffers (seq-filter (lambda (buffer)
                               (buffer-local-value 'ladybird--conn buffer))
                             (ladybird--buffers)))
        (pages nil)
        (candidates nil))
    (setq buffers (append (remq (current-buffer) buffers)
                          (and (memq (current-buffer) buffers)
                               (list (current-buffer)))))
    (dolist (buffer buffers)
      (with-current-buffer buffer
        (push (list buffer (alist-get 'title ladybird--state) (ladybird--url)) pages)))
    (dolist (conn ladybird--conns)
      (when (ladybird--ready-p conn)
        (dolist (entry (ladybird--conn-kept conn))
          (push (list (cons conn (car entry)) (alist-get 'title (cdr entry))
                      (alist-get 'url (cdr entry)))
                pages))))
    (dolist (page (nreverse pages))
      (let* ((base (ladybird--page-candidate (nth 1 page) (or (nth 2 page) "")))
             (name base)
             (n 1))
        (while (assoc name candidates)
          (setq name (format "%s <%d>" base (cl-incf n))))
        (push (cons name (car page)) candidates)))
    (nreverse candidates)))

(defun ladybird--page-conn (page)
  "Return the connection of PAGE, a value of `ladybird--page-candidates'."
  (if (bufferp page) (buffer-local-value 'ladybird--conn page) (car page)))

(defun ladybird--opener-name (page)
  "Return the name of the open page that opened PAGE, or nil.
PAGE is a value of `ladybird--page-candidates'."
  (when-let* (((bufferp page))
              (opener (buffer-local-value 'ladybird--opener page))
              (conn (buffer-local-value 'ladybird--conn page)))
    (if-let* ((buffer (ladybird--view-buffer conn `((view . ,opener)))))
        (buffer-name buffer)
      (when-let* ((state (cdr (assq opener (ladybird--conn-kept conn)))))
        (ladybird--page-candidate (alist-get 'title state)
                                  (or (alist-get 'url state) ""))))))

(defun ladybird-switch-to-page (buffer)
  "Show the page BUFFER, read with completion over titles and URLs.
The pages of every server are offered, also those a connected server
keeps for buffers killed with `ladybird-keep-view-on-kill', which get a
buffer again.  A page that a page opened is annotated with its opener,
and with several servers each page with its host.  Any part of a title
or URL completes, in the completion category `ladybird-page'."
  (interactive
   (let* ((candidates (or (ladybird--page-candidates)
                          (user-error "No page is open")))
          (hosts (delete-dups
                  (mapcar (lambda (candidate) (ladybird--page-conn (cdr candidate)))
                          candidates)))
          (annotate
           (and (or (cdr hosts)
                    (seq-some (lambda (candidate) (ladybird--opener-name (cdr candidate)))
                              candidates))
                (lambda (name)
                  (when-let* ((page (cdr (assoc name candidates))))
                    (concat (and (cdr hosts)
                                 (format "  [%s]" (ladybird--conn-name
                                                   (ladybird--page-conn page))))
                            (and-let* ((opener (ladybird--opener-name page)))
                              (format "  opened by %s" opener)))))))
          ;; A part of the title or of the URL picks a page.
          (completion-category-defaults
           (cons '(ladybird-page (styles substring basic))
                 completion-category-defaults))
          (choice (completing-read
                   "Page: "
                   (lambda (string predicate action)
                     (if (eq action 'metadata)
                         `(metadata (category . ladybird-page)
                                    (display-sort-function . identity)
                                    (cycle-sort-function . identity)
                                    ,@(and annotate
                                           `((annotation-function . ,annotate))))
                       (complete-with-action action candidates string predicate)))
                   nil t nil nil (caar candidates))))
     (list (cdr (assoc choice candidates)))))
  (when (consp buffer)
    (setq buffer (car (ladybird--restore-kept (car buffer) (cdr buffer)))))
  (unless (buffer-live-p buffer)
    (user-error "No such page"))
  (pop-to-buffer-same-window buffer)
  (setq ladybird--last-buffer buffer))

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

(defun ladybird-goto-url (url &optional new-buffer)
  "Load URL in the current page buffer, or with NEW-BUFFER in a new one.
Text that is no URL is searched for or taken as a host name, as the
server sees fit.  Interactively NEW-BUFFER is the prefix argument; a
new buffer opens on the current buffer's host."
  (interactive
   (list (read-string (if current-prefix-arg "URL in a new buffer: " "URL: ")
                      (ladybird--url) 'ladybird-url-history)
         current-prefix-arg)
   ladybird-mode)
  (when (string-empty-p url)
    (user-error "No URL"))
  (if new-buffer
      (ladybird--open url ladybird--host)
    (ladybird--check-view)
    (ladybird--send-view "load" `(url . ,url))))

(defun ladybird-reload (&optional bypass-cache)
  "Load the page again; with BYPASS-CACHE without using the cache.
Interactively BYPASS-CACHE is the prefix argument."
  (interactive "P" ladybird-mode)
  (ladybird--check-view)
  (ladybird--send-view "reload" `(bypass_cache . ,(ladybird--bool bypass-cache))))

(defun ladybird-reload-bypass-cache ()
  "Load the page again without using the cache."
  (interactive nil ladybird-mode)
  (ladybird-reload t))

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


;;; Hints

(defvar ladybird-hint-map
  (let ((map (make-keymap)))
    (set-char-table-range (nth 1 map) (cons ?\s (max-char))
                          #'ladybird-hint-add-char)
    (define-key map (kbd "DEL") #'ladybird-hint-delete-char)
    (define-key map [backspace] #'ladybird-hint-delete-char)
    ;; The page map binds the keypad digits, which Emacs would otherwise
    ;; translate to digits.
    (dotimes (digit 10)
      (define-key map (vector (intern (format "kp-%d" digit)))
                  #'ladybird-hint-add-char))
    (define-key map (kbd "C-g") #'ladybird-hint-quit)
    (define-key map [escape] #'ladybird-hint-quit)
    map)
  "Keymap in force while `ladybird-follow-hint' reads a label.
Characters add to the label.  A key this map does not bind ends the
hints and then does what it does otherwise.")

(defvar ladybird--hint-map-alist (list (cons 'ladybird--hint ladybird-hint-map))
  "Entry of `emulation-mode-map-alists' for `ladybird-hint-map'.
The map is in force exactly while `ladybird--hint' is non-nil, in
every buffer and above the minor and major modes' maps.")

(defun ladybird--hint-alphabet-p (alphabet)
  "Return non-nil if ALPHABET is a string the server makes labels of."
  (let ((case-fold-search nil))
    (and (stringp alphabet)
         (<= 2 (length alphabet) 36)
         (string-match-p "\\`[a-z0-9]*\\'" alphabet)
         (= (length (delete-dups (string-to-list alphabet))) (length alphabet)))))

(defun ladybird--hint-of-p (conn msg)
  "Return non-nil if MSG on CONN names the hint session in progress."
  (and ladybird--hint
       (eq (ladybird--hint-conn ladybird--hint) conn)
       (equal (alist-get 'view msg) (ladybird--hint-view ladybird--hint))
       (equal (alist-get 'id msg) (ladybird--hint-id ladybird--hint))))

(defun ladybird--hint-ended-p (conn msg)
  "Return non-nil if MSG on CONN names a hint session that is over."
  (and (alist-get 'id msg)
       (member (cons (alist-get 'view msg) (alist-get 'id msg))
               (ladybird--conn-hints-ended conn))))

(defun ladybird--hint-send (hint type &rest fields)
  "Send a message of TYPE with the alist FIELDS about the session HINT.
Nothing is sent on a connection that is not ready.  Return non-nil if
it was sent."
  (let ((conn (ladybird--hint-conn hint)))
    (and (ladybird--ready-p conn)
         (ladybird--send conn `((type . ,type) (view . ,(ladybird--hint-view hint))
                                (id . ,(ladybird--hint-id hint)) ,@fields)))))

(defun ladybird--hint-stop (&optional tell)
  "End the hint session in progress, if there is one.
`ladybird-hint-map' goes out of force with it.  The connection keeps
the session's view and id among the 16 that ended last.  With TELL the
server gets a `hints_end' that activates nothing."
  (when-let* ((hint ladybird--hint))
    (setq ladybird--hint nil)
    (remove-hook 'pre-command-hook #'ladybird--hint-pre-command)
    (remove-hook 'minibuffer-setup-hook #'ladybird--hint-minibuffer)
    (let ((conn (ladybird--hint-conn hint)))
      (setf (ladybird--conn-hints-ended conn)
            (take 16 (cons (cons (ladybird--hint-view hint) (ladybird--hint-id hint))
                           (ladybird--conn-hints-ended conn)))))
    (when tell
      (ladybird--hint-send hint "hints_end" '(activate . :null)))
    (when (and ladybird--hint-shown (equal (current-message) ladybird--hint-shown))
      (message nil))
    (setq ladybird--hint-shown nil)))

(defun ladybird--hint-keep-p ()
  "Return non-nil if the command about to run continues the hints.
The commands of `ladybird-hint-map' and mouse movement do."
  (or (mouse-movement-p last-command-event)
      (let ((command (lookup-key ladybird-hint-map (this-command-keys-vector))))
        (and command (eq command this-command)))))

(defun ladybird--hint-pre-command ()
  "End the hints before a command that does not continue them."
  (when (and ladybird--hint (not (ladybird--hint-keep-p)))
    (with-demoted-errors "ladybird: ending the hints: %S"
      (ladybird--hint-stop t))))

(defun ladybird--hint-minibuffer ()
  "End the hints as the minibuffer opens."
  (ladybird--hint-stop t))

(defun ladybird--hint-here-p ()
  "Return non-nil if a session's selected window shows its page.
In another buffer the hints end and the keys of the current command
are read again, with `ladybird-hint-map' out of force.  Without a
session the keys are dropped."
  (cond
   ((null ladybird--hint) nil)
   ((eq (window-buffer (selected-window)) (ladybird--hint-buffer ladybird--hint)) t)
   (t (ladybird--hint-stop t)
      (setq unread-command-events (append (this-command-keys-vector)
                                          unread-command-events))
      nil)))

(defun ladybird--hint-remaining (hint &optional prefix)
  "Return the items of HINT whose label starts with PREFIX.
PREFIX defaults to what has been typed."
  (let ((prefix (or prefix (ladybird--hint-prefix hint))))
    (seq-filter (lambda (item) (string-prefix-p prefix (alist-get 'label item)))
                (ladybird--hint-items hint))))

(defun ladybird--hint-describe (item)
  "Return the text of the hint ITEM, or its URL if it has no text."
  (let ((text (string-trim (or (alist-get 'text item) ""))))
    (if (string-empty-p text)
        (or (alist-get 'url item) (alist-get 'kind item) "")
      text)))

(defun ladybird--hint-prompt ()
  "Show what has been typed of a label and how many items remain."
  (when-let* ((hint ladybird--hint))
    (let* ((remaining (ladybird--hint-remaining hint))
           (text (ladybird--echo-line
                  (concat
                   (if (ladybird--hint-new-buffer hint) "Hint (new buffer): " "Hint: ")
                   (ladybird--hint-prefix hint)
                   (cond ((ladybird--hint-waiting hint) "  [waiting for the labels]")
                         (t (format "  [%d left%s]" (length remaining)
                                    (if (ladybird--hint-truncated hint)
                                        ", more not labelled"
                                      ""))))
                   (and (not (ladybird--hint-waiting hint))
                        (= (length remaining) 1)
                        (concat " " (ladybird--hint-describe (car remaining)))))))
           (message-log-max nil))
      (setq ladybird--hint-shown text)
      (message "%s" text))))

(defun ladybird--hint-items-p (items alphabet)
  "Return non-nil if ITEMS is a usable `items' field of a `hints_list'.
It is an array of objects, each with an integer `index', a `label' of
the characters of ALPHABET, and a `kind', `text' and `url' that are
strings or null."
  (and (vectorp items)
       (seq-every-p
        (lambda (item)
          (and (consp item) (proper-list-p item) (seq-every-p #'consp item)
               (integerp (alist-get 'index item))
               (let ((label (alist-get 'label item)))
                 (and (stringp label) (not (string-empty-p label))
                      (seq-every-p (lambda (char) (seq-contains-p alphabet char))
                                   label)))
               (seq-every-p (lambda (key)
                              (let ((value (alist-get key item)))
                                (or (null value) (stringp value))))
                            '(kind text url))))
        items)))

(defun ladybird--link-url-p (url page-url)
  "Return non-nil if URL, a link of the page at PAGE-URL, may be loaded.
The page names URL: http and https are loaded, file only from a page
that is a file itself."
  (let ((case-fold-search t))
    (and (stringp url)
         (or (string-match-p "\\`https?:" url)
             (and (string-match-p "\\`file:" url)
                  (stringp page-url)
                  (string-match-p "\\`file:" page-url))))))

(defun ladybird--follow-link (url &optional new-buffer)
  "Load URL, a link of the current page, in the page.
With NEW-BUFFER it opens in a new page buffer.  A URL that
`ladybird--link-url-p' does not accept is refused with a message."
  (cond
   ((not (ladybird--link-url-p url (ladybird--url)))
    (message "ladybird: not opening %s" (ladybird--echo-line (format "%s" url))))
   (new-buffer (ladybird--open url ladybird--host))
   (t (ladybird--send-view "load" `(url . ,url)))))

(defun ladybird--hint-choose (hint item)
  "End the session HINT by activating ITEM.
With HINT's prefix argument a link opens in a new buffer instead, as
`ladybird--follow-link' allows; a text field gets the focus and
`ladybird-command-mode' is turned off until `ladybird-follow-field-focus'
turns it on again."
  (let* ((url (alist-get 'url item))
         (kind (alist-get 'kind item))
         (open (and (ladybird--hint-new-buffer hint) (equal kind "link")
                    url (not (string-empty-p url))))
         (buffer (ladybird--hint-buffer hint)))
    (ladybird--hint-stop)
    (ladybird--hint-send hint "hints_end"
                         `(activate . ,(if open :null (alist-get 'index item))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (cond (open (ladybird--follow-link url t))
              ((equal kind "input") (ladybird--enter-field t)))))))

(defun ladybird--hint-add (char)
  "Add CHAR to the label typed in the hint session in progress.
Before the labels arrive it is kept; then a character that continues
no label is refused, and one that completes a label activates its
item."
  (let* ((hint ladybird--hint)
         (prefix (concat (ladybird--hint-prefix hint) (string char))))
    (if (ladybird--hint-waiting hint)
        (setf (ladybird--hint-prefix hint) prefix)
      (let* ((remaining (ladybird--hint-remaining hint prefix))
             (chosen (seq-find (lambda (item)
                                 (equal (alist-get 'label item) prefix))
                               remaining)))
        (cond
         ((null remaining) (ding))
         (chosen (ladybird--hint-choose hint chosen))
         (t (setf (ladybird--hint-prefix hint) prefix)
            (ladybird--hint-send hint "hints_narrow" `(prefix . ,prefix))))))
    (ladybird--hint-prompt)))

(defun ladybird--hint-take-up (hint)
  "Take up the characters typed in HINT before its labels arrived.
This runs from a timer: a completed label is activated outside the
process filter."
  (when (and (eq ladybird--hint hint) (ladybird--hint-waiting hint))
    (let ((typed (ladybird--hint-prefix hint)))
      (setf (ladybird--hint-waiting hint) nil
            (ladybird--hint-prefix hint) "")
      ;; A command it runs may refuse; from a timer that is a message.
      (condition-case err
          (seq-doseq (char typed)
            (when (eq ladybird--hint hint)
              (ladybird--hint-add char)))
        (user-error (message "%s" (error-message-string err))))
      (ladybird--hint-prompt))))

(defun ladybird-follow-hint (&optional new-buffer)
  "Activate a link, a button or a field of the page by typing its label.
The page labels what can be activated in its window with strings of
the characters of `ladybird-hint-alphabet'.  Each character typed
narrows the labels shown, and completing a label activates its
element: a link or button is clicked, a text field gets the focus and
`ladybird-command-mode' turns off until `ladybird-follow-field-focus'
turns it on again.
\\<ladybird-hint-map>\\[ladybird-hint-delete-char] deletes the last character
and \\[ladybird-hint-quit] ends the hints; a key that is not a character ends them
and does what it does otherwise.

With a prefix argument NEW-BUFFER a link opens in a new page buffer,
if it is an http or https URL, or a file URL of a page that is a file."
  (interactive "P" ladybird-mode)
  (ladybird--check-view)
  (unless (ladybird--hint-alphabet-p ladybird-hint-alphabet)
    (user-error "`ladybird-hint-alphabet' needs 2 to 36 different characters \
of a-z and 0-9"))
  (unless (seq-contains-p (alist-get 'features
                                     (ladybird--conn-server-info ladybird--conn))
                          "hints")
    (user-error "The server on %s does not offer hints"
                (ladybird--conn-name ladybird--conn)))
  (ladybird--hint-stop t)
  (let* ((conn ladybird--conn)
         (hint (ladybird--make-hint
                :conn conn :view ladybird--view :buffer (current-buffer)
                :id (cl-incf (ladybird--conn-next-request conn))
                :alphabet ladybird-hint-alphabet
                :new-buffer (and new-buffer t))))
    (when (ladybird--hint-send hint "hints" `(alphabet . ,ladybird-hint-alphabet))
      (add-to-list 'emulation-mode-map-alists 'ladybird--hint-map-alist)
      (setq ladybird--hint hint
            ladybird--last-buffer (current-buffer))
      (add-hook 'pre-command-hook #'ladybird--hint-pre-command)
      (add-hook 'minibuffer-setup-hook #'ladybird--hint-minibuffer)
      (ladybird--hint-prompt))))

(defun ladybird-hint-add-char ()
  "Add the character typed to the label of `ladybird-follow-hint'.
A character that continues no label is refused."
  (declare (completion ignore))
  (interactive)
  (when (ladybird--hint-here-p)
    (let ((event last-command-event))
      (ladybird--hint-add
       (if (symbolp event)
           (string-to-char (string-remove-prefix "kp-" (symbol-name event)))
         (downcase event))))))

(defun ladybird-hint-delete-char ()
  "Delete the last character typed of the label of `ladybird-follow-hint'."
  (declare (completion ignore))
  (interactive)
  (when (ladybird--hint-here-p)
    (let* ((hint ladybird--hint)
           (prefix (ladybird--hint-prefix hint)))
      (if (string-empty-p prefix)
          (ding)
        (setq prefix (substring prefix 0 -1))
        (setf (ladybird--hint-prefix hint) prefix)
        (unless (ladybird--hint-waiting hint)
          (ladybird--hint-send hint "hints_narrow" `(prefix . ,prefix))))
      (ladybird--hint-prompt))))

(defun ladybird-hint-quit ()
  "End `ladybird-follow-hint' without activating anything."
  (declare (completion ignore))
  (interactive)
  (ladybird--hint-stop t))

(ladybird--defhandler "hints_cancelled" (conn msg)
  "End the hint session the server on CONN ended; nothing is sent.
A message for another session is ignored."
  (when (ladybird--hint-of-p conn msg)
    (ladybird--hint-stop)
    (message "The page ended the hint session")))

(ladybird--defhandler "hints_list" (conn msg)
  "Take the labels a page on CONN shows for the hint session in progress.
A list for another session is ignored; an empty one ends the session,
and one that is unusable ends it with a `hints_end'.  The characters
typed while the labels were awaited are taken up from a timer."
  (let ((hint ladybird--hint)
        (items (alist-get 'items msg)))
    (when (and (ladybird--hint-of-p conn msg) (ladybird--hint-waiting hint)
               (null (ladybird--hint-items hint)))
      (cond
       ((not (ladybird--hint-items-p items (ladybird--hint-alphabet hint)))
        (ladybird--hint-stop t)
        (message "ladybird: the page sent unusable hints"))
       ((seq-empty-p items)
        (ladybird--hint-stop)
        (message "No hints in view"))
       (t
        (setf (ladybird--hint-items hint) (append items nil)
              (ladybird--hint-truncated hint) (alist-get 'truncated msg))
        (if (string-empty-p (ladybird--hint-prefix hint))
            (progn (setf (ladybird--hint-waiting hint) nil)
                   (ladybird--hint-prompt))
          (run-at-time 0 nil #'ladybird--hint-take-up hint)))))))


;;; Page events

(ladybird--defhandler "cursor" (conn msg)
  "Show the pointer shape the page on CONN asks for."
  (ladybird--with-view conn msg
    (setq ladybird--cursor (ladybird-keys-pointer (alist-get 'cursor msg)))
    (let ((inhibit-read-only t))
      (with-silent-modifications
        (put-text-property 1 2 'pointer ladybird--cursor)))))

(defun ladybird--echo-free-p ()
  "Return non-nil when the echo area may be used for a hover message.
It is not while it shows a prompt."
  (not (or (active-minibuffer-window) cursor-in-echo-area ladybird--hint)))

(defun ladybird--echo-line (text)
  "Return TEXT cut to one line of the echo area.
A longer message would grow the echo area and with it resize the page."
  (truncate-string-to-width
   (ladybird--clean text)
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
An error with the id of the hint session in progress ends the session;
one with the id of a session that is over is ignored.
An error that names neither a request nor a view, while a buffer waits
for a view, is the answer to the oldest `create_view' of a server that
does not name the request."
  (cond
   ((ladybird--hint-of-p conn msg)
    (ladybird--hint-stop)
    (message "ladybird: %s: %s" (ladybird--conn-name conn)
             (alist-get 'message msg)))
   ((ladybird--hint-ended-p conn msg))
   ((and (ladybird--conn-creating conn) (null (alist-get 'view msg)))
    (ladybird--create-failed conn (ladybird--pop-creating conn)
                             (alist-get 'message msg)))
   (t (message "ladybird: %s: %s" (ladybird--conn-name conn)
               (alist-get 'message msg)))))

(ladybird--defhandler "popup_blocked" (conn msg)
  "Remember the window a page on CONN tried to open.
A window without a URL is reported and not remembered.  The message
says what `ladybird-open-blocked-popup' does: open the URL as a new
page, load it in the page of a server that holds one, or nothing on a
server that has all the pages it can hold."
  (ladybird--with-view conn msg
    (let ((url (alist-get 'url msg))
          (max (ladybird--max-views conn)))
      (when (stringp url)
        (setq ladybird--blocked-popup url))
      (message "Popup blocked: %s%s"
               (if (stringp url) (ladybird--clean url) "a window without a URL")
               (cond ((not (stringp url)) "")
                     ((and (> max 1) (>= (ladybird--view-count conn) max))
                      (format "  (%s holds no more pages)" (ladybird--conn-name conn)))
                     (t (substitute-command-keys
                         (if (= max 1)
                             "  (\\[ladybird-open-blocked-popup] loads it here)"
                           "  (\\[ladybird-open-blocked-popup] opens it)"))))))))

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
  (let ((origin (ladybird--clean (alist-get 'origin msg))))
    (cond ((not (string-empty-p origin)) origin)
          ((ladybird--view-buffer conn msg)
           (buffer-name (ladybird--view-buffer conn msg)))
          (t "The page"))))

(ladybird--defhandler "dialog" (conn msg)
  "Show the alert, confirmation or prompt of a page on CONN."
  (let* ((kind (alist-get 'kind msg))
         (text (ladybird--clean (alist-get 'message msg)))
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
               (label (ladybird--clean
                       (concat (and group (not (string-empty-p group))
                                    (concat group " / "))
                               (or (alist-get 'label item) ""))))
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
shared memory, no segment of a server there has failed to map and the
server names this machine as its host."
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
PROMPT asks the question.  Return nil if the input is empty.  Keys
typed before the prompt opened are discarded, and a choice has to be
typed or completed in full: \\`RET' on a part of one, or on anything
else, asks again with the input gone.  What PROMPT asks is the server's
question, and keys meant for the page do not answer it."
  (let ((answer nil)
        (asked nil))
    (while (progn
             (discard-input)
             (setq answer (completing-read
                           (format "%s%s (%s) "
                                   (if asked "Type a choice in full: " "")
                                   prompt (string-join choices ", "))
                           choices nil nil)
                   asked t)
             (not (or (string-empty-p answer) (member answer choices)))))
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
       `(("Open Link" . ,(lambda () (ladybird--follow-link link)))
         ("Open Link in New Buffer" . ,(lambda () (ladybird--follow-link link t)))
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

(defun ladybird-unload-function ()
  "Undo what ladybird set up outside its buffers, for `unload-feature'.
Pages are closed, connections and timers ended, and hooks, keymaps and
mouse tracking put back."
  (mapc #'kill-buffer (ladybird--buffers))
  (mapc #'ladybird--disconnect ladybird--conns)
  (ladybird--hint-stop)
  (dolist (entry '((post-command-hook . ladybird--after-command)
                   (window-buffer-change-functions . ladybird--window-buffer-changed)
                   (delete-frame-functions . ladybird--schedule-update)
                   (pre-command-hook . ladybird--hint-pre-command)
                   (minibuffer-setup-hook . ladybird--hint-minibuffer)))
    (remove-hook (car entry) (cdr entry)))
  (remove-function after-focus-change-function #'ladybird--focus-changed)
  (setq emulation-mode-map-alists
        (delq 'ladybird--hint-map-alist emulation-mode-map-alists))
  (dolist (entry ladybird--special-events)
    (define-key special-event-map (vector (car entry)) (cdr entry)))
  (setq ladybird--special-events nil)
  (when ladybird--saved-tracking
    (setq track-mouse (nth 0 ladybird--saved-tracking)
          mouse-fine-grained-tracking (nth 1 ladybird--saved-tracking)
          ladybird--saved-tracking nil))
  (dolist (timer (append timer-list timer-idle-list))
    (let ((function (timer--function timer)))
      (when (and (symbolp function)
                 (string-prefix-p "ladybird-" (symbol-name function)))
        (cancel-timer timer))))
  ;; Go on with the standard unloading.
  nil)

(provide 'ladybird)

;;; ladybird.el ends here
