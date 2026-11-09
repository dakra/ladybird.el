;;; ladybird-fake-module.el --- Elisp stand-in for ladybird-module -*- lexical-binding: t; -*-

;;; Commentary:

;; Implements the Lisp API of the native module (plans/03-emacs-module.md
;; section 2) in Emacs Lisp, so the package can be tested without the
;; module.  It parses records, validates frame headers, keeps a backing
;; store per view and "paints" into a pixel string kept per canvas spec.
;; Raw frames are decoded; zstd frames are decoded with the `zstd'
;; program when there is one; shm frames carry no pixels and count as
;; mapped only while `ladybird-fake-module-shm-size' is set.
;;
;; `ladybird-fake-module-frames' counts frame records,
;; `ladybird-fake-module-refreshes' counts canvas refreshes.

;;; Code:

(require 'cl-lib)

(define-error 'ladybird-module-error "Ladybird module error")

(defconst ladybird-fake-module--max-record (* 64 1024 1024))
(defconst ladybird-fake-module--max-dimension 16384)
(defconst ladybird-fake-module--max-frame-bytes (* 256 1024 1024))

(defvar ladybird-fake-module-frames 0
  "Number of frame records the fake module has consumed.")

(defvar ladybird-fake-module-refreshes 0
  "Number of canvas refreshes the fake module has done.")

(defvar ladybird-fake-module-shm-size nil
  "Size `ladybird-module-set-shm' reports for a segment.
With nil no segment can be mapped and the function signals an error.")

(defvar ladybird-fake-module--canvases (make-hash-table :test #'eq :weakness 'key)
  "Pixel strings of the canvas specs painted so far.")

(cl-defstruct (ladybird-fake-module--session
               (:constructor ladybird-fake-module--make-session)
               (:copier nil))
  chunks (have 0) (need 5) (offset 0) (state 'ok)
  (views (make-hash-table))
  (records 0) (control 0) (frames 0) (painted 0) (dropped 0) (bytes 0)
  dirty)

(cl-defstruct (ladybird-fake-module--view
               (:constructor ladybird-fake-module--make-view)
               (:copier nil))
  width height pixels canvas shm)

(defun ladybird-fake-module--u32 (string position)
  "Return the little-endian u32 of STRING at POSITION."
  (logior (aref string position)
          (ash (aref string (+ position 1)) 8)
          (ash (aref string (+ position 2)) 16)
          (ash (aref string (+ position 3)) 24)))

(defun ladybird-fake-module--u64 (string position)
  "Return the little-endian u64 of STRING at POSITION."
  (logior (ladybird-fake-module--u32 string position)
          (ash (ladybird-fake-module--u32 string (+ position 4)) 32)))

(defun ladybird-fake-module--f64 (string position)
  "Return the little-endian IEEE 754 double of STRING at POSITION."
  (let* ((bits (ladybird-fake-module--u64 string position))
         (sign (if (zerop (ash bits -63)) 1.0 -1.0))
         (exponent (logand (ash bits -52) #x7ff))
         (fraction (logand bits (1- (ash 1 52)))))
    (cond ((and (zerop exponent) (zerop fraction)) (* sign 0.0))
          ((zerop exponent) (* sign (ldexp (float fraction) -1074)))
          (t (* sign (ldexp (float (logior fraction (ash 1 52)))
                            (- exponent 1075)))))))

(defun ladybird-fake-module--live (session)
  "Signal an error unless SESSION is an open session."
  (unless (and (ladybird-fake-module--session-p session)
               (not (eq (ladybird-fake-module--session-state session) 'closed)))
    (signal 'ladybird-module-error (list "session is closed"))))

(defun ladybird-fake-module--view (session view &optional create)
  "Return SESSION's state of VIEW, making it when CREATE is non-nil."
  (let ((views (ladybird-fake-module--session-views session)))
    (or (gethash view views)
        (and create (puthash view (ladybird-fake-module--make-view) views)))))

(defun ladybird-fake-module--canvas-size (canvas)
  "Return (WIDTH . HEIGHT) of the CANVAS spec."
  (cons (plist-get (cdr canvas) :data-width)
        (plist-get (cdr canvas) :data-height)))

(defun ladybird-fake-module--canvas-pixels (canvas)
  "Return the pixel string of CANVAS, allocating it at the spec's size."
  (let* ((size (ladybird-fake-module--canvas-size canvas))
         (bytes (* 4 (car size) (cdr size)))
         (pixels (gethash canvas ladybird-fake-module--canvases)))
    (if (and pixels (= (length pixels) bytes))
        pixels
      (puthash canvas (make-string bytes 0) ladybird-fake-module--canvases))))

(defun ladybird-fake-module--copy-rect (from to width x y w h)
  "Copy the W x H rectangle at X, Y between pixel strings FROM and TO.
Both hold rows of WIDTH pixels."
  (dotimes (row h)
    (let ((start (* 4 (+ (* (+ y row) width) x))))
      (store-substring to start (substring from start (+ start (* 4 w)))))))

(defun ladybird-fake-module--unzstd (data size)
  "Return DATA decompressed with the zstd program, or nil.
The result must be SIZE bytes long."
  (when-let* ((program (executable-find "zstd")))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert data)
      (let ((coding-system-for-read 'binary)
            (coding-system-for-write 'binary))
        (and (eql 0 (ignore-errors
                      (call-process-region (point-min) (point-max) program
                                           t t nil "-d" "-q" "-c")))
             (= (buffer-size) size)
             (buffer-string))))))

(defun ladybird-fake-module--frame (session payload)
  "Consume the frame record PAYLOAD in SESSION and return its event."
  (cl-incf ladybird-fake-module-frames)
  (cl-incf (ladybird-fake-module--session-frames session))
  (if (< (length payload) 44)
      (progn (cl-incf (ladybird-fake-module--session-dropped session))
             (list 'frame nil nil nil nil nil nil nil nil nil nil 'bad-frame))
    (let* ((u32 (lambda (n) (ladybird-fake-module--u32 payload n)))
           (seq (funcall u32 0)) (view (funcall u32 4))
           (fw (funcall u32 8)) (fh (funcall u32 12))
           (dpr (ladybird-fake-module--f64 payload 16))
           (dx (funcall u32 24)) (dy (funcall u32 28))
           (dw (funcall u32 32)) (dh (funcall u32 36))
           (encoding (aref payload 40))
           (full (/= 0 (logand (aref payload 41) 1)))
           (body (- (length payload) 44))
           (state (ladybird-fake-module--view session view))
           (status
            (cond
             ((null state) 'unknown-view)
             ((not (and (<= 1 fw ladybird-fake-module--max-dimension)
                        (<= 1 fh ladybird-fake-module--max-dimension)
                        (<= (* fw fh 4) ladybird-fake-module--max-frame-bytes)
                        (>= dw 1) (>= dh 1)
                        (<= (+ dx dw) fw) (<= (+ dy dh) fh)
                        (pcase encoding
                          (0 (= body (* dw dh 4)))
                          (1 t)
                          (2 (= body 8)))))
              'bad-frame)
             (t (ladybird-fake-module--decode
                 session view fw fh dx dy dw dh encoding full
                 (substring payload 44))))))
      (if (eq status 'painted)
          (cl-incf (ladybird-fake-module--session-painted session))
        (unless (memq status '(stored size-mismatch canvas-error))
          (cl-incf (ladybird-fake-module--session-dropped session))))
      (list 'frame view seq fw fh dpr dx dy dw dh full status))))

(defun ladybird-fake-module--decode (session view fw fh dx dy dw dh encoding
                                           full body)
  "Apply a valid frame to SESSION's store of VIEW and return its status.
The frame is FW x FH with damage DX DY DW DH, ENCODING, the FULL flag
and the payload BODY.  A frame that cannot be decoded leaves the store
as it was."
  (let* ((state (ladybird-fake-module--view session view))
         (same (and (eql (ladybird-fake-module--view-width state) fw)
                    (eql (ladybird-fake-module--view-height state) fh)))
         (pixels (pcase encoding
                   (0 body)
                   (1 (ladybird-fake-module--unzstd body (* dw dh 4)))
                   (2 (let ((size (ladybird-fake-module--view-shm state)))
                        (and size
                             (<= (+ (ladybird-fake-module--u64 body 0) (* fw fh 4))
                                 size)
                             'unchanged))))))
    (cond
     ((null pixels) (if (= encoding 1) 'decode-error 'shm-error))
     ((and (not same) (not full)) 'stale)
     (t
      (unless same
        (setf (ladybird-fake-module--view-width state) fw
              (ladybird-fake-module--view-height state) fh
              (ladybird-fake-module--view-pixels state) (make-string (* fw fh 4) 0)))
      (let ((store (ladybird-fake-module--view-pixels state))
            (canvas (ladybird-fake-module--view-canvas state)))
        (cond
         ((not (stringp pixels)))
         ((and (= dw fw) (= dh fh))
          (setq store (copy-sequence pixels))
          (setf (ladybird-fake-module--view-pixels state) store))
         (t (dotimes (row dh)
              (store-substring store (* 4 (+ (* (+ dy row) fw) dx))
                               (substring pixels (* row dw 4)
                                          (* (1+ row) dw 4))))))
        (cond
         ((null canvas) 'stored)
         ((not (and (eq (car-safe canvas) 'image)
                    (natnump (car (ladybird-fake-module--canvas-size canvas)))
                    (natnump (cdr (ladybird-fake-module--canvas-size canvas)))))
          'canvas-error)
         ((not (equal (ladybird-fake-module--canvas-size canvas) (cons fw fh)))
          'size-mismatch)
         (t (ladybird-fake-module--copy-rect
             store (ladybird-fake-module--canvas-pixels canvas) fw dx dy dw dh)
            (cl-pushnew view (ladybird-fake-module--session-dirty session))
            'painted)))))))

(defun ladybird-fake-module--take (session)
  "Return SESSION's buffered bytes as one string."
  (let ((chunks (ladybird-fake-module--session-chunks session)))
    (if (cdr chunks)
        (let ((all (apply #'concat (reverse chunks))))
          (setf (ladybird-fake-module--session-chunks session) (list all))
          all)
      (or (car chunks) ""))))

(defun ladybird-module-version ()
  "Return the version of the fake module."
  "0.0.0-fake")

(defun ladybird-module-create-session ()
  "Return a new session."
  (ladybird-fake-module--make-session))

(defun ladybird-module-close (session)
  "Close SESSION; later calls on it signal an error."
  (ladybird-fake-module--live session)
  (setf (ladybird-fake-module--session-state session) 'closed
        (ladybird-fake-module--session-chunks session) nil)
  (clrhash (ladybird-fake-module--session-views session))
  nil)

(defun ladybird-module-feed (session bytes &optional no-refresh)
  "Append the unibyte string BYTES to SESSION's stream and return events.
Complete records are consumed up to and including the first control
record that has bytes buffered behind it; feeding the empty string
until the result is nil consumes the rest.  An event is a control
record's JSON text, a list (frame VIEW SEQ FRAME-W FRAME-H DPR DX DY DW
DH FULL STATUS), or (desync REASON OFFSET) as the last element.
Non-nil NO-REFRESH leaves painted canvases unrefreshed."
  (ladybird-fake-module--live session)
  (when (multibyte-string-p bytes)
    (signal 'ladybird-module-error
            (list "chunk must be unibyte; use :coding 'binary")))
  (when (eq (ladybird-fake-module--session-state session) 'ok)
    (cl-incf (ladybird-fake-module--session-bytes session) (length bytes))
    (push bytes (ladybird-fake-module--session-chunks session))
    (cl-incf (ladybird-fake-module--session-have session) (length bytes))
    (let (events done)
      (while (not done)
        (let ((have (ladybird-fake-module--session-have session)))
          (if (< have (ladybird-fake-module--session-need session))
              (setq done t)
            (let* ((data (ladybird-fake-module--take session))
                   (length (ladybird-fake-module--u32 data 0))
                   (kind (aref data 4))
                   (reason (cond ((< length 1) 'bad-length)
                                 ((> length ladybird-fake-module--max-record)
                                  'oversize)
                                 ((not (memq kind '(1 2))) 'bad-kind))))
              (cond
               (reason
                (push (list 'desync reason
                            (ladybird-fake-module--session-offset session))
                      events)
                (setf (ladybird-fake-module--session-state session) 'desynced
                      (ladybird-fake-module--session-chunks session) nil
                      (ladybird-fake-module--session-have session) 0
                      (ladybird-fake-module--session-need session) 5)
                (setq done t))
               ((< have (+ 4 length))
                (setf (ladybird-fake-module--session-need session) (+ 4 length))
                (setq done t))
               (t
                (let ((payload (substring data 5 (+ 4 length)))
                      (rest (substring data (+ 4 length))))
                  (setf (ladybird-fake-module--session-chunks session)
                        (and (> (length rest) 0) (list rest))
                        (ladybird-fake-module--session-have session) (length rest)
                        (ladybird-fake-module--session-need session) 5)
                  ;; The caller acts on a control record before the
                  ;; records after it are decoded.
                  (when (and (= kind 1) (> (length rest) 0))
                    (setq done t))
                  (cl-incf (ladybird-fake-module--session-offset session)
                           (+ 4 length))
                  (cl-incf (ladybird-fake-module--session-records session))
                  (push (if (= kind 1)
                            (progn
                              (cl-incf (ladybird-fake-module--session-control
                                        session))
                              (decode-coding-string payload 'utf-8))
                          (ladybird-fake-module--frame session payload))
                        events))))))))
      (unless no-refresh
        (cl-incf ladybird-fake-module-refreshes
                 (length (ladybird-fake-module--session-dirty session)))
        (setf (ladybird-fake-module--session-dirty session) nil))
      (nreverse events))))

(defun ladybird-module-attach-canvas (session view canvas)
  "Paint SESSION's frames of VIEW into the CANVAS image spec."
  (ladybird-fake-module--live session)
  (unless (and (eq (car-safe canvas) 'image)
               (eq (plist-get (cdr canvas) :type) 'canvas))
    (signal 'ladybird-module-error (list "Not a canvas")))
  (setf (ladybird-fake-module--view-canvas
         (ladybird-fake-module--view session view t))
        canvas)
  t)

(defun ladybird-module-detach (session view)
  "Detach the canvas of VIEW in SESSION; return t if there was one."
  (ladybird-fake-module--live session)
  (when-let* ((state (ladybird-fake-module--view session view))
              ((ladybird-fake-module--view-canvas state)))
    (setf (ladybird-fake-module--view-canvas state) nil)
    t))

(defun ladybird-module-repaint (session view)
  "Copy SESSION's whole store of VIEW into its canvas.
Return `painted', `size-mismatch', `no-canvas' or `no-frame'."
  (ladybird-fake-module--live session)
  (let* ((state (ladybird-fake-module--view session view))
         (canvas (and state (ladybird-fake-module--view-canvas state))))
    (cond
     ((null canvas) 'no-canvas)
     ((null (ladybird-fake-module--view-pixels state)) 'no-frame)
     ((not (equal (ladybird-fake-module--canvas-size canvas)
                  (cons (ladybird-fake-module--view-width state)
                        (ladybird-fake-module--view-height state))))
      'size-mismatch)
     (t (puthash canvas (copy-sequence (ladybird-fake-module--view-pixels state))
                 ladybird-fake-module--canvases)
        (cl-incf ladybird-fake-module-refreshes)
        'painted))))

(defun ladybird-module-view-size (session view)
  "Return (W . H) of SESSION's store of VIEW, or nil."
  (ladybird-fake-module--live session)
  (when-let* ((state (ladybird-fake-module--view session view))
              ((ladybird-fake-module--view-pixels state)))
    (cons (ladybird-fake-module--view-width state)
          (ladybird-fake-module--view-height state))))

(defun ladybird-module-register-view (session view)
  "Keep the frames of VIEW in SESSION from now on.
A frame for a view that is not registered is reported as
`unknown-view' and dropped."
  (ladybird-fake-module--live session)
  (ladybird-fake-module--view session view t)
  t)

(defun ladybird-module-forget-view (session view)
  "Drop everything SESSION holds for VIEW; return t if it was registered."
  (ladybird-fake-module--live session)
  (when (ladybird-fake-module--view session view)
    (remhash view (ladybird-fake-module--session-views session))
    (setf (ladybird-fake-module--session-dirty session)
          (delq view (ladybird-fake-module--session-dirty session)))
    t))

(defun ladybird-module-set-shm (session view name)
  "Map the shared memory segment NAME for VIEW in SESSION; return its size.
A nil NAME unmaps the view's segment."
  (ladybird-fake-module--live session)
  (let ((state (or (ladybird-fake-module--view session view)
                   (signal 'ladybird-module-error
                           (list (format "view %d is not registered" view))))))
    (cond
     ((null name) (setf (ladybird-fake-module--view-shm state) nil))
     (ladybird-fake-module-shm-size
      (setf (ladybird-fake-module--view-shm state)
            ladybird-fake-module-shm-size))
     (t (setf (ladybird-fake-module--view-shm state) nil)
        (signal 'ladybird-module-error
                (list (format "shm_open %s: No such file or directory"
                              name)))))))

(defun ladybird-module-reset (session)
  "Drop SESSION's buffered bytes and desync state."
  (ladybird-fake-module--live session)
  (setf (ladybird-fake-module--session-chunks session) nil
        (ladybird-fake-module--session-have session) 0
        (ladybird-fake-module--session-need session) 5
        (ladybird-fake-module--session-offset session) 0
        (ladybird-fake-module--session-state session) 'ok)
  nil)

(defun ladybird-module-stats (session)
  "Return a plist of SESSION's counters."
  (let ((views nil)
        (shm 0))
    (maphash (lambda (view state)
               (cl-incf shm (or (ladybird-fake-module--view-shm state) 0))
               (push (list view (or (ladybird-fake-module--view-width state) 0)
                           (or (ladybird-fake-module--view-height state) 0)
                           (and (ladybird-fake-module--view-canvas state) t)
                           (or (ladybird-fake-module--view-shm state) 0))
                     views))
             (ladybird-fake-module--session-views session))
    (list :state (ladybird-fake-module--session-state session)
          :bytes-in (ladybird-fake-module--session-bytes session)
          :records (ladybird-fake-module--session-records session)
          :control-records (ladybird-fake-module--session-control session)
          :frames (ladybird-fake-module--session-frames session)
          :frames-painted (ladybird-fake-module--session-painted session)
          :frames-dropped (ladybird-fake-module--session-dropped session)
          :buffered (ladybird-fake-module--session-have session)
          :dirty-views (ladybird-fake-module--session-dirty session)
          :shm-size shm
          :views views)))

(defun ladybird-module-canvas-pixel (canvas x y)
  "Return the ARGB value of the pixel at X, Y of CANVAS."
  (ladybird-fake-module--u32 (ladybird-fake-module--canvas-pixels canvas)
                           (* 4 (+ (* y (car (ladybird-fake-module--canvas-size
                                              canvas)))
                                   x))))

(defun ladybird-module-canvas-row (canvas y)
  "Return row Y of CANVAS as a unibyte string of ARGB32 pixels."
  (let ((width (car (ladybird-fake-module--canvas-size canvas))))
    (substring (ladybird-fake-module--canvas-pixels canvas)
               (* 4 y width) (* 4 (1+ y) width))))

(provide 'ladybird-fake-module)

;;; ladybird-fake-module.el ends here
