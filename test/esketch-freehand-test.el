;;; esketch-freehand-test.el --- Tests for esketch-freehand  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pcsf

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Every row of freehand-cases.json was produced by the real perfect-freehand
;; 1.2.0 (tools/gen-freehand-cases.ts).  Run from the repository root:
;;   emacs -Q --batch -L . -l test/esketch-freehand-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'esketch-json)
(require 'esketch-freehand)

(defconst esketch-freehand-test--tolerance 1e-6)

(defconst esketch-freehand-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun esketch-freehand-test--cases ()
  (let ((json-object-type 'alist) (json-array-type 'list)
        (json-key-type 'string) (json-false :false))
    (json-read-file (expand-file-name "freehand-cases.json"
                                      esketch-freehand-test--dir))))

(defun esketch-freehand-test--obj (v)
  "Convert json.el V to esketch-json form (objects as (:obj ...), arrays as vectors)."
  (cond ((and (consp v) (consp (car v)) (stringp (caar v)))
         (cons :obj (mapcar (lambda (c) (cons (car c) (esketch-freehand-test--obj (cdr c))))
                            v)))
        ((listp v) (vconcat (mapcar #'esketch-freehand-test--obj v)))
        (t v)))

(defun esketch-freehand-test--easing (name)
  (pcase name
    ("sine" (lambda (u) (sin (/ (* u float-pi) 2))))
    ("linear" #'identity)
    ("quad" (lambda (u) (* u u)))))

(defun esketch-freehand-test--side (spec)
  (let (out)
    (dolist (c spec)
      (let ((k (intern (concat ":" (car c)))) (v (cdr c)))
        (setq out (append out (list k (if (and (eq k :easing) (stringp v))
                                          (esketch-freehand-test--easing v)
                                        v))))))
    out))

(defun esketch-freehand-test--options (alist)
  (let (out)
    (dolist (c alist)
      (let ((k (intern (concat ":" (car c)))) (v (cdr c)))
        (setq out (append out
                          (list k (cond ((eq k :easing) (esketch-freehand-test--easing v))
                                        ((memq k '(:start :end))
                                         (esketch-freehand-test--side v))
                                        (t v)))))))
    out))

(defun esketch-freehand-test--max-deviation (got want what)
  "Largest coordinate difference between lists GOT and WANT, or signal on shape."
  (unless (= (length got) (length want))
    (error "%s: %d points, expected %d" what (length got) (length want)))
  (let ((worst 0.0))
    (cl-mapc (lambda (g w)
               (setq worst (max worst (abs (- (car g) (car w)))
                                (abs (- (cadr g) (cadr w))))))
             got want)
    worst))

(defvar esketch-freehand-test--worst 0.0)

(ert-deftest esketch-freehand-oracle-outline ()
  (dolist (c (esketch-freehand-test--cases))
    (let* ((name (cdr (assoc "name" c)))
           (got (esketch-freehand-stroke
                 (cdr (assoc "inputPoints" c))
                 (esketch-freehand-test--options (cdr (assoc "options" c)))))
           (dev (esketch-freehand-test--max-deviation
                 got (cdr (assoc "outline" c)) name)))
      (setq esketch-freehand-test--worst (max esketch-freehand-test--worst dev))
      (should (<= dev esketch-freehand-test--tolerance)))))

(ert-deftest esketch-freehand-oracle-stroke-points ()
  (dolist (c (esketch-freehand-test--cases))
    (let* ((name (cdr (assoc "name" c)))
           (got (esketch-freehand-stroke-points
                 (cdr (assoc "inputPoints" c))
                 (esketch-freehand-test--options (cdr (assoc "options" c)))))
           (want (cdr (assoc "strokePoints" c))))
      (should (equal (length got) (length want)))
      (cl-mapc
       (lambda (g w)
         (dolist (pair `((:point . "point") (:vector . "vector")))
           (should (<= (esketch-freehand-test--max-deviation
                        (list (plist-get g (car pair))) (list (cdr (assoc (cdr pair) w)))
                        name)
                       esketch-freehand-test--tolerance)))
         (should (<= (abs (- (plist-get g :pressure) (cdr (assoc "pressure" w))))
                     esketch-freehand-test--tolerance))
         (should (<= (abs (- (plist-get g :distance) (cdr (assoc "distance" w))))
                     esketch-freehand-test--tolerance))
         (should (<= (abs (- (plist-get g :running-length)
                             (cdr (assoc "runningLength" w))))
                     esketch-freehand-test--tolerance)))
       got want))))

(ert-deftest esketch-freehand-oracle-svg-path ()
  (let ((checked 0) mismatches)
    (dolist (c (esketch-freehand-test--cases))
      (let ((want (cdr (assoc "d" c))))
        (when want
          (cl-incf checked)
          (let ((got (esketch-freehand-svg-path
                      (esketch-freehand-test--obj (cdr (assoc "element" c))))))
            (unless (equal got want)
              (push (cdr (assoc "name" c)) mismatches))))))
    (should (> checked 30))
    (should (equal (nreverse mismatches) nil))))

(ert-deftest esketch-freehand-empty-input ()
  (should (null (esketch-freehand-stroke nil nil)))
  (should (null (esketch-freehand-stroke-points nil nil))))

(provide 'esketch-freehand-test)
;;; esketch-freehand-test.el ends here
