;;; ladybird-test-helpers.el --- Helpers for the ladybird module tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Loads the native module and provides what its ERT tests share: reading
;; the stream fixtures of test/fixtures/ and their JSON descriptions,
;; building records, and computing expected pixels with the formula of
;; plans/05-tooling-and-integration.md section 2.
;;
;; The environment variable LADYBIRD_MODULE_DIR names the directory of the
;; module to test; it has to be one built with -Dtest-helpers=true for the
;; shared memory tests to run.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'ladybird-module-load)

(declare-function ladybird-module-feed "ladybird-module")
(declare-function ladybird-module-create-session "ladybird-module")
(declare-function ladybird-module-close "ladybird-module")
(declare-function ladybird-module-canvas-row "ladybird-module")
(declare-function ladybird-module-canvas-pixel "ladybird-module")

(defconst ladybird-test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of the test files.")

(defconst ladybird-test-fixture-directory
  (expand-file-name "fixtures/" ladybird-test-directory)
  "Directory of the stream fixtures.")

(when-let* ((dir (getenv "LADYBIRD_MODULE_DIR")))
  (setq ladybird-module-directory (expand-file-name dir)))
(unless (ladybird-load-module)
  (error "The ladybird native module is not available"))

(defun ladybird-test-fixture-bytes (name)
  "Return the stream fixture NAME as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally
     (expand-file-name (concat name ".ladybird") ladybird-test-fixture-directory))
    (buffer-string)))

(defun ladybird-test-fixture-info (name)
  "Return the description of fixture NAME as an alist.
Its keys are `records', `desync' and `final'; JSON arrays are lists and
null and false are nil."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat name ".json") ladybird-test-fixture-directory))
    (json-parse-buffer :object-type 'alist :array-type 'list
                       :null-object nil :false-object nil)))

(defun ladybird-test-frame-records (info)
  "Return the frame records of the fixture description INFO."
  (seq-filter (lambda (record) (equal (alist-get 'kind record) "frame"))
              (alist-get 'records info)))

(defun ladybird-test-chunks (bytes size)
  "Split the string BYTES into a list of strings of at most SIZE bytes."
  (let ((chunks nil)
        (position 0)
        (length (length bytes)))
    (while (< position length)
      (push (substring bytes position (min length (+ position size))) chunks)
      (setq position (+ position size)))
    (nreverse chunks)))

(defun ladybird-test-drain (session bytes &optional no-refresh)
  "Feed BYTES to SESSION and return the events of every complete record.
A feed stops after a control record with bytes buffered behind it, so
this feeds the empty string until nothing more comes back.  NO-REFRESH
is passed on."
  (let ((events (ladybird-module-feed session bytes no-refresh))
        more)
    (while (setq more (ladybird-module-feed session "" no-refresh))
      (setq events (nconc events more)))
    events))

(defun ladybird-test-feed (session bytes &optional chunk-size no-refresh)
  "Feed BYTES to SESSION in chunks of CHUNK-SIZE and return all events.
A nil CHUNK-SIZE feeds BYTES in one call.  NO-REFRESH is passed on."
  (mapcan (lambda (chunk) (ladybird-test-drain session chunk no-refresh))
          (if chunk-size (ladybird-test-chunks bytes chunk-size) (list bytes))))

(defun ladybird-test-frame-events (events)
  "Return the frame events among EVENTS."
  (seq-filter (lambda (event) (eq (car-safe event) 'frame)) events))

(defun ladybird-test-statuses (events)
  "Return the statuses of the frame events among EVENTS."
  (mapcar (lambda (event) (nth 11 event)) (ladybird-test-frame-events events)))

(defun ladybird-test-make-canvas (width height)
  "Return a new canvas image spec of WIDTH by HEIGHT pixels."
  (list 'image :type 'canvas :id (gensym "ladybird-test-")
        :data-width width :data-height height))

(defmacro ladybird-test-with-session (var &rest body)
  "Run BODY with VAR bound to a new session that is closed afterwards."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (ladybird-module-create-session)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (ladybird-module-close ,var)))))

(defun ladybird-test-formula (x y seed frame-width frame-height)
  "Return the ARGB value of pixel (X, Y) of the synthetic frame with SEED.
FRAME-WIDTH and FRAME-HEIGHT are the size of the whole frame."
  (logior #xFF000000
          (ash (/ (* x 255) (max (1- frame-width) 1)) 16)
          (ash (/ (* y 255) (max (1- frame-height) 1)) 8)
          (logand (+ (* seed 37) (logxor x y)) #xFF)))

(defun ladybird-test-expected-pixel (records frame-width frame-height x y)
  "Return the pixel (X, Y) a client holds after the frame RECORDS.
RECORDS are frame records of a fixture description.  Only records of
FRAME-WIDTH by FRAME-HEIGHT whose status says they were decoded count;
a pixel none of them covers is 0."
  (let ((pixel 0))
    (dolist (record records)
      (let-alist record
        (when (and (eql .frame_width frame-width)
                   (eql .frame_height frame-height)
                   (member .status '("painted" "stored" "size-mismatch"))
                   (<= .x x) (< x (+ .x .width))
                   (<= .y y) (< y (+ .y .height)))
          (setq pixel (ladybird-test-formula x y .seed frame-width frame-height)))))
    pixel))

(defun ladybird-test-pixel-bytes (pixels)
  "Return the list of ARGB integers PIXELS as little-endian bytes."
  (apply #'unibyte-string
         (mapcan (lambda (pixel)
                   (list (logand pixel #xFF)
                         (logand (ash pixel -8) #xFF)
                         (logand (ash pixel -16) #xFF)
                         (logand (ash pixel -24) #xFF)))
                 pixels)))

(defun ladybird-test-expected-row (records frame-width frame-height y)
  "Return row Y a client holds after the frame RECORDS, as a byte string.
RECORDS, FRAME-WIDTH and FRAME-HEIGHT are as for
`ladybird-test-expected-pixel'.  The bytes are little-endian ARGB32 pixels."
  (ladybird-test-pixel-bytes
   (cl-loop for x below frame-width
            collect (ladybird-test-expected-pixel
                     records frame-width frame-height x y))))

(defun ladybird-test-canvas-matches-p (canvas records &optional rows)
  "Return non-nil if CANVAS shows what the frame RECORDS compose.
CANVAS is a canvas image spec; its size selects the records that count.
ROWS is the list of rows to compare, by default all of them."
  (let ((width (plist-get (cdr canvas) :data-width))
        (height (plist-get (cdr canvas) :data-height)))
    (cl-loop for y in (or rows (number-sequence 0 (1- height)))
             always (equal (ladybird-module-canvas-row canvas y)
                           (ladybird-test-expected-row records width height y)))))

(defun ladybird-test-u32 (n)
  "Return N as four little-endian bytes."
  (ladybird-test-pixel-bytes (list n)))

(defun ladybird-test-record (kind payload)
  "Return a stream record of KIND (1 control, 2 frame) with unibyte PAYLOAD."
  (concat (ladybird-test-u32 (1+ (length payload))) (unibyte-string kind) payload))

(cl-defun ladybird-test-frame-record (&key (seq 1) (view 1) width height
                                         (x 0) (y 0) (w width) (h height)
                                         (encoding 0) (flags 0) (seed 0) body)
  "Return a frame record for a WIDTH by HEIGHT frame.
The damage rectangle X, Y, W, H defaults to the whole frame.  SEQ, VIEW,
ENCODING and FLAGS fill the header.  BODY defaults to the raw formula
pixels of the rectangle for SEED."
  (ladybird-test-record
   2 (concat
      (mapconcat #'ladybird-test-u32 (list seq view width height) "")
      (unibyte-string 0 0 0 0 0 0 #xF0 #x3F) ; dpr 1.0
      (mapconcat #'ladybird-test-u32 (list x y w h) "")
      (unibyte-string encoding flags 0 0)
      (or body
          (ladybird-test-pixel-bytes
           (cl-loop for py from y below (+ y h)
                    nconc (cl-loop for px from x below (+ x w)
                                   collect (ladybird-test-formula
                                            px py seed width height))))))))

(provide 'ladybird-test-helpers)
;;; ladybird-test-helpers.el ends here
