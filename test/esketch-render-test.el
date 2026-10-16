;;; esketch-render-test.el --- ERT suite for esketch-render  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/esketch-render-test.el -f ert-run-tests-batch-and-exit
;;
;; test/render-cases.json comes from tools/gen-render-cases.ts and records
;; what JavaScript prints for +x.toFixed(d).  The option and geometry cases
;; are worked out by hand from Excalidraw's shape.ts, bounds.ts and utils.ts
;; at commit 4c37956b.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'esketch-render)

(defconst esketch-render-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun esketch-render-test--el (json)
  (esketch-json-read-from-string json))

(defun esketch-render-test--rect (&rest kv)
  "A rectangle element with Excalidraw defaults, overridden by KV."
  (let ((el (esketch-new-element "rectangle" 0 0 200 80)))
    (esketch-put el "seed" 1)
    (while kv
      (esketch-put el (car kv) (cadr kv))
      (setq kv (cddr kv)))
    el))

(ert-deftest esketch-render-test-to-fixed ()
  (let* ((json-array-type 'list)
         (rows (json-read-file (expand-file-name "render-cases.json"
                                                 esketch-render-test--dir)))
         (fails nil))
    (should (> (length rows) 500))
    (dolist (r rows)
      (let ((got (esketch-json-number-string
                  (esketch-render--to-fixed (float (nth 0 r)) (nth 1 r)))))
        (unless (equal got (nth 2 r))
          (push (list r got) fails))))
    (should (equal fails nil))))

(ert-deftest esketch-render-test-options-plain-rectangle ()
  (let ((o (esketch-render--options (esketch-render-test--rect))))
    (should (equal (plist-get o :seed) 1))
    (should (equal (plist-get o :roughness) 1))
    (should (equal (plist-get o :strokeWidth) 2))
    (should (= (plist-get o :fillWeight) 1))
    (should (= (plist-get o :hachureGap) 8))
    (should (eq (plist-get o :preserveVertices) t))
    (should-not (plist-get o :disableMultiStroke))
    (should-not (plist-get o :strokeLineDash))
    (should (equal (plist-get o :fillStyle) "solid"))
    (should-not (plist-get o :fill))))

(ert-deftest esketch-render-test-options-small-dashed ()
  "Small shapes lose roughness; dashed strokes widen and stop multi-stroking."
  (let ((o (esketch-render--options
            (esketch-render-test--rect "width" 8 "height" 8 "roughness" 2
                                       "strokeStyle" "dashed"
                                       "backgroundColor" "#ffc9c9"
                                       "roundness" :null))))
    (should (= (plist-get o :roughness) (/ 2 3.0)))
    (should (equal (plist-get o :strokeLineDash) '(8 10)))
    (should (= (plist-get o :strokeWidth) 2.5))
    (should (eq (plist-get o :disableMultiStroke) t))
    (should-not (plist-get o :preserveVertices))
    (should (equal (plist-get o :fill) "#ffc9c9"))))

(ert-deftest esketch-render-test-options-rounded-keeps-roughness ()
  "A rounded rectangle of 16 px keeps its roughness; a sharp one halves it."
  (should (= (plist-get (esketch-render--options
                         (esketch-render-test--rect "width" 40 "height" 16))
                        :roughness)
             1))
  (should (= (plist-get (esketch-render--options
                         (esketch-render-test--rect "width" 40 "height" 16
                                                    "roundness" :null))
                        :roughness)
             0.5)))

(ert-deftest esketch-render-test-options-ellipse-and-dotted ()
  (let ((el (esketch-new-element "ellipse" 0 0 100 60)))
    (esketch-put el "strokeStyle" "dotted")
    (esketch-put el "strokeWidth" 1)
    (let ((o (esketch-render--options el)))
      (should (= (plist-get o :curveFitting) 1))
      (should (equal (plist-get o :strokeLineDash) '(1.5 7))))))

(ert-deftest esketch-render-test-plain-style ()
  (let ((esketch-render-style 'plain))
    (should (= (plist-get (esketch-render--options (esketch-render-test--rect))
                          :roughness)
               0))))

(ert-deftest esketch-render-test-transparent ()
  (dolist (c '("transparent" "#fff0" "#ffffff00" "rgba(1, 2, 3, 0)"))
    (should (esketch-render--transparent-p c)))
  (dolist (c '("#ffffff" "#fff" "#ffc9c9" "rgba(1, 2, 3, 0.5)" "#ffffff80"))
    (should-not (esketch-render--transparent-p c))))

(ert-deftest esketch-render-test-corner-radius ()
  (let ((adaptive (esketch-render-test--rect))
        (prop (esketch-render-test--rect "roundness" '(:obj ("type" . 2))))
        (fixed (esketch-render-test--rect
                "roundness" '(:obj ("type" . 3) ("value" . 10))))
        (none (esketch-render-test--rect "roundness" :null)))
    (should (= (esketch-render--corner-radius 80 adaptive) 20))
    (should (= (esketch-render--corner-radius 200 adaptive) 32))
    (should (= (esketch-render--corner-radius 200 prop) 50))
    (should (= (esketch-render--corner-radius 200 fixed) 10))
    (should (= (esketch-render--corner-radius 200 none) 0))))

(ert-deftest esketch-render-test-diamond-points ()
  (let ((el (esketch-new-element "diamond" 0 0 160 120)))
    (should (equal (esketch-render--diamond-points el) '(81 0 160 61 81 120 0 61))))
  (let ((el (esketch-new-element "diamond" 0 0 25 9)))
    (should (equal (esketch-render--diamond-points el) '(13 0 25 5 13 9 0 5)))))

(defun esketch-render-test--arrow (points head)
  (let ((el (esketch-new-element "arrow" 0 0 100 0)))
    (esketch-put el "points" (vconcat (mapcar #'vconcat points)))
    (esketch-put el "roughness" 0)
    (esketch-put el "roundness" :null)
    (esketch-put el "endArrowhead" head)
    el))

(ert-deftest esketch-render-test-arrowhead-straight ()
  "On a straight arrow the head is a 25 px, 20 degree chevron at the tip."
  (let* ((el (esketch-render-test--arrow '((0 0) (100 0)) "arrow"))
         (main (esketch-rough-linear-path '((0 0) (100 0))
                                          (esketch-render--options el)))
         (p (esketch-render--arrowhead-points el main 'end "arrow"))
         (a (degrees-to-radians 20)))
    (should (= (length p) 6))
    (cl-mapc (lambda (got want) (should (< (abs (- got want)) 1e-9)))
             p (list 100 0
                     (- 100 (* 25 (cos a))) (* 25 (sin a))
                     (- 100 (* 25 (cos a))) (- (* 25 (sin a)))))))

(ert-deftest esketch-render-test-arrowhead-short-segment ()
  "A short last segment scales the head to half its length."
  (let* ((el (esketch-render-test--arrow '((0 0) (20 0)) "arrow"))
         (main (esketch-rough-linear-path '((0 0) (20 0))
                                          (esketch-render--options el)))
         (p (esketch-render--arrowhead-points el main 'end "arrow")))
    (should (< (abs (- (nth 2 p) (- 20 (* 10 (cos (degrees-to-radians 20))))))
               1e-9))))

(ert-deftest esketch-render-test-arrowhead-kinds ()
  "Every Excalidraw arrowhead yields drawables."
  (dolist (head '("arrow" "bar" "circle" "circle_outline" "triangle"
                  "triangle_outline" "diamond" "diamond_outline"
                  "cardinality_one" "cardinality_many" "cardinality_one_or_many"
                  "cardinality_exactly_one" "cardinality_zero_or_one"
                  "cardinality_zero_or_many"))
    (let* ((el (esketch-render-test--arrow '((0 0) (100 30)) head))
           (shapes (esketch-render--shape-drawables el "#ffffff")))
      (should (> (length shapes) 1)))))

(ert-deftest esketch-render-test-text-placement ()
  "A font esketch does not ship falls back to SVG text, placed as Excalidraw
places it."
  (let ((el (esketch-new-element "text" 0 0 99 25)))
    (esketch-put el "text" "a<b\nline 2")
    (esketch-put el "textAlign" "center")
    (esketch-put el "fontFamily" 2)
    (let ((svg (esketch-render--text-svg el)))
      (should (string-match-p "x=\"49.5\"" svg))
      ;; JavaScript gives these for Helvetica at 20px, lineHeight 1.25
      (should (string-match-p "y=\"17.900390625\"" svg))
      (should (string-match-p "a&lt;b" svg))
      (should (string-match-p "font-family=\"Helvetica, sans-serif, Segoe UI Emoji\"" svg)))))

(ert-deftest esketch-render-test-text-glyphs ()
  "Excalifont text is drawn from the shipped outlines, centred by its advances."
  (let ((el (esketch-new-element "text" 0 0 99 25)))
    (esketch-put el "text" "Sensor")
    (esketch-put el "textAlign" "center")
    (let* ((svg (esketch-render--text-svg el))
           (w (esketch-render--text-width 5 20 "Sensor")))
      (should (string-match-p "<g class=\"esketch-text\"" svg))
      (should-not (string-match-p "<text" svg))
      (should (string-match-p
               (regexp-quote
                (format "translate(%s 17.619999999999997) scale(0.02)"
                        (esketch-json-number-string (- 49.5 (/ w 2.0)))))
               svg))
      (should (= (cl-count ?< svg) 8)))))

(ert-deftest esketch-render-test-text-missing-glyph ()
  "A character the font lacks sends the whole line to SVG text."
  (let ((el (esketch-new-element "text" 0 0 99 25)))
    (esketch-put el "text" "x \u4e2d")
    (should (string-match-p "<text" (esketch-render--text-svg el)))))

(ert-deftest esketch-render-test-document ()
  "The basic fixture renders as one well-formed SVG with every live element."
  (let* ((doc (esketch-json-read-from-string
               (with-temp-buffer
                 (insert-file-contents
                  (expand-file-name "data/basic.excalidraw" esketch-render-test--dir))
                 (buffer-string))))
         (svg (esketch-render-svg doc)))
    (should (string-prefix-p "<svg" svg))
    (when (fboundp 'libxml-parse-xml-region)
      (should (with-temp-buffer
                (insert svg)
                (libxml-parse-xml-region (point-min) (point-max)))))
    ;; rect, text, ellipse, arrow (shaft + 2 head lines), diamond, line,
    ;; freedraw, arrow2 (shaft + 2 head lines)
    (should (>= (cl-count ?g (split-string svg "<" t)
                          :key (lambda (s) (aref s 0)))
                8))
    (should (string-match-p "class=\"esketch-text\"" svg))
    (should (string-match-p "stroke-dasharray=\"8 10.5\"\\|stroke-dasharray=\"8 10\"" svg))))

(ert-deftest esketch-render-test-deterministic ()
  "Rendering twice gives the same SVG: everything is seeded."
  (let ((doc (esketch-json-read-from-string
              (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "data/basic.excalidraw" esketch-render-test--dir))
                (buffer-string)))))
    (should (equal (esketch-render-svg doc) (esketch-render-svg doc)))))

(provide 'esketch-render-test)
;;; esketch-render-test.el ends here
