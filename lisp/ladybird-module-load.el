;;; ladybird-module-load.el --- Load the ladybird native module -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Locates and loads `ladybird-module', the native module that parses the
;; ladybird byte stream and paints frames into Emacs canvas images.
;;
;; `ladybird-load-module' reads the version sidecar `ladybird-module.version'
;; next to the module before mapping the module, so a module older than
;; `ladybird--minimum-module-version' is never loaded.  Build the module
;; with `make build' in the package directory (Zig 0.17).

;;; Code:

(declare-function ladybird-module-version "ladybird-module")

(defcustom ladybird-module-directory nil
  "Directory holding the ladybird native module.
When nil, the module is looked for in the directory of this file and in
its parent directory."
  :type '(choice (const :tag "Package directory" nil)
                 (directory :tag "Custom directory"))
  :group 'ladybird)

(defconst ladybird--minimum-module-version "0.2.0"
  "Oldest native module version this Elisp code works with.")

(define-error 'ladybird-module-error "Ladybird module error")

(defconst ladybird--module-load-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory this file was loaded from.")

(defun ladybird--module-file-name ()
  "Return the file name of the native module without its directory."
  (concat "ladybird-module" module-file-suffix))

(defun ladybird--module-directory ()
  "Return the directory to load the native module from.
This is `ladybird-module-directory' if set.  Otherwise it is the directory
of this file or its parent, whichever contains the module, and the
parent when neither does."
  (if ladybird-module-directory
      (file-name-as-directory (expand-file-name ladybird-module-directory))
    (let* ((lisp-dir (or (and-let* ((library (locate-library "ladybird-module-load")))
                           (file-name-directory library))
                         ladybird--module-load-directory))
           (parent (file-name-directory (directory-file-name lisp-dir))))
      (if (file-exists-p (expand-file-name (ladybird--module-file-name) lisp-dir))
          lisp-dir
        parent))))

(defun ladybird--module-sidecar-version (dir)
  "Return the module version recorded in the sidecar file in DIR, or nil."
  (let ((file (expand-file-name "ladybird-module.version" dir)))
    (when (file-readable-p file)
      (let ((version (with-temp-buffer
                       (insert-file-contents file)
                       (string-trim (buffer-string)))))
        (and (not (string-empty-p version)) version)))))

(defun ladybird--module-version-ok-p (version)
  "Return non-nil if VERSION is a version string the Lisp code works with.
A string that is no version is not."
  (condition-case nil
      (not (version< version ladybird--minimum-module-version))
    (error nil)))

(defun ladybird-load-module ()
  "Load the ladybird native module unless it is loaded.
Return non-nil if a module the Lisp code works with is loaded
afterwards.  A missing module, one whose version is malformed or older
than `ladybird--minimum-module-version', and one that fails to load
produce a warning and nil."
  (if (featurep 'ladybird-module)
      (ladybird--module-version-ok-p (ladybird-module-version))
    (let* ((dir (ladybird--module-directory))
           (file (expand-file-name (ladybird--module-file-name) dir))
           (sidecar (ladybird--module-sidecar-version dir)))
      (cond
       ((not (fboundp 'module-load))
        (display-warning 'ladybird "This Emacs does not support dynamic modules")
        nil)
       ((not (file-exists-p file))
        (display-warning
         'ladybird (format "Native module %s not found; build it with `make build'" file))
        nil)
       ((and sidecar (not (ladybird--module-version-ok-p sidecar)))
        (display-warning
         'ladybird (format "Native module version %S in %s is not a version or older than required %s"
                           sidecar dir ladybird--minimum-module-version))
        nil)
       (t
        (condition-case err
            (progn
              (module-load file)
              (let ((version (ladybird-module-version)))
                (or (ladybird--module-version-ok-p version)
                    (progn
                      (display-warning
                       'ladybird (format "Loaded native module version %S is older than required %s"
                                         version ladybird--minimum-module-version))
                      nil))))
          (error
           (display-warning
            'ladybird (format "Failed to load native module %s: %s"
                              file (error-message-string err)))
           nil)))))))

(provide 'ladybird-module-load)
;;; ladybird-module-load.el ends here
