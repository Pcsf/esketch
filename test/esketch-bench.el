;;; esketch-bench.el --- Drag latency of the esketch editor  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with `make bench', or
;;   emacs -Q --batch -L . -l test/esketch-bench.el -f esketch-bench-run
;;
;; One drag step is what the editor does for each move: esketch-move on the
;; selected shape, the view fitted, the SVG rendered with the selection
;; layer, and `create-image'.  Rasterisation by the SVG library happens when
;; the frame redisplays, which a batch Emacs cannot do; in a graphic Emacs the
;; step adds `image-size', which forces it.  For that figure run, in a graphic
;; Emacs started with -Q:
;;   (progn (load "test/esketch-bench.el")
;;          (with-output-to-temp-buffer "*bench*" (esketch-bench-run)))
;;
;; ESKETCH_BENCH_SIZES, e.g. "10 100 500", sets the element counts.

;;; Code:

(require 'cl-lib)
(require 'esketch)

(defconst esketch-bench-steps 30 "Timed drag steps per drawing.")

(defun esketch-bench--shape (doc i)
  "Add shape I, rectangle, ellipse or diamond in turn, on a grid; return it."
  (let ((el (esketch-new-element (nth (mod i 3) '("rectangle" "ellipse" "diamond"))
                                 (* 260 (mod i 12)) (* 160 (/ i 12)) 160 80)))
    (esketch-add doc el)
    el))

(defun esketch-bench--label (doc shape text)
  (let ((tx (esketch-new-element "text" 0 0 0 0)))
    (esketch-put tx "text" text)
    (esketch-put tx "originalText" text)
    (esketch-put tx "textAlign" "center")
    (esketch-put tx "verticalAlign" "middle")
    (esketch-put tx "containerId" (esketch-get shape "id"))
    (esketch-add doc tx)
    (esketch--bound-add shape (esketch-get tx "id") "text")
    (esketch--place-label doc tx shape)))

(defun esketch-bench--arrow (doc from to)
  (let* ((ends (esketch--arrow-ends doc from to))
         (s (car ends)) (e (cadr ends))
         (a (esketch-new-element "arrow" (car s) (cadr s)
                                 (- (car e) (car s)) (- (cadr e) (cadr s))))
         (id (esketch-add doc a)))
    (esketch-bind doc id 'start (esketch-get from "id"))
    (esketch-bind doc id 'end (esketch-get to "id"))))

(defun esketch-bench-doc (n)
  "A drawing of exactly N elements: shapes, their labels, arrows between shapes.
Return (DOC . ID) with ID a shape in the middle that has a label and arrows."
  (let ((doc (list :obj (cons "type" "excalidraw") (cons "version" 2)
                   (cons "elements" []) (cons "appState" (list :obj))))
        (i 0) (prev nil) (mid nil))
    (while (< (length (esketch-elements doc)) n)
      (let ((shape (esketch-bench--shape doc i)))
        (when (and (null mid) (>= (length (esketch-elements doc)) (/ n 2)) prev)
          (setq mid (esketch-get shape "id")))
        (when (< (length (esketch-elements doc)) n)
          (esketch-bench--label doc shape (format "Block %d" i)))
        (when (and prev (< (length (esketch-elements doc)) n))
          (esketch-bench--arrow doc prev shape))
        (setq prev shape i (1+ i))))
    (cons doc (or mid (esketch-get (aref (esketch-elements doc) 0) "id")))))

(defun esketch-bench--ed (doc)
  (let ((ed (esketch-ed--make :efile (esketch-file--make :doc doc) :file "bench.excalidraw")))
    (esketch--fit-view ed)
    ed))

(defun esketch-bench--step (ed id raster)
  (esketch-move (esketch-ed-doc ed) id 3 2)
  (esketch--fit-view ed)
  (let ((img (esketch-image (esketch-render-svg (esketch-ed-doc ed) (esketch-ed-view ed)
                                                (esketch--selection-svg ed))
                            (esketch-ed-scale ed))))
    (when raster (image-size img t))))

(defun esketch-bench--ms (fn)
  (let ((t0 (float-time))) (funcall fn) (* 1000 (- (float-time) t0))))

(defun esketch-bench--stats (xs)
  (let ((sorted (sort (copy-sequence xs) #'<)))
    (list (nth (/ (length sorted) 2) sorted) (car (last sorted)))))

(defun esketch-bench-measure (n &optional raster)
  "Median and maximum drag step in ms over `esketch-bench-steps' steps at N elements."
  (let* ((built (esketch-bench-doc n))
         (ed (esketch-bench--ed (car built)))
         (id (cdr built)))
    (esketch--select ed id)
    (dotimes (_ 3) (esketch-bench--step ed id raster))
    (garbage-collect)
    (esketch-bench--stats
     (cl-loop repeat esketch-bench-steps
              collect (esketch-bench--ms (lambda () (esketch-bench--step ed id raster)))))))

(defun esketch-bench-run ()
  (let* ((env (getenv "ESKETCH_BENCH_SIZES"))
         (sizes (if env (mapcar #'string-to-number (split-string env)) '(10 100 500)))
         (raster (display-graphic-p)))
    (princ (format "drag step (move + render + create-image%s), %d steps each, Emacs %s\n"
                   (if raster " + image-size" "") esketch-bench-steps emacs-version))
    (princ (format "%9s %12s %12s\n" "elements" "median ms" "max ms"))
    (dolist (n sizes)
      (let ((s (esketch-bench-measure n raster)))
        (princ (format "%9d %12.1f %12.1f\n" n (car s) (cadr s)))))))

(provide 'esketch-bench)
;;; esketch-bench.el ends here
