;;; ladybird-module-test.el --- Tests for the ladybird native module -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests of `ladybird-module' against the stream fixtures in
;; test/fixtures/.  They run in `emacs --batch'; see `make test-native'.

;;; Code:

(require 'ert)
(require 'ladybird-test-helpers)

(declare-function ladybird-module-version "ladybird-module")
(declare-function ladybird-module-create-session "ladybird-module")
(declare-function ladybird-module-close "ladybird-module")
(declare-function ladybird-module-feed "ladybird-module")
(declare-function ladybird-module-attach-canvas "ladybird-module")
(declare-function ladybird-module-detach "ladybird-module")
(declare-function ladybird-module-repaint "ladybird-module")
(declare-function ladybird-module-view-size "ladybird-module")
(declare-function ladybird-module-set-shm "ladybird-module")
(declare-function ladybird-module-register-view "ladybird-module")
(declare-function ladybird-module-forget-view "ladybird-module")
(declare-function ladybird-module-reset "ladybird-module")
(declare-function ladybird-module-stats "ladybird-module")
(declare-function ladybird-module-canvas-pixel "ladybird-module")
(declare-function ladybird-module-canvas-row "ladybird-module")
(declare-function ladybird-module-canvas-fill "ladybird-module")
(declare-function ladybird-module--test-shm-write "ladybird-module")
(declare-function ladybird-module--test-shm-unlink "ladybird-module")

(defvar ladybird-test--refreshes 0
  "Number of `canvas-refresh' calls seen by `ladybird-test--count-refresh'.")

(defun ladybird-test--count-refresh (&rest _)
  "Count a `canvas-refresh' call."
  (cl-incf ladybird-test--refreshes))

(defmacro ladybird-test--counting-refreshes (&rest body)
  "Run BODY with `canvas-refresh' calls counted in `ladybird-test--refreshes'."
  (declare (indent 0) (debug t))
  `(progn
     (setq ladybird-test--refreshes 0)
     (advice-add 'canvas-refresh :before #'ladybird-test--count-refresh)
     (unwind-protect
         (progn ,@body)
       (advice-remove 'canvas-refresh #'ladybird-test--count-refresh))))

(defun ladybird-test--event-fields (event)
  "Return frame EVENT without its DPR, for comparison with a description."
  (pcase-let ((`(frame ,view ,seq ,fw ,fh ,_dpr ,x ,y ,w ,h ,full ,status) event))
    (list view seq fw fh x y w h full status)))

(defun ladybird-test--record-fields (record)
  "Return the fields of the fixture frame RECORD as a frame event has them."
  (let-alist record
    (list .view .seq .frame_width .frame_height .x .y .width .height
          (and .full t) (intern .status))))

;;; Module and sessions

(ert-deftest ladybird-test-version ()
  (should (equal (ladybird-module-version) "0.2.0"))
  (should (equal (ladybird-module-version)
                 (ladybird--module-sidecar-version (ladybird--module-directory)))))

(ert-deftest ladybird-test-session-lifecycle ()
  (let ((session (ladybird-module-create-session)))
    (should (user-ptrp session))
    (let ((stats (ladybird-module-stats session)))
      (should (eq (plist-get stats :state) 'ok))
      (dolist (key '(:bytes-in :records :control-records :frames :frames-painted
                     :frames-dropped :zstd-in-bytes :zstd-out-bytes :decode-ns
                     :copy-ns :buffered :buffer-capacity :largest-record :shm-size))
        (should (eql (plist-get stats key) 0)))
      (should (plist-member stats :dirty-views))
      (should-not (plist-get stats :dirty-views))
      (should-not (plist-get stats :views)))
    (should-not (ladybird-module-close session))
    (should (eq (plist-get (ladybird-module-stats session) :state) 'closed))
    (should-error (ladybird-module-close session) :type 'ladybird-module-error)
    (should-error (ladybird-module-feed session "") :type 'ladybird-module-error)
    (should-error (ladybird-module-reset session) :type 'ladybird-module-error))
  ;; Dropped sessions, with and without a canvas, are collected.
  (dotimes (_ 20)
    (let ((session (ladybird-module-create-session)))
      (ladybird-module-attach-canvas session 1 (ladybird-test-make-canvas 4 4))
      (ladybird-module-feed session (ladybird-test-frame-record :width 4 :height 4 :flags 1))))
  (garbage-collect)
  (garbage-collect)
  (ladybird-test-with-session session
    (should (eq (plist-get (ladybird-module-stats session) :state) 'ok))))

(ert-deftest ladybird-test-argument-types ()
  (should-error (ladybird-module-stats 'not-a-session) :type 'wrong-type-argument)
  (should-error (ladybird-module-feed nil "") :type 'wrong-type-argument)
  (ladybird-test-with-session session
    (should-error (ladybird-module-feed session 42) :type 'wrong-type-argument)
    (should-error (ladybird-module-attach-canvas session 1 '(image :type png)))
    (should-error (ladybird-module-attach-canvas session "1" (ladybird-test-make-canvas 2 2))
                  :type 'wrong-type-argument)
    (should-error (ladybird-module-attach-canvas session -1 (ladybird-test-make-canvas 2 2))
                  :type 'ladybird-module-error)))

;;; Raw frames

(ert-deftest ladybird-test-raw-full ()
  (let ((bytes (ladybird-test-fixture-bytes "basic-raw-full"))
        (records (ladybird-test-frame-records (ladybird-test-fixture-info "basic-raw-full"))))
    (dolist (chunk-size '(1 7 13 4096 nil))
      (ladybird-test-with-session session
        (let* ((canvas (ladybird-test-make-canvas 64 48))
               (_ (ladybird-module-attach-canvas session 1 canvas))
               (events (ladybird-test-feed session bytes chunk-size)))
          (should (= (length events) 3))
          (should (stringp (nth 0 events)))
          (should (multibyte-string-p (nth 0 events)))
          (should (equal (alist-get 'type (json-parse-string (nth 0 events)
                                                             :object-type 'alist))
                         "welcome"))
          (should (equal (nth 1 events) '(frame 1 1 64 48 1.0 0 0 64 48 t painted)))
          (should (equal (alist-get 'title (json-parse-string (nth 2 events)
                                                              :object-type 'alist))
                         "basic"))
          (should (ladybird-test-canvas-matches-p canvas records))
          (should (= (ladybird-module-canvas-pixel canvas 0 0)
                     (ladybird-test-formula 0 0 1 64 48)))
          (should (= (ladybird-module-canvas-pixel canvas 63 47) #xFFFFFF35))
          (should (= (ladybird-module-canvas-pixel canvas 17 30)
                     (ladybird-test-formula 17 30 1 64 48)))
          (should (equal (ladybird-module-view-size session 1) '(64 . 48)))
          (let ((stats (ladybird-module-stats session)))
            (should (= (plist-get stats :bytes-in) (length bytes)))
            (should (= (plist-get stats :records) 3))
            (should (= (plist-get stats :control-records) 2))
            (should (= (plist-get stats :frames) 1))
            (should (= (plist-get stats :frames-painted) 1))
            (should (= (plist-get stats :buffered) 0))
            (should (equal (plist-get stats :views) '((1 64 48 t 0))))))))))

(ert-deftest ladybird-test-partial-record-is-buffered ()
  (let ((bytes (ladybird-test-fixture-bytes "basic-raw-full")))
    (ladybird-test-with-session session
      (should-not (ladybird-module-feed session (substring bytes 0 3)))
      (should (= (plist-get (ladybird-module-stats session) :buffered) 3))
      (should-not (ladybird-module-feed session ""))
      (should (= (length (ladybird-test-drain session (substring bytes 3))) 3))
      (should (= (plist-get (ladybird-module-stats session) :buffered) 0)))))

(ert-deftest ladybird-test-damage-mix ()
  (let* ((bytes (ladybird-test-fixture-bytes "damage-mix"))
         (records (ladybird-test-frame-records (ladybird-test-fixture-info "damage-mix"))))
    (dolist (chunk-size '(nil 4096 251))
      (ladybird-test-with-session session
        (let ((canvas (ladybird-test-make-canvas 320 200)))
          (ladybird-module-attach-canvas session 1 canvas)
          (let ((events (ladybird-test-feed session bytes chunk-size)))
            (should (equal (ladybird-test-statuses events) (make-list 7 'painted)))
            (should (equal (mapcar #'ladybird-test--event-fields events)
                           (mapcar #'ladybird-test--record-fields records))))
          (should (ladybird-test-canvas-matches-p canvas records))
          (let ((stats (ladybird-module-stats session)))
            (should (> (plist-get stats :zstd-in-bytes) 0))
            (should (= (plist-get stats :zstd-out-bytes)
                       (* 4 (+ (* 100 60) (* 320 50) 1))))))))))

(ert-deftest ladybird-test-no-canvas ()
  (let ((bytes (ladybird-test-fixture-bytes "damage-mix"))
        (records (ladybird-test-frame-records (ladybird-test-fixture-info "damage-mix"))))
    (ladybird-test-with-session session
      (should (eq (ladybird-module-repaint session 1) 'no-frame))
      (should-not (ladybird-module-view-size session 1))
      (should (eq (ladybird-module-register-view session 1) t))
      (should (equal (ladybird-test-statuses (ladybird-module-feed session bytes))
                     (make-list 7 'stored)))
      (should (equal (ladybird-module-view-size session 1) '(320 . 200)))
      (should (eq (ladybird-module-repaint session 1) 'no-canvas))
      (should (equal (plist-get (ladybird-module-stats session) :views)
                     '((1 320 200 nil 0))))
      (let ((canvas (ladybird-test-make-canvas 320 200)))
        (should (eq (ladybird-module-attach-canvas session 1 canvas) t))
        (should (= (ladybird-module-canvas-pixel canvas 5 5) 0))
        (should (eq (ladybird-module-repaint session 1) 'painted))
        (should (ladybird-test-canvas-matches-p canvas records))
        (should (eq (ladybird-module-detach session 1) t))
        (should-not (ladybird-module-detach session 1))
        (should-not (ladybird-module-detach session 99))
        (should (eq (ladybird-module-repaint session 1) 'no-canvas))))))

(ert-deftest ladybird-test-attach-before-frame ()
  (ladybird-test-with-session session
    (let ((canvas (ladybird-test-make-canvas 8 8)))
      (ladybird-module-attach-canvas session 3 canvas)
      (should (eq (ladybird-module-repaint session 3) 'no-frame))
      (should-not (ladybird-module-view-size session 3))
      (should (equal (plist-get (ladybird-module-stats session) :views) '((3 0 0 t 0)))))))

(ert-deftest ladybird-test-attach-replaces ()
  (ladybird-test-with-session session
    (let ((first (ladybird-test-make-canvas 4 4))
          (second (ladybird-test-make-canvas 4 4)))
      (ladybird-module-attach-canvas session 1 first)
      (ladybird-module-attach-canvas session 1 second)
      (ladybird-module-feed session (ladybird-test-frame-record :width 4 :height 4 :flags 1 :seed 3))
      (should (= (ladybird-module-canvas-pixel first 1 1) 0))
      (should (= (ladybird-module-canvas-pixel second 1 1)
                 (ladybird-test-formula 1 1 3 4 4))))))

(ert-deftest ladybird-test-two-views ()
  (ladybird-test-with-session session
    (let ((one (ladybird-test-make-canvas 4 4))
          (two (ladybird-test-make-canvas 6 2)))
      (ladybird-module-attach-canvas session 1 one)
      (ladybird-module-attach-canvas session 2 two)
      (let ((events (ladybird-module-feed
                     session
                     (concat (ladybird-test-frame-record :view 1 :width 4 :height 4 :flags 1 :seed 1)
                             (ladybird-test-frame-record :view 2 :width 6 :height 2 :flags 1 :seed 2)))))
        (should (equal (ladybird-test-statuses events) '(painted painted))))
      (should (= (ladybird-module-canvas-pixel one 3 3) (ladybird-test-formula 3 3 1 4 4)))
      (should (= (ladybird-module-canvas-pixel two 5 1) (ladybird-test-formula 5 1 2 6 2))))))

(ert-deftest ladybird-test-resize ()
  (let* ((bytes (ladybird-test-fixture-bytes "resize"))
         (records (ladybird-test-frame-records (ladybird-test-fixture-info "resize"))))
    (dolist (chunk-size '(nil 8192))
      (ladybird-test-with-session session
        (let ((canvas (ladybird-test-make-canvas 320 200)))
          (ladybird-module-attach-canvas session 1 canvas)
          (let ((events (ladybird-test-feed session bytes chunk-size)))
            (should (equal (ladybird-test-statuses events)
                           '(painted painted size-mismatch stale)))
            (should (equal (mapcar #'ladybird-test--event-fields events)
                           (mapcar #'ladybird-test--record-fields records))))
          ;; The canvas keeps the last frame of its own size.
          (should (ladybird-test-canvas-matches-p canvas records))
          (should (equal (ladybird-module-view-size session 1) '(400 . 300)))
          (should (eq (ladybird-module-repaint session 1) 'size-mismatch))
          (plist-put (cdr canvas) :data-width 400)
          (plist-put (cdr canvas) :data-height 300)
          (should (eq (ladybird-module-repaint session 1) 'painted))
          (should (ladybird-test-canvas-matches-p canvas records))
          (should (= (ladybird-module-canvas-pixel canvas 399 299)
                     (ladybird-test-formula 399 299 3 400 300))))))))

(ert-deftest ladybird-test-full-frame-repaints-everything ()
  ;; A full frame whose damage is smaller than the frame replaces the rest
  ;; of the canvas with zeros.
  (ladybird-test-with-session session
    (let ((canvas (ladybird-test-make-canvas 8 8)))
      (ladybird-module-attach-canvas session 1 canvas)
      (ladybird-module-feed session (ladybird-test-frame-record :width 8 :height 8 :flags 1 :seed 1))
      (plist-put (cdr canvas) :data-width 4)
      (plist-put (cdr canvas) :data-height 4)
      (ladybird-module-canvas-fill canvas #xFF112233)
      (should (equal (ladybird-test-statuses
                      (ladybird-module-feed
                       session (ladybird-test-frame-record
                                :seq 2 :width 4 :height 4 :x 1 :y 1 :w 2 :h 2
                                :flags 1 :seed 2)))
                     '(painted)))
      (should (= (ladybird-module-canvas-pixel canvas 0 0) 0))
      (should (= (ladybird-module-canvas-pixel canvas 3 3) 0))
      (should (= (ladybird-module-canvas-pixel canvas 2 1)
                 (ladybird-test-formula 2 1 2 4 4))))))

;;; Control records

(ert-deftest ladybird-test-multibyte-chunk-signals ()
  (ladybird-test-with-session session
    (let ((err (should-error (ladybird-module-feed session "héllo")
                             :type 'ladybird-module-error)))
      (should (string-match-p "unibyte" (cadr err))))
    (should (= (plist-get (ladybird-module-stats session) :bytes-in) 0))
    (should (equal (ladybird-module-feed
                    session (ladybird-test-record 1 (encode-coding-string "{\"a\":\"é\"}" 'utf-8)))
                   '("{\"a\":\"é\"}")))))

(ert-deftest ladybird-test-control-utf8 ()
  (let ((bytes (ladybird-test-fixture-bytes "control-utf8")))
    (dolist (chunk-size '(nil 65536 8192))
      (ladybird-test-with-session session
        (let* ((events (ladybird-test-feed session bytes chunk-size))
               (objects (mapcar (lambda (event)
                                  (json-parse-string event :object-type 'alist))
                                events)))
          (should (= (length events) 3))
          (should (seq-every-p #'multibyte-string-p (seq-take events 2)))
          (should (string-search "héllo wörld ✓ 日本語 🦋" (nth 0 events)))
          (should (equal (alist-get 'title (nth 0 objects)) "héllo wörld ✓ 日本語 🦋"))
          (should (equal (alist-get 'text (nth 1 objects)) (make-string (* 512 1024) ?é)))
          (should (equal (alist-get 'type (nth 2 objects)) "pong"))
          (should (= (plist-get (ladybird-module-stats session) :control-records) 3)))))))

(ert-deftest ladybird-test-control-invalid-utf8 ()
  (ladybird-test-with-session session
    (let ((events (ladybird-module-feed
                   session (ladybird-test-record 1 (unibyte-string ?a #xFF ?b)))))
      (should (equal events (list (string ?a (unibyte-char-to-multibyte #xFF) ?b)))))))

;;; Bad input

(ert-deftest ladybird-test-bad-and-desync ()
  (let* ((bytes (ladybird-test-fixture-bytes "bad"))
         (info (ladybird-test-fixture-info "bad"))
         (records (ladybird-test-frame-records info)))
    (dolist (chunk-size '(nil 5 4096))
      (ladybird-test-with-session session
        (let ((canvas (ladybird-test-make-canvas 64 48)))
          (ladybird-module-attach-canvas session 1 canvas)
          (let* ((events (ladybird-test-feed session bytes chunk-size))
                 (frames (ladybird-test-frame-events events)))
            (should (equal (ladybird-test-statuses events)
                           (append (make-list 8 'bad-frame) '(decode-error))))
            (should (equal (mapcar #'ladybird-test--event-fields frames)
                           (mapcar #'ladybird-test--record-fields records)))
            (should (= (length events) 11))
            (should (equal (alist-get 'title (json-parse-string (nth 9 events)
                                                                :object-type 'alist))
                           "after bad frames"))
            (should (equal (nth 10 events)
                           (list 'desync 'oversize
                                 (alist-get 'offset (alist-get 'desync info))))))
          (should (= (ladybird-module-canvas-pixel canvas 0 0) 0))
          (let ((stats (ladybird-module-stats session)))
            (should (eq (plist-get stats :state) 'desynced))
            (should (= (plist-get stats :frames-dropped) 9))
            (should (= (plist-get stats :buffered) 0)))
          (should-not (ladybird-module-feed session (ladybird-test-fixture-bytes "basic-raw-full")))
          (should-not (ladybird-module-reset session))
          (should (eq (plist-get (ladybird-module-stats session) :state) 'ok))
          (let ((events (ladybird-test-drain
                         session (ladybird-test-fixture-bytes "basic-raw-full"))))
            (should (equal (ladybird-test-statuses events) '(painted))))
          (should (= (ladybird-module-canvas-pixel canvas 63 47) #xFFFFFF35)))))))

(ert-deftest ladybird-test-desync-reasons ()
  (let ((good (ladybird-test-record 1 "{}")))
    (pcase-dolist (`(,bad . ,reason)
                   `((,(concat (ladybird-test-u32 0) (unibyte-string 1)) . bad-length)
                     (,(concat (ladybird-test-u32 (1+ (* 64 1024 1024))) (unibyte-string 1))
                      . oversize)
                     (,(concat (ladybird-test-u32 4) (unibyte-string 3) "abc") . bad-kind)))
      (ladybird-test-with-session session
        (should (equal (ladybird-module-feed session bad) `((desync ,reason 0)))))
      (ladybird-test-with-session session
        (should (equal (ladybird-test-drain session (concat good bad))
                       `("{}" (desync ,reason ,(length good)))))
        (should-not (ladybird-module-feed session good))))))

(ert-deftest ladybird-test-record-of-kind-only ()
  ;; LENGTH 1 is a record with an empty payload.
  (ladybird-test-with-session session
    (should (equal (ladybird-module-feed session (ladybird-test-record 1 "")) '("")))
    (should (equal (ladybird-module-feed session (ladybird-test-record 2 ""))
                   '((frame nil nil nil nil nil nil nil nil nil nil bad-frame))))))

(ert-deftest ladybird-test-feed-stops-after-control ()
  ;; A feed returns after a control record that has bytes behind it, so
  ;; the caller can act on it before the next record is decoded.
  (ladybird-test-with-session session
    (ladybird-module-register-view session 1)
    (let* ((first (ladybird-test-record 1 "{\"n\":1}"))
           (second (ladybird-test-record 1 "{\"n\":2}"))
           (frame (ladybird-test-frame-record :width 4 :height 4 :flags 1)))
      (should (equal (ladybird-module-feed session (concat frame first second frame
                                                         (substring frame 0 9)))
                     '((frame 1 1 4 4 1.0 0 0 4 4 t stored) "{\"n\":1}")))
      (should (equal (ladybird-module-feed session "") '("{\"n\":2}")))
      (should (equal (ladybird-test-statuses (ladybird-module-feed session ""))
                     '(stored)))
      (should-not (ladybird-module-feed session ""))
      (should (= (plist-get (ladybird-module-stats session) :buffered) 9))
      ;; A control record at the end of the input does not stop the feed.
      (should (equal (ladybird-module-feed session (concat (substring frame 9) first))
                     '((frame 1 1 4 4 1.0 0 0 4 4 t stored) "{\"n\":1}")))
      (should-not (ladybird-module-feed session "")))))

;;; Refresh

(ert-deftest ladybird-test-refresh-called ()
  (let ((bytes (ladybird-test-fixture-bytes "damage-mix")))
    (ladybird-test--counting-refreshes
      (ladybird-test-with-session session
        (let ((canvas (ladybird-test-make-canvas 320 200)))
          ;; Nothing painted: no canvas attached.
          (ladybird-module-feed session bytes)
          (should (= ladybird-test--refreshes 0))
          (ladybird-module-attach-canvas session 1 canvas)
          ;; Seven painted frames in one feed.
          (ladybird-module-feed session bytes)
          (should (= ladybird-test--refreshes 1))
          ;; One refresh per feed that painted.
          (dolist (chunk (ladybird-test-chunks bytes 65536))
            (ladybird-module-feed session chunk))
          (should (= ladybird-test--refreshes 4))
          ;; Control records only.
          (ladybird-test-drain session (ladybird-test-fixture-bytes "control-utf8"))
          (should (= ladybird-test--refreshes 4))
          ;; NO-REFRESH leaves the view dirty until a feed without it.
          (ladybird-module-feed session bytes t)
          (should (= ladybird-test--refreshes 4))
          (should (equal (plist-get (ladybird-module-stats session) :dirty-views) '(1)))
          (ladybird-module-feed session "")
          (should (= ladybird-test--refreshes 5))
          (should-not (plist-get (ladybird-module-stats session) :dirty-views))
          (ladybird-module-feed session "")
          (should (= ladybird-test--refreshes 5))
          ;; Repaint refreshes.
          (should (eq (ladybird-module-repaint session 1) 'painted))
          (should (= ladybird-test--refreshes 6)))))))

(ert-deftest ladybird-test-more-flag-defers-refresh ()
  (ladybird-test--counting-refreshes
    (ladybird-test-with-session session
      (let ((canvas (ladybird-test-make-canvas 8 6))
            (band (lambda (seq y flags)
                    (ladybird-test-frame-record :seq seq :width 8 :height 6
                                              :y y :h 2 :flags flags :seed 4))))
        (ladybird-module-attach-canvas session 1 canvas)
        (ladybird-module-feed session (ladybird-test-frame-record :width 8 :height 6 :flags 1))
        (setq ladybird-test--refreshes 0)
        (should (equal (ladybird-test-statuses
                        (ladybird-module-feed session (funcall band 1 0 2)))
                       '(painted)))
        (should (= ladybird-test--refreshes 0))
        (should (equal (plist-get (ladybird-module-stats session) :dirty-views) '(1)))
        ;; The state survives feeds without frames.
        (ladybird-module-feed session (ladybird-test-record 1 "{}"))
        (ladybird-module-feed session "")
        (should (= ladybird-test--refreshes 0))
        (ladybird-module-feed session (funcall band 2 2 2))
        (should (= ladybird-test--refreshes 0))
        (ladybird-module-feed session (funcall band 3 4 0))
        (should (= ladybird-test--refreshes 1))
        (should-not (plist-get (ladybird-module-stats session) :dirty-views))
        (dotimes (y 6)
          (should (= (ladybird-module-canvas-pixel canvas 7 y)
                     (ladybird-test-formula 7 y 4 8 6))))
        ;; Bands of one frame in a single feed refresh once.
        (ladybird-module-feed session (concat (funcall band 4 0 2) (funcall band 5 2 2)
                                            (funcall band 6 4 0)))
        (should (= ladybird-test--refreshes 2))
        ;; A reset ends the wait for the last band.
        (ladybird-module-feed session (funcall band 7 0 2))
        (should (= ladybird-test--refreshes 2))
        (ladybird-module-reset session)
        (ladybird-module-feed session "")
        (should (= ladybird-test--refreshes 3))))))

(ert-deftest ladybird-test-interrupted-bands ()
  ;; A server that hides or closes a view in the middle of a banded frame
  ;; sends no more bands of it: the bands that came wait unrefreshed, the
  ;; other views go on, and the view's next frame, a full one, paints and
  ;; refreshes it.
  (ladybird-test--counting-refreshes
    (ladybird-test-with-session session
      (let ((one (ladybird-test-make-canvas 8 6))
            (two (ladybird-test-make-canvas 8 6))
            (three (ladybird-test-make-canvas 8 6)))
        (ladybird-module-attach-canvas session 1 one)
        (ladybird-module-attach-canvas session 2 two)
        (ladybird-module-attach-canvas session 3 three)
        (ladybird-module-feed session
                              (concat (ladybird-test-frame-record :view 1 :width 8 :height 6
                                                                :flags 1)
                                      (ladybird-test-frame-record :view 2 :width 8 :height 6
                                                                :flags 1)
                                      (ladybird-test-frame-record :view 3 :width 8 :height 6
                                                                :flags 1)))
        (setq ladybird-test--refreshes 0)
        ;; The first band of a full frame of view 1; the rest never comes.
        (should (equal (ladybird-test-statuses
                        (ladybird-module-feed
                         session (ladybird-test-frame-record :seq 2 :view 1 :width 8
                                                           :height 6 :h 2 :flags 3
                                                           :seed 5)))
                       '(painted)))
        (should (= ladybird-test--refreshes 0))
        ;; Another view's frame comes next and is refreshed at once.
        (ladybird-module-feed session (ladybird-test-frame-record :seq 2 :view 2 :width 8
                                                                :height 6 :flags 1 :seed 6))
        (should (= ladybird-test--refreshes 1))
        (should (equal (plist-get (ladybird-module-stats session) :dirty-views) '(1)))
        (should (= (ladybird-module-canvas-pixel two 7 5) (ladybird-test-formula 7 5 6 8 6)))
        ;; View 1, shown again, sends a whole frame: it is painted and refreshed.
        (ladybird-module-feed session (ladybird-test-frame-record :seq 3 :view 1 :width 8
                                                                :height 6 :flags 1 :seed 7))
        (should (= ladybird-test--refreshes 2))
        (should-not (plist-get (ladybird-module-stats session) :dirty-views))
        (dotimes (y 6)
          (should (= (ladybird-module-canvas-pixel one 3 y) (ladybird-test-formula 3 y 7 8 6))))
        ;; A view closed in the middle of a banded frame leaves nothing waiting.
        (ladybird-module-feed session (ladybird-test-frame-record :seq 2 :view 3 :width 8
                                                                :height 6 :h 2 :flags 3))
        (ladybird-module-forget-view session 3)
        (should-not (plist-get (ladybird-module-stats session) :dirty-views))
        (should (equal (ladybird-test-statuses
                        (ladybird-module-feed session (ladybird-test-frame-record
                                                       :seq 3 :view 3 :width 8 :height 6
                                                       :y 2 :h 2)))
                       '(unknown-view)))
        (ladybird-module-feed session (ladybird-test-frame-record :seq 3 :view 2 :width 8
                                                                :height 6 :flags 1))
        (should (= ladybird-test--refreshes 3))))))

;;; zstd

(ert-deftest ladybird-test-zstd-full ()
  (let* ((bytes (ladybird-test-fixture-bytes "zstd"))
         (records (ladybird-test-frame-records (ladybird-test-fixture-info "zstd"))))
    (dolist (chunk-size '(65536 8192 nil))
      (ladybird-test-with-session session
        (let ((canvas (ladybird-test-make-canvas 1600 1000)))
          (ladybird-module-attach-canvas session 1 canvas)
          (should (equal (ladybird-test-feed session bytes chunk-size)
                         '((frame 1 1 1600 1000 1.0 0 0 1600 1000 t painted))))
          (should (ladybird-test-canvas-matches-p canvas records '(0 499 999)))
          (cl-loop for index from 0 below (* 1600 1000) by 97
                   for x = (% index 1600)
                   for y = (/ index 1600)
                   do (should (= (ladybird-module-canvas-pixel canvas x y)
                                 (ladybird-test-formula x y 7 1600 1000))))
          (let ((stats (ladybird-module-stats session)))
            (should (= (plist-get stats :zstd-out-bytes) (* 1600 1000 4)))
            (should (= (plist-get stats :zstd-in-bytes) (- (length bytes) 5 44)))
            (should (> (plist-get stats :decode-ns) 0))))))))

(ert-deftest ladybird-test-zstd-errors ()
  (let* ((bytes (ladybird-test-fixture-bytes "zstd"))
         (zstd (substring bytes 49)))
    (ladybird-test-with-session session
      (ladybird-module-register-view session 1)
      (let ((feed (lambda (&rest args)
                    (ladybird-test-statuses
                     (ladybird-module-feed
                      session (apply #'ladybird-test-frame-record
                                     :width 1600 :height 1000 :encoding 1 args))))))
        ;; A truncated body.
        (should (equal (funcall feed :flags 1 :body (substring zstd 0 (/ (length zstd) 2)))
                       '(decode-error)))
        ;; The stated content size differs from the damage rectangle.
        (should (equal (funcall feed :flags 1 :h 999 :body zstd) '(decode-error)))
        (should (equal (funcall feed :flags 1 :body "garbage") '(decode-error)))
        (should (equal (funcall feed :flags 1 :body zstd) '(stored)))
        (should (= (plist-get (ladybird-module-stats session) :frames-dropped) 3))))))

;;; Shared memory

(defun ladybird-test--shm-name ()
  "Return a shared memory name for this Emacs process."
  (format "/ladybird-t-%d" (emacs-pid)))

(ert-deftest ladybird-test-shm ()
  :tags '(posix)
  (skip-unless (fboundp 'ladybird-module--test-shm-write))
  (let* ((name (ladybird-test--shm-name))
         (bytes (ladybird-test-fixture-bytes "shm"))
         (records (ladybird-test-frame-records (ladybird-test-fixture-info "shm")))
         (pixels (ladybird-test-pixel-bytes
                  (cl-loop for y below 48
                           nconc (cl-loop for x below 64
                                          collect (ladybird-test-formula x y 5 64 48))))))
    (ignore-errors (ladybird-module--test-shm-unlink name))
    (ladybird-module--test-shm-write name 4096 pixels)
    (unwind-protect
        (ladybird-test-with-session session
          (let ((canvas (ladybird-test-make-canvas 64 48)))
            (ladybird-module-attach-canvas session 1 canvas)
            ;; Without a mapping.
            (should (equal (ladybird-test-statuses (ladybird-test-drain session bytes))
                           '(shm-error)))
            (should (>= (ladybird-module-set-shm session 1 name) (+ 4096 (length pixels))))
            (should (= (plist-get (ladybird-module-stats session) :shm-size)
                       (ladybird-module-set-shm session 1 name)))
            (let ((events (ladybird-test-drain session bytes)))
              (should (= (length events) 2))
              (should (equal (alist-get 'type (json-parse-string (car events)
                                                                 :object-type 'alist))
                             "shm"))
              (should (equal (mapcar #'ladybird-test--event-fields (cdr events))
                             (mapcar #'ladybird-test--record-fields records))))
            (should (ladybird-test-canvas-matches-p canvas records))
            ;; The announcement and its frame in one chunk: the segment is
            ;; mapped between the two feeds.
            (ladybird-module-set-shm session 1 nil)
            (ladybird-module-canvas-fill canvas 0)
            (should (stringp (car (ladybird-module-feed session bytes))))
            (should (> (plist-get (ladybird-module-stats session) :buffered) 0))
            (ladybird-module-set-shm session 1 name)
            (should (equal (ladybird-test-statuses (ladybird-module-feed session ""))
                           '(painted)))
            (should (ladybird-test-canvas-matches-p canvas records))
            ;; A damage rectangle is read at its place in the segment.
            (ladybird-module--test-shm-write
             name (+ 4096 (* 4 (+ (* 64 10) 20)))
             (ladybird-test-pixel-bytes (list #xFF010203 #xFF040506)))
            (should (equal (ladybird-test-statuses
                            (ladybird-module-feed
                             session (ladybird-test-frame-record
                                      :seq 2 :width 64 :height 48 :x 20 :y 10 :w 2 :h 1
                                      :encoding 2
                                      :body (concat (ladybird-test-u32 4096)
                                                    (ladybird-test-u32 0)))))
                           '(painted)))
            (should (= (ladybird-module-canvas-pixel canvas 20 10) #xFF010203))
            (should (= (ladybird-module-canvas-pixel canvas 21 10) #xFF040506))
            (should (= (ladybird-module-canvas-pixel canvas 22 10)
                       (ladybird-test-formula 22 10 5 64 48)))
            ;; The frame does not fit behind the offset.
            (dolist (offset (list (concat (ladybird-test-u32 8192) (ladybird-test-u32 0))
                                  (unibyte-string 0 0 0 0 0 0 0 #x80)
                                  (apply #'unibyte-string (make-list 8 #xFF))))
              (should (equal (ladybird-test-statuses
                              (ladybird-module-feed
                               session (ladybird-test-frame-record
                                        :seq 3 :width 64 :height 48 :encoding 2
                                        :body offset)))
                             '(shm-error))))
            (should-not (ladybird-module-set-shm session 1 nil))
            (should (= (plist-get (ladybird-module-stats session) :shm-size) 0))
            (should (equal (ladybird-test-statuses (ladybird-test-drain session bytes))
                           '(shm-error)))))
      (ladybird-module--test-shm-unlink name))))

(ert-deftest ladybird-test-shm-open-failure ()
  :tags '(posix)
  (ladybird-test-with-session session
    ;; A view that is not registered has no mapping.
    (let ((err (should-error (ladybird-module-set-shm session 1 "/ladybird-t-missing")
                             :type 'ladybird-module-error)))
      (should (string-match-p "view 1 is not registered" (cadr err))))
    (should-not (plist-get (ladybird-module-stats session) :views))
    (ladybird-module-register-view session 1)
    (let ((err (should-error (ladybird-module-set-shm session 1 "/ladybird-t-missing")
                             :type 'ladybird-module-error)))
      (should (string-match-p "shm_open /ladybird-t-missing: " (cadr err))))
    (should (= (plist-get (ladybird-module-stats session) :shm-size) 0))
    (should-error (ladybird-module-set-shm session 1 42) :type 'wrong-type-argument)
    (when (eq system-type 'darwin)
      (let ((err (should-error
                  (ladybird-module-set-shm session 1 (concat "/" (make-string 31 ?x)))
                  :type 'ladybird-module-error)))
        (should (string-match-p "too long" (cadr err)))))))

(ert-deftest ladybird-test-shm-per-view ()
  ;; Each view reads its frames from its own segment.
  :tags '(posix)
  (skip-unless (fboundp 'ladybird-module--test-shm-write))
  (let* ((names (list (format "/ladybird-ta-%d" (emacs-pid))
                      (format "/ladybird-tb-%d" (emacs-pid))))
         (pixels (lambda (seed)
                   (ladybird-test-pixel-bytes
                    (cl-loop for y below 6
                             nconc (cl-loop for x below 8
                                            collect (ladybird-test-formula
                                                     x y seed 8 6))))))
         (frame (lambda (view)
                  (ladybird-test-frame-record
                   :view view :width 8 :height 6 :flags 1 :encoding 2
                   :body (concat (ladybird-test-u32 0) (ladybird-test-u32 0))))))
    (dolist (name names)
      (ignore-errors (ladybird-module--test-shm-unlink name)))
    (ladybird-module--test-shm-write (nth 0 names) 0 (funcall pixels 1))
    (ladybird-module--test-shm-write (nth 1 names) 0 (funcall pixels 2))
    (unwind-protect
        (ladybird-test-with-session session
          (let ((one (ladybird-test-make-canvas 8 6))
                (two (ladybird-test-make-canvas 8 6)))
            (ladybird-module-attach-canvas session 1 one)
            (ladybird-module-attach-canvas session 2 two)
            (ladybird-module-set-shm session 1 (nth 0 names))
            ;; View 2 has no segment yet.
            (should (equal (ladybird-test-statuses
                            (ladybird-module-feed
                             session (concat (funcall frame 1) (funcall frame 2))))
                           '(painted shm-error)))
            (ladybird-module-set-shm session 2 (nth 1 names))
            (should (equal (ladybird-test-statuses
                            (ladybird-module-feed
                             session (concat (funcall frame 2) (funcall frame 1))))
                           '(painted painted)))
            (should (= (ladybird-module-canvas-pixel one 7 5)
                       (ladybird-test-formula 7 5 1 8 6)))
            (should (= (ladybird-module-canvas-pixel two 7 5)
                       (ladybird-test-formula 7 5 2 8 6)))
            (let ((views (sort (plist-get (ladybird-module-stats session) :views)
                               (lambda (a b) (< (car a) (car b))))))
              (should (equal (mapcar (lambda (view) (take 4 view)) views)
                             '((1 8 6 t) (2 8 6 t))))
              (should (= (plist-get (ladybird-module-stats session) :shm-size)
                         (+ (nth 4 (nth 0 views)) (nth 4 (nth 1 views)))))
              (should (> (nth 4 (nth 1 views)) 0)))
            ;; Unmapping one view leaves the other.
            (ladybird-module-set-shm session 1 nil)
            (should (equal (ladybird-test-statuses
                            (ladybird-module-feed
                             session (concat (funcall frame 1) (funcall frame 2))))
                           '(shm-error painted)))
            ;; Forgetting a view unmaps its segment.
            (ladybird-module-forget-view session 2)
            (should (= (plist-get (ladybird-module-stats session) :shm-size) 0))))
      (dolist (name names)
        (ladybird-module--test-shm-unlink name)))))

;;; Views

(ert-deftest ladybird-test-unknown-view ()
  ;; Frames of views nobody registered are reported and not kept.
  (ladybird-test-with-session session
    (let ((events (ladybird-module-feed
                   session
                   (concat (ladybird-test-frame-record :view 7 :seq 3 :width 4
                                                       :height 4 :flags 1)
                           ;; Not even a valid frame.
                           (ladybird-test-frame-record :view 8 :seq 9 :width 0
                                                       :height 0 :w 0 :h 0
                                                       :body "")))))
      (should (equal events '((frame 7 3 4 4 1.0 0 0 4 4 t unknown-view)
                              (frame 8 9 0 0 1.0 0 0 0 0 nil unknown-view)))))
    (should-not (plist-get (ladybird-module-stats session) :views))
    (should-not (ladybird-module-view-size session 7))
    (should (= (plist-get (ladybird-module-stats session) :frames-dropped) 2))))

(ert-deftest ladybird-test-many-views-allocate-nothing ()
  ;; A stream cannot make the module allocate stores: huge frames for
  ;; thousands of view ids leave no trace.
  (ladybird-test-with-session session
    (ladybird-module-register-view session 1)
    (let ((records nil))
      (dotimes (view 2000)
        (push (ladybird-test-frame-record :view (+ 100 view) :seq 1 :width 16384
                                          :height 16384 :w 1 :h 1 :flags 1
                                          :encoding 2
                                          :body (make-string 8 0))
              records))
      (let ((events (ladybird-module-feed session (apply #'concat records))))
        (should (= (length events) 2000))
        (should (equal (delete-dups (ladybird-test-statuses events))
                       '(unknown-view)))))
    ;; On a registered view a frame beyond the limit is a bad frame, and
    ;; one that fails is rejected before a store is made.
    (should (equal (ladybird-test-statuses
                    (ladybird-module-feed
                     session
                     (concat
                      (ladybird-test-frame-record :width 16384 :height 16384 :w 1
                                                  :h 1 :flags 1 :seed 1)
                      (ladybird-test-frame-record :width 8192 :height 8193 :w 1
                                                  :h 1 :flags 1 :seed 1)
                      (ladybird-test-frame-record :width 8192 :height 8192 :w 1
                                                  :h 1 :flags 1 :encoding 2
                                                  :body (make-string 8 0))
                      (ladybird-test-frame-record :width 8192 :height 8192 :w 1
                                                  :h 1 :flags 1 :encoding 1
                                                  :body "not zstd"))))
                   '(bad-frame bad-frame shm-error decode-error)))
    (should (equal (plist-get (ladybird-module-stats session) :views)
                   '((1 0 0 nil 0))))
    (should-not (ladybird-module-view-size session 1))))

(ert-deftest ladybird-test-forget-view ()
  (ladybird-test-with-session session
    (let ((canvas (ladybird-test-make-canvas 4 4))
          (frame (ladybird-test-frame-record :width 4 :height 4 :flags 1 :seed 2)))
      (should-not (ladybird-module-forget-view session 1))
      (ladybird-module-attach-canvas session 1 canvas)
      (should (equal (ladybird-test-statuses (ladybird-module-feed session frame))
                     '(painted)))
      (should (eq (ladybird-module-forget-view session 1) t))
      (should-not (ladybird-module-forget-view session 1))
      (should-not (plist-get (ladybird-module-stats session) :views))
      (should-not (ladybird-module-view-size session 1))
      (should (eq (ladybird-module-repaint session 1) 'no-frame))
      (should (equal (ladybird-test-statuses (ladybird-module-feed session frame))
                     '(unknown-view)))
      ;; Registered again it starts without a frame or a canvas.
      (ladybird-module-register-view session 1)
      (should (eq (ladybird-module-register-view session 1) t))
      (should (equal (plist-get (ladybird-module-stats session) :views)
                     '((1 0 0 nil 0))))
      (should (equal (ladybird-test-statuses (ladybird-module-feed session frame))
                     '(stored))))))

(ert-deftest ladybird-test-failed-frame-keeps-store ()
  ;; A full frame that cannot be decoded leaves the last good frame.
  (ladybird-test-with-session session
    (let ((canvas (ladybird-test-make-canvas 4 4))
          (good (ladybird-test-frame-record :width 4 :height 4 :flags 1 :seed 2)))
      (ladybird-module-attach-canvas session 1 canvas)
      (ladybird-module-feed session good)
      (should (equal (ladybird-test-statuses
                      (ladybird-module-feed
                       session
                       (concat
                        (ladybird-test-frame-record :seq 2 :width 9 :height 9
                                                    :flags 1 :encoding 1
                                                    :body "not zstd")
                        (ladybird-test-frame-record :seq 3 :width 9 :height 9
                                                    :flags 1 :encoding 2
                                                    :body (make-string 8 0))
                        (ladybird-test-frame-record :seq 4 :width 4 :height 4
                                                    :flags 1 :encoding 1
                                                    :body "not zstd"))))
                     '(decode-error shm-error decode-error)))
      (should (equal (ladybird-module-view-size session 1) '(4 . 4)))
      (ladybird-module-canvas-fill canvas 0)
      (should (eq (ladybird-module-repaint session 1) 'painted))
      (dotimes (y 4)
        (dotimes (x 4)
          (should (= (ladybird-module-canvas-pixel canvas x y)
                     (ladybird-test-formula x y 2 4 4))))))))

(ert-deftest ladybird-test-canvas-error ()
  ;; A canvas spec Emacs rejects does not abort the feed: the frame is
  ;; stored and reported, and the events around it are returned.
  (ladybird-test-with-session session
    (let* ((canvas (ladybird-test-make-canvas 4 4))
           (other (ladybird-test-make-canvas 4 4))
           (frame (lambda (view seq)
                    (ladybird-test-frame-record :view view :seq seq :width 4
                                                :height 4 :flags 1 :seed seq))))
      (ladybird-module-attach-canvas session 1 canvas)
      (ladybird-module-attach-canvas session 2 other)
      ;; Break the spec of view 1 after it was attached.
      (plist-put (cdr canvas) :data-width 'broken)
      (let ((events (ladybird-module-feed
                     session (concat (funcall frame 2 1) (funcall frame 1 2)
                                     (funcall frame 2 3)
                                     (ladybird-test-record 1 "{}")))))
        (should (equal events '((frame 2 1 4 4 1.0 0 0 4 4 t painted)
                                (frame 1 2 4 4 1.0 0 0 4 4 t canvas-error)
                                (frame 2 3 4 4 1.0 0 0 4 4 t painted)
                                "{}"))))
      (should (= (ladybird-module-canvas-pixel other 3 3)
                 (ladybird-test-formula 3 3 3 4 4)))
      ;; The frame is there for a canvas that works.
      (should (equal (ladybird-module-view-size session 1) '(4 . 4)))
      (let ((fresh (ladybird-test-make-canvas 4 4)))
        (ladybird-module-attach-canvas session 1 fresh)
        (should (eq (ladybird-module-repaint session 1) 'painted))
        (should (= (ladybird-module-canvas-pixel fresh 3 3)
                   (ladybird-test-formula 3 3 2 4 4)))))))

(ert-deftest ladybird-test-refresh-error-keeps-dirty ()
  ;; A `canvas-refresh' that signals loses neither events nor the need to
  ;; refresh.
  (ladybird-test-with-session session
    (let ((canvas (ladybird-test-make-canvas 4 4))
          (frame (ladybird-test-frame-record :width 4 :height 4 :flags 1))
          (fail t)
          (calls 0))
      (ladybird-module-attach-canvas session 1 canvas)
      (cl-letf (((symbol-function 'canvas-refresh)
                 (lambda (&rest _)
                   (cl-incf calls)
                   (when fail (error "No refresh")))))
        (should (equal (ladybird-module-feed
                        session (concat frame (ladybird-test-record 1 "{}")))
                       '((frame 1 1 4 4 1.0 0 0 4 4 t painted) "{}")))
        (should (= calls 1))
        (should (equal (plist-get (ladybird-module-stats session) :dirty-views)
                       '(1)))
        ;; The next feed tries again.
        (setq fail nil)
        (should-not (ladybird-module-feed session ""))
        (should (= calls 2))
        (should-not (plist-get (ladybird-module-stats session) :dirty-views))
        (should-not (ladybird-module-feed session ""))
        (should (= calls 2))))))

(ert-deftest ladybird-test-feed-ignores-quit ()
  ;; A pending quit does not cut a feed short: every record gets its event.
  (ladybird-test-with-session session
    (ladybird-module-register-view session 1)
    (let* ((frame (ladybird-test-frame-record :width 4 :height 4 :flags 1))
           (inhibit-quit t)
           (events (progn
                     (setq quit-flag t)
                     (prog1 (ladybird-module-feed session (concat frame frame frame))
                       (setq quit-flag nil)))))
      (should (equal (ladybird-test-statuses events) '(stored stored stored))))))

(provide 'ladybird-module-test)
;;; ladybird-module-test.el ends here
