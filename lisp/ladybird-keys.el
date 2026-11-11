;;; ladybird-keys.el --- Event translation for ladybird -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ladybird
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Pure functions that turn Emacs input events into the fields of the
;; ladybird protocol's `key', `text' and `mouse' messages, and CSS cursor
;; names into Emacs pointer shapes.  Key names are the enumerator names of
;; Ladybird's `Web::UIEvents::KeyCode' without the `Key_' prefix.

;;; Code:

(require 'seq)

(defvar mouse-wheel-flip-direction)

(defconst ladybird-keys-shift 1 "Modifier bit of the shift key.")
(defconst ladybird-keys-ctrl 2 "Modifier bit of the control key.")
(defconst ladybird-keys-alt 4 "Modifier bit of the alt, option or meta key.")
(defconst ladybird-keys-super 8 "Modifier bit of the super or command key.")
(defconst ladybird-keys-keypad 16 "Modifier bit of a numeric keypad key.")

(defconst ladybird-keys--punctuation
  '((?\) . "RightParen") (?! . "ExclamationPoint") (?@ . "AtSign")
    (?# . "Hashtag") (?$ . "Dollar") (?% . "Percent") (?^ . "Circumflex")
    (?& . "Ampersand") (?* . "Asterisk") (?\( . "LeftParen") (?+ . "Plus")
    (?- . "Minus") (?/ . "Slash") (?, . "Comma") (?. . "Period")
    (?: . "Colon") (?\" . "DoubleQuote") (?' . "Apostrophe")
    (?\; . "Semicolon") (?< . "LessThan") (?= . "Equal")
    (?> . "GreaterThan") (?? . "QuestionMark") (?\[ . "LeftBracket")
    (?\] . "RightBracket") (?\\ . "Backslash") (?_ . "Underscore")
    (?{ . "LeftBrace") (?} . "RightBrace") (?| . "Pipe") (?~ . "Tilde")
    (?` . "Backtick") (?\s . "Space"))
  "Alist of ASCII punctuation characters and their key names.")

(defconst ladybird-keys--symbols
  '((return "Return" 10) (kp-enter "Return" 10) (tab "Tab" 9)
    (backtab "Tab" 9) (backspace "Backspace" 8) (delete "Delete" 127)
    (deletechar "Delete" 127) (escape "Escape" 27)
    (left "Left" 0) (right "Right" 0) (up "Up" 0) (down "Down" 0)
    (home "Home" 0) (end "End" 0) (prior "PageUp" 0) (next "PageDown" 0)
    (insert "Insert" 0) (print "PrintScreen" 0) (pause "PauseBreak" 0)
    (menu "Menu" 0) (capslock "CapsLock" 0) (scroll "ScrollLock" 0)
    (f1 "F1" 0) (f2 "F2" 0) (f3 "F3" 0) (f4 "F4" 0) (f5 "F5" 0) (f6 "F6" 0)
    (f7 "F7" 0) (f8 "F8" 0) (f9 "F9" 0) (f10 "F10" 0) (f11 "F11" 0)
    (f12 "F12" 0)
    (kp-0 "0" ?0) (kp-1 "1" ?1) (kp-2 "2" ?2) (kp-3 "3" ?3) (kp-4 "4" ?4)
    (kp-5 "5" ?5) (kp-6 "6" ?6) (kp-7 "7" ?7) (kp-8 "8" ?8) (kp-9 "9" ?9)
    (kp-add "Plus" ?+) (kp-subtract "Minus" ?-) (kp-multiply "Asterisk" ?*)
    (kp-divide "Slash" ?/) (kp-decimal "Period" ?.) (kp-equal "Equal" ?=)
    (kp-space "Space" ?\s) (kp-tab "Tab" 9)
    (kp-left "Left" 0) (kp-right "Right" 0) (kp-up "Up" 0)
    (kp-down "Down" 0) (kp-home "Home" 0) (kp-end "End" 0)
    (kp-prior "PageUp" 0) (kp-next "PageDown" 0) (kp-insert "Insert" 0)
    (kp-delete "Delete" 127))
  "Alist of function key symbols: (SYMBOL KEY-NAME CODE-POINT).")

(defconst ladybird-keys--buttons
  '((mouse-1 . "left") (mouse-2 . "middle") (mouse-3 . "right")
    (mouse-8 . "back") (mouse-9 . "forward"))
  "Alist of Emacs mouse button symbols and protocol button names.")

(defconst ladybird-keys--pointers
  '(("default" . arrow) ("auto" . arrow) ("pointer" . hand)
    ("text" . text) ("vertical-text" . text)
    ("wait" . hourglass) ("progress" . hourglass)
    ("ew-resize" . hdrag) ("col-resize" . hdrag) ("e-resize" . hdrag)
    ("w-resize" . hdrag)
    ("ns-resize" . nhdrag) ("row-resize" . nhdrag) ("n-resize" . nhdrag)
    ("s-resize" . nhdrag)
    ("move" . vdrag) ("all-scroll" . vdrag) ("grab" . vdrag)
    ("grabbing" . vdrag))
  "Alist of CSS cursor names and Emacs pointer shapes.")

(defun ladybird-keys--basic-type (event)
  "Return the base key or button of EVENT without its modifiers.
Unlike `event-basic-type' this parses a symbol Emacs has not seen as
an event."
  (let ((type (if (consp event) (car event) event)))
    (if (symbolp type)
        (car (internal-event-symbol-parse-modifiers type))
      (event-basic-type type))))

(defun ladybird-keys-modifiers (modifiers)
  "Return the protocol modifier bitmask of the event MODIFIERS list.
MODIFIERS is what `event-modifiers' returns."
  (logior (if (memq 'shift modifiers) ladybird-keys-shift 0)
          (if (memq 'control modifiers) ladybird-keys-ctrl 0)
          (if (or (memq 'meta modifiers) (memq 'alt modifiers))
              ladybird-keys-alt
            0)
          (if (memq 'super modifiers) ladybird-keys-super 0)))

(defun ladybird-keys-button (event)
  "Return the protocol button name of the mouse EVENT, or nil."
  (cdr (assq (ladybird-keys--basic-type event) ladybird-keys--buttons)))

(defun ladybird-keys-pointer (cursor)
  "Return the Emacs pointer shape for the CSS CURSOR name."
  (or (cdr (assoc cursor ladybird-keys--pointers)) 'arrow))

(defun ladybird-keys-wheel-delta (event line-height)
  "Return (DX . DY) in pixels for the wheel EVENT.
Positive DY scrolls the content down and positive DX scrolls it right.
An EVENT without pixel deltas moves LINE-HEIGHT pixels per line."
  (let ((type (ladybird-keys--basic-type event))
        (pixels (nth 4 event)))
    (if (and (consp pixels) (numberp (car pixels)) (numberp (cdr pixels)))
        (cons (- (round (car pixels))) (- (round (cdr pixels))))
      (let ((amount (* (let ((lines (nth 3 event)))
                         (if (and (integerp lines) (> lines 0)) lines 3))
                       line-height))
            (flip (bound-and-true-p mouse-wheel-flip-direction)))
        (pcase type
          ((or 'wheel-up 'mouse-4) (cons 0 (- amount)))
          ((or 'wheel-down 'mouse-5) (cons 0 amount))
          ((or 'wheel-left 'mouse-6) (cons (if flip amount (- amount)) 0))
          ((or 'wheel-right 'mouse-7) (cons (if flip (- amount) amount) 0))
          (_ (cons 0 0)))))))

(defun ladybird-keys-event (event &optional meta)
  "Translate the key EVENT for the page.
Return (KEY CODE-POINT MODIFIERS) for a `key' message, (text STRING)
for a `text' message, or nil when EVENT has no counterpart.  Non-nil
META adds the alt modifier."
  (let* ((base (ladybird-keys--basic-type event))
         (mods (event-modifiers event))
         (mods (if meta (cons 'meta mods) mods))
         (c0 (cdr (assq event '((?\r . return) (?\t . tab) (?\e . escape)))))
         (mods (if c0 (remq 'control mods) mods))
         (base (cond (c0 c0)
                     ((eql base 127) 'backspace)
                     (t base)))
         (mods (if (eq base 'backtab) (cons 'shift mods) mods))
         (chord (or (memq 'control mods) (memq 'meta mods)
                    (memq 'alt mods) (memq 'super mods))))
    (cond
     ((symbolp base)
      (when-let* ((entry (cdr (assq base ladybird-keys--symbols))))
        (list (car entry) (cadr entry)
              (logior (ladybird-keys-modifiers mods)
                      (if (string-prefix-p "kp-" (symbol-name base))
                          ladybird-keys-keypad
                        0)))))
     ((not (integerp base)) nil)
     ((<= ?a base ?z)
      (if (and (characterp event) (not chord))
          ;; A shifted letter arrives as the upper case character.
          (list (string (upcase base)) event
                (if (= event base) 0 ladybird-keys-shift))
        (list (string (upcase base)) base (ladybird-keys-modifiers mods))))
     ((<= ?0 base ?9)
      (list (string base) base (ladybird-keys-modifiers mods)))
     ((assq base ladybird-keys--punctuation)
      (list (cdr (assq base ladybird-keys--punctuation)) base
            (ladybird-keys-modifiers mods)))
     ((and (characterp base) (>= base 128) (not chord))
      (list 'text (string (if (characterp event) event base))))
     (t nil))))

(defconst ladybird-keys--editing
  (let ((line-start '(("Home" 0 0)))
        (line-end '(("End" 0 0)))
        (word-left '((("Left" 0 2)) (("Left" 0 4))))
        (word-right '((("Right" 0 2)) (("Right" 0 4))))
        (word-delete '((("Delete" 127 2)) (("Delete" 127 4))))
        (word-rubout '((("Backspace" 8 2)) (("Backspace" 8 4))))
        (undo '((edit "undo")))
        (redo '((edit "redo"))))
    `(("C-a" ,line-start)
      ("C-e" ,line-end)
      ("C-b" (("Left" 0 0)))
      ("C-f" (("Right" 0 0)))
      ("C-p" (("Up" 0 0)))
      ("C-n" (("Down" 0 0)))
      ("C-v" (("PageDown" 0 0)))
      ("M-v" (("PageUp" 0 0)))
      ;; The start and the end of a text field, or the top and the bottom
      ;; of the page.
      ("M-<" (("Home" 0 2)) (("Up" 0 8)))
      ("M->" (("End" 0 2)) (("Down" 0 8)))
      ("C-d" (("Delete" 127 0)))
      ;; Select to the end of the line and delete; at the end of a line
      ;; nothing is selected and the line break goes.
      ("C-k" (("End" 0 1) ("Delete" 127 0)))
      ("M-b" ,@word-left)
      ("M-f" ,@word-right)
      ("M-d" ,@word-delete)
      ("M-DEL" ,@word-rubout)
      ("M-<backspace>" ,@word-rubout)
      ("C-<backspace>" ,@word-rubout)
      ("C-z" ,undo)
      ("C-/" ,undo)
      ("C-_" ,undo)
      ("C-?" ,redo)
      ("C-M-_" ,redo)
      ("C-S-z" ,redo)))
  "Emacs editing and motion keys and what the page is sent for them.
A list of (KEY ACTIONS [MACOS-ACTIONS]).  KEY is a string for
`key-parse'.  An action is a key spec (KEY-NAME CODE-POINT MODIFIERS)
or (edit OP) for the protocol's `edit' message.  MACOS-ACTIONS apply to
a server on macOS, where words are moved over and deleted with the alt
key and the ends of a field or the page are reached with the command
key, and elsewhere with the control key.")

(defun ladybird-keys-editing (event platform)
  "Return what the page is sent for the Emacs editing or motion key EVENT.
PLATFORM is the server's platform, the symbol `macos' or anything
else.  The value is a list of key specs (KEY CODE-POINT MODIFIERS) and
of (edit OP) for an `edit' message, or nil if EVENT is not in the
table."
  (when-let* ((entry (seq-find (lambda (entry)
                                 (equal (aref (key-parse (car entry)) 0) event))
                               ladybird-keys--editing)))
    (or (and (eq platform 'macos) (nth 2 entry))
        (nth 1 entry))))

(provide 'ladybird-keys)

;;; ladybird-keys.el ends here
