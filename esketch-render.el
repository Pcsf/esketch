;;; esketch-render.el --- Draw Excalidraw documents as SVG  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pcsf

;; Author: Pcsf <7274075+Pcsf@users.noreply.github.com>
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/Pcsf/esketch

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Turns an Excalidraw document into SVG the way Excalidraw's own SVG export
;; does (packages/element/src/shape.ts and renderer/staticSvgScene.ts at
;; commit 4c37956b): the same roughjs options and shape calls per element,
;; the same arrowhead geometry, the same text placement, and path numbers
;; rounded to 2 decimals.
;;
;; `esketch-render-style' set to `plain' draws every element with roughness
;; 0, Excalidraw's "architect" setting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'esketch-json)
(require 'esketch-model)
(require 'esketch-rough)
(require 'esketch-freehand)

(defvar esketch-render-style 'hand
  "`hand' for Excalidraw's sketchy look, `plain' for straight lines.")

(defconst esketch-render--decimals 2
  "Excalidraw's MAX_DECIMALS_FOR_SVG_EXPORT.")

(defconst esketch-render--padding 10
  "Excalidraw's default export padding.")

;;;; Numbers as JavaScript prints them

(defun esketch-render--num (n)
  (esketch-json-number-string n))

(defun esketch-render--to-fixed (x digits)
  "X rounded as JavaScript's x.toFixed(DIGITS), then read back as a number.
JavaScript rounds the exact binary value and takes the larger magnitude
on a tie, where printf would round a tie to even."
  (if (>= (abs x) 1e21)
      x
    (let* ((s (format (format "%%.%df" (+ digits 60)) (abs x)))
           (dot (string-match "\\." s))
           (kept (concat (substring s 0 dot)
                         (substring s (1+ dot) (+ dot 1 digits))))
           (n (string-to-number kept)))
      (when (>= (aref s (+ dot 1 digits)) ?5)
        (setq n (1+ n)))
      (let ((v (/ (float n) (expt 10 digits))))
        ;; Division can miss the nearest double; read the decimal instead.
        (setq v (string-to-number
                 (if (= digits 0)
                     (number-to-string n)
                   (let ((str (number-to-string n)))
                     (when (<= (length str) digits)
                       (setq str (concat (make-string (- (1+ digits) (length str)) ?0)
                                         str)))
                     (concat (substring str 0 (- (length str) digits)) "."
                             (substring str (- (length str) digits)))))))
        (if (< x 0) (- v) v)))))

(defun esketch-render--ops-to-path (set &optional digits)
  "roughjs opsToPath for SET, rounding as toFixed(DIGITS) when given."
  (let ((parts nil)
        (fmt (lambda (d)
               (esketch-render--num
                (if digits (esketch-render--to-fixed d digits) d)))))
    (dolist (op (plist-get set :ops))
      (let ((d (mapcar fmt (cdr op))))
        (push (pcase (car op)
                ('move (format "M%s %s " (nth 0 d) (nth 1 d)))
                ('bcurveTo (format "C%s %s, %s %s, %s %s "
                                   (nth 0 d) (nth 1 d) (nth 2 d) (nth 3 d)
                                   (nth 4 d) (nth 5 d)))
                ('lineTo (format "L%s %s " (nth 0 d) (nth 1 d)))
                (_ ""))
              parts)))
    (string-trim (apply #'concat (nreverse parts)))))

;;;; Excalidraw's roughjs options

(defun esketch-render--transparent-p (color)
  "Non-nil when COLOR has alpha 0, as tinycolor sees it."
  (let ((c (downcase (string-trim (or color "")))))
    (or (string= c "transparent")
        (string-match-p "\\`#[0-9a-f]\\{3\\}0\\'" c)
        (string-match-p "\\`#[0-9a-f]\\{6\\}00\\'" c)
        (string-match-p "\\`\\(rgb\\|hsl\\)a?(.*,[ \t]*0*\\.?0*[ \t]*)\\'" c))))

(defun esketch-render--linear-p (el)
  (member (esketch-get el "type") '("arrow" "line")))

(defun esketch-render--rounded-p (el)
  (esketch-obj-p (esketch-get el "roundness")))

(defun esketch-render--roughness (el)
  (if (eq esketch-render-style 'plain) 0 (or (esketch-get el "roughness") 1)))

(defun esketch-render--adjust-roughness (el)
  "Excalidraw's adjustRoughness: small shapes get less wobble."
  (let* ((r (esketch-render--roughness el))
         (w (esketch-get el "width")) (h (esketch-get el "height"))
         (max-size (max w h)) (min-size (min w h)))
    (if (or (and (>= min-size 20) (>= max-size 50))
            (and (>= min-size 15) (esketch-render--rounded-p el)
                 (member (esketch-get el "type")
                         '("rectangle" "iframe" "embeddable" "line" "diamond"
                           "stickynote" "image")))
            (and (esketch-render--linear-p el) (>= max-size 50)))
        r
      (min (/ r (if (< max-size 10) 3.0 2.0)) 2.5))))

(defun esketch-render--loop-p (points)
  (and (>= (length points) 3)
       (let ((a (car points)) (b (car (last points))))
         (<= (sqrt (+ (expt (- (car b) (car a)) 2) (expt (- (cadr b) (cadr a)) 2)))
             8))))

(defun esketch-render--points (el)
  (let ((pts (mapcar (lambda (p) (list (aref p 0) (aref p 1)))
                     (or (esketch-get el "points") []))))
    (or pts (list (list 0 0)))))

(defun esketch-render--options (el &optional continuous)
  "roughjs options for EL, as Excalidraw's generateRoughOptions builds them."
  (let* ((sw (esketch-get el "strokeWidth"))
         (style (esketch-get el "strokeStyle"))
         (solid (equal style "solid"))
         (type (esketch-get el "type"))
         (bg (esketch-get el "backgroundColor"))
         (opts (list :seed (esketch-get el "seed")
                     :disableMultiStroke (not solid)
                     :strokeWidth (if solid sw (+ sw 0.5))
                     :fillWeight (/ sw 2.0)
                     :hachureGap (* sw 4)
                     :roughness (esketch-render--adjust-roughness el)
                     :stroke (esketch-get el "strokeColor")
                     :preserveVertices
                     (or continuous (< (esketch-render--roughness el) 2)))))
    (pcase style
      ("dashed" (setq opts (plist-put opts :strokeLineDash (list 8 (+ 8 sw)))))
      ("dotted" (setq opts (plist-put opts :strokeLineDash (list 1.5 (+ 6 sw))))))
    (cond
     ((member type '("rectangle" "iframe" "embeddable" "diamond" "ellipse"))
      (setq opts (plist-put opts :fillStyle (esketch-get el "fillStyle")))
      (unless (esketch-render--transparent-p bg)
        (setq opts (plist-put opts :fill bg)))
      (when (equal type "ellipse")
        (setq opts (plist-put opts :curveFitting 1))))
     ((member type '("line" "freedraw"))
      (when (esketch-render--loop-p (esketch-render--points el))
        (setq opts (plist-put opts :fillStyle (esketch-get el "fillStyle")))
        (unless (equal bg "transparent")
          (setq opts (plist-put opts :fill bg))))))
    opts))

(defun esketch-render--plist-del (plist key)
  (let ((out nil))
    (while plist
      (unless (eq (car plist) key)
        (setq out (cons (cadr plist) (cons (car plist) out))))
      (setq plist (cddr plist)))
    (nreverse out)))

;;;; Shapes

(defun esketch-render--corner-radius (x el)
  (let* ((r (esketch-get el "roundness"))
         (type (and (esketch-obj-p r) (esketch-get r "type"))))
    (cond ((memq type '(1 2)) (* x 0.25))
          ((eq type 3)
           (let* ((value (esketch-get r "value"))
                  (fixed (if (numberp value) value 32)))
             (if (<= x (/ fixed 0.25)) (* x 0.25) fixed)))
          (t 0))))

(defun esketch-render--diamond-points (el)
  (let* ((w (esketch-get el "width")) (h (esketch-get el "height"))
         (top-x (1+ (floor (/ w 2.0)))) (right-y (1+ (floor (/ h 2.0)))))
    (list top-x 0 w right-y top-x h 0 right-y)))

(defun esketch-render--path-string (&rest parts)
  (mapconcat (lambda (p) (if (numberp p) (esketch-render--num p) p)) parts ""))

(defun esketch-render--shape-drawables (el bg-color)
  "List of roughjs drawables for EL, in Excalidraw's order."
  (let ((type (esketch-get el "type"))
        (w (esketch-get el "width")) (h (esketch-get el "height")))
    (pcase type
      ((or "rectangle" "iframe" "embeddable")
       (if (esketch-render--rounded-p el)
           (let ((r (esketch-render--corner-radius (min w h) el)))
             (list (esketch-rough-path
                    (esketch-render--path-string
                     "M " r " 0 L " (- w r) " 0 Q " w " 0, " w " " r
                     " L " w " " (- h r) " Q " w " " h ", " (- w r) " " h
                     " L " r " " h " Q 0 " h ", 0 " (- h r)
                     " L 0 " r " Q 0 0, " r " 0")
                    (esketch-render--options el t))))
         (list (esketch-rough-rectangle 0 0 w h (esketch-render--options el)))))
      ("diamond"
       (cl-destructuring-bind (tx ty rx ry bx by lx ly)
           (esketch-render--diamond-points el)
         (if (esketch-render--rounded-p el)
             (let ((vr (esketch-render--corner-radius (abs (- tx lx)) el))
                   (hr (esketch-render--corner-radius (abs (- ry ty)) el)))
               (list (esketch-rough-path
                      (esketch-render--path-string
                       "M " (+ tx vr) " " (+ ty hr) " L " (- rx vr) " " (- ry hr)
                       " C " rx " " ry ", " rx " " ry ", " (- rx vr) " " (+ ry hr)
                       " L " (+ bx vr) " " (- by hr)
                       " C " bx " " by ", " bx " " by ", " (- bx vr) " " (- by hr)
                       " L " (+ lx vr) " " (+ ly hr)
                       " C " lx " " ly ", " lx " " ly ", " (+ lx vr) " " (- ly hr)
                       " L " (- tx vr) " " (+ ty hr)
                       " C " tx " " ty ", " tx " " ty ", " (+ tx vr) " " (+ ty hr))
                      (esketch-render--options el t))))
           (list (esketch-rough-polygon
                  (list (list tx ty) (list rx ry) (list bx by) (list lx ly))
                  (esketch-render--options el))))))
      ("ellipse"
       (list (esketch-rough-ellipse (/ w 2.0) (/ h 2.0) w h
                                    (esketch-render--options el))))
      ((or "line" "arrow")
       (let* ((opts (esketch-render--options el))
              (pts (esketch-render--points el))
              (main (cond ((eq (esketch-get el "elbowed") t)
                           (esketch-rough-path (esketch-render--elbow-path pts 16)
                                               (esketch-render--options el t)))
                          ((esketch-render--rounded-p el)
                           (esketch-rough-curve pts opts))
                          ((plist-get opts :fill)
                           (esketch-rough-polygon pts opts))
                          (t (esketch-rough-linear-path pts opts))))
              (shapes (list main)))
         (when (equal type "arrow")
           (dolist (pos '(start end))
             (let ((head (esketch-get el (if (eq pos 'start)
                                             "startArrowhead" "endArrowhead"))))
               (when (and (stringp head) (not (eq head :null)))
                 (setq shapes (append shapes
                                      (esketch-render--arrowhead-drawables
                                       el main pos head opts bg-color)))))))
         shapes))
      (_ nil))))

(defun esketch-render--horizontal-p (p o)
  "Excalidraw's headingForPointIsHorizontal for the vector P - O."
  (let* ((x (- (car p) (car o))) (y (- (cadr p) (cadr o)))
         (ay (abs y)))
    (or (> x ay) (<= x (- ay)))))

(defun esketch-render--elbow-path (points radius)
  "SVG path for an elbow arrow through POINTS with corners of RADIUS."
  (let ((pv (vconcat points)) (sub nil))
    (cl-loop
     for i from 1 below (1- (length pv))
     do (let* ((prev (aref pv (1- i))) (next (aref pv (1+ i))) (p (aref pv i))
               (dist (lambda (a b) (sqrt (+ (expt (- (car a) (car b)) 2)
                                          (expt (- (cadr a) (cadr b)) 2)))))
               (corner (min radius (/ (funcall dist p next) 2.0)
                            (/ (funcall dist p prev) 2.0)))
               (toward
                (lambda (q horizontal)
                  (if horizontal
                      (list (if (< (car q) (car p)) (- (car p) corner) (+ (car p) corner))
                            (cadr p))
                    (list (car p)
                          (if (< (cadr q) (cadr p)) (- (cadr p) corner) (+ (cadr p) corner)))))))
          (push (funcall toward prev (esketch-render--horizontal-p p prev)) sub)
          (push p sub)
          (push (funcall toward next (esketch-render--horizontal-p next p)) sub)))
    (setq sub (vconcat (nreverse sub)))
    (let ((n (lambda (v) (esketch-render--num v)))
          (d (list (format "M %s %s" (esketch-render--num (car (aref pv 0)))
                           (esketch-render--num (cadr (aref pv 0)))))))
      (cl-loop for i from 0 below (length sub) by 3
               do (push (format "L %s %s" (funcall n (car (aref sub i)))
                                (funcall n (cadr (aref sub i))))
                        d)
               (push (format "Q %s %s, %s %s"
                             (funcall n (car (aref sub (1+ i))))
                             (funcall n (cadr (aref sub (1+ i))))
                             (funcall n (car (aref sub (+ i 2))))
                             (funcall n (cadr (aref sub (+ i 2)))))
                     d))
      (let ((last (aref pv (1- (length pv)))))
        (push (format "L %s %s" (funcall n (car last)) (funcall n (cadr last))) d))
      (mapconcat #'identity (nreverse d) " "))))

;;;; Arrowheads

(defun esketch-render--rotate (x y cx cy angle)
  (list (+ (- (* (- x cx) (cos angle)) (* (- y cy) (sin angle))) cx)
        (+ (+ (* (- x cx) (sin angle)) (* (- y cy) (cos angle))) cy)))

(defun esketch-render--path-ops (drawable)
  (let ((sets (plist-get drawable :sets)))
    (plist-get (or (cl-find 'path sets :key (lambda (s) (plist-get s :type)))
                   (car sets))
               :ops)))

(defun esketch-render--arrowhead-size (head)
  (pcase head
    ("arrow" 25)
    ((or "diamond" "diamond_outline") 12)
    ((or "cardinality_many" "cardinality_one_or_many" "cardinality_zero_or_many") 15)
    ((or "cardinality_one" "cardinality_exactly_one" "cardinality_zero_or_one") 20)
    (_ 15)))

(defun esketch-render--arrowhead-angle (head)
  (pcase head ("bar" 90) ("arrow" 20) (_ 25)))

(defun esketch-render--arrowhead-points (el main pos head &optional offset)
  "Excalidraw's getArrowheadPoints for arrow EL drawn as MAIN."
  (let* ((offset (or offset 0))
         (ops (vconcat (esketch-render--path-ops main))))
    (when (> (length ops) 1)
      (let* ((index (if (eq pos 'start) 1 (1- (length ops))))
             (data (cdr (aref ops index)))
             (p3 (list (nth 4 data) (nth 5 data)))
             (p2 (list (nth 2 data) (nth 3 data)))
             (p1 (list (nth 0 data) (nth 1 data)))
             (prev (aref ops (1- index)))
             (p0 (pcase (car prev)
                   ('move (list (nth 1 prev) (nth 2 prev)))
                   ('bcurveTo (list (nth 5 prev) (nth 6 prev)))
                   (_ (list 0 0))))
             (eqn (lambda (tt i)
                    (+ (* (expt (- 1 tt) 3) (nth i p3))
                       (* 3 tt (expt (- 1 tt) 2) (nth i p2))
                       (* 3 (expt tt 2) (- 1 tt) (nth i p1))
                       (* (nth i p0) (expt tt 3)))))
             (tip (if (eq pos 'start) p0 p3))
             (x2 (nth 0 tip)) (y2 (nth 1 tip))
             (x1 (funcall eqn 0.3 0)) (y1 (funcall eqn 0.3 1))
             (dist (sqrt (+ (expt (- x2 x1) 2) (expt (- y2 y1) 2))))
             (nx (/ (- x2 x1) dist)) (ny (/ (- y2 y1) dist))
             (size (esketch-render--arrowhead-size head))
             (pts (esketch-render--points el))
             (n (length pts))
             (c (if (eq pos 'end) (nth (1- n) pts) (nth 0 pts)))
             (p (if (> n 1) (if (eq pos 'end) (nth (- n 2) pts) (nth 1 pts))
                  (list 0 0)))
             (len (sqrt (+ (expt (- (car c) (car p)) 2)
                           (expt (- (cadr c) (cadr p)) 2))))
             (min-size (min size (* len (if (member head '("diamond" "diamond_outline"))
                                            0.25 0.5))))
             (tx (- x2 (* nx min-size offset)))
             (ty (- y2 (* ny min-size offset)))
             (xs (- tx (* nx min-size)))
             (ys (- ty (* ny min-size))))
        (if (member head '("circle" "circle_outline"))
            (list tx ty (+ (sqrt (+ (expt (- ys ty) 2) (expt (- xs tx) 2)))
                           (esketch-get el "strokeWidth") -2))
          (let ((angle (esketch-render--arrowhead-angle head)))
            (if (member head '("cardinality_many" "cardinality_one_or_many"))
                (append (list xs ys)
                        (esketch-render--rotate tx ty xs ys (/ (* (- angle) float-pi) 180))
                        (esketch-render--rotate tx ty xs ys (/ (* angle float-pi) 180)))
              (let ((a (esketch-render--rotate xs ys tx ty (/ (* (- angle) float-pi) 180)))
                    (b (esketch-render--rotate xs ys tx ty (/ (* angle float-pi) 180))))
                (if (member head '("diamond" "diamond_outline"))
                    (let ((o (if (eq pos 'start)
                                 (let ((q (if (> n 1) (nth 1 pts) (list 0 0))))
                                   (esketch-render--rotate
                                    (+ tx (* min-size 2)) ty tx ty
                                    (atan (- (cadr q) ty) (- (car q) tx))))
                               (let ((q (if (> n 1) (nth (- n 2) pts) (list 0 0))))
                                 (esketch-render--rotate
                                  (- tx (* min-size 2)) ty tx ty
                                  (atan (- ty (cadr q)) (- tx (car q))))))))
                      (append (list tx ty) a o b))
                  (append (list tx ty) a b))))))))))

(defun esketch-render--arrowhead-drawables (el main pos head opts bg)
  (let* ((stroke (esketch-get el "strokeColor"))
         (rough (or (plist-get opts :roughness) 0))
         (line-opts
          (let ((o (esketch-render--plist-del opts :strokeLineDash)))
            (when (equal (esketch-get el "strokeStyle") "dotted")
              (setq o (plist-put o :strokeLineDash
                                 (list 1.5 (- (+ 6 (- (esketch-get el "strokeWidth") 1)) 1)))))
            (plist-put o :roughness (min 1 rough))))
         (solid-opts
          (lambda (fill cap)
            (let ((o (esketch-render--plist-del (copy-sequence opts) :strokeLineDash)))
              (setq o (plist-put o :fill fill))
              (setq o (plist-put o :fillStyle "solid"))
              (plist-put o :roughness (min cap rough)))))
         (lines-to-tip
          (lambda (p)
            (when p
              (cl-destructuring-bind (x2 y2 x3 y3 x4 y4) p
                (list (esketch-rough-line x3 y3 x2 y2 line-opts)
                      (esketch-rough-line x4 y4 x2 y2 line-opts))))))
         (card-one
          (lambda (p)
            (when p
              (list (esketch-rough-line (nth 2 p) (nth 3 p) (nth 4 p) (nth 5 p)
                                        line-opts)))))
         (circle
          (lambda (p fill &optional scale)
            (when p
              (let ((o (funcall solid-opts fill 0.5)))
                (setq o (plist-put o :stroke stroke))
                (list (esketch-rough-circle (nth 0 p) (nth 1 p)
                                            (* (nth 2 p) (or scale 1)) o))))))
         (pts (lambda (h &optional off)
                (esketch-render--arrowhead-points el main pos h off))))
    (pcase head
      ((or "circle" "circle_outline")
       (funcall circle (funcall pts head)
                (if (equal head "circle_outline") bg stroke)))
      ((or "triangle" "triangle_outline")
       (let ((p (funcall pts head)))
         (when p
           (cl-destructuring-bind (x y x2 y2 x3 y3) p
             (list (esketch-rough-polygon
                    (list (list x y) (list x2 y2) (list x3 y3) (list x y))
                    (funcall solid-opts
                             (if (equal head "triangle_outline") bg stroke) 1)))))))
      ((or "diamond" "diamond_outline")
       (let ((p (funcall pts head)))
         (when p
           (cl-destructuring-bind (x y x2 y2 x3 y3 x4 y4) p
             (list (esketch-rough-polygon
                    (list (list x y) (list x2 y2) (list x3 y3) (list x4 y4)
                          (list x y))
                    (funcall solid-opts
                             (if (equal head "diamond_outline") bg stroke) 1)))))))
      ("cardinality_one" (funcall card-one (funcall pts head)))
      ("cardinality_many" (funcall lines-to-tip (funcall pts head)))
      ("cardinality_one_or_many"
       (append (funcall lines-to-tip (funcall pts "cardinality_many"))
               (funcall card-one (funcall pts "cardinality_one" -0.25))))
      ("cardinality_exactly_one"
       (append (funcall card-one (funcall pts "cardinality_one" -0.5))
               (funcall card-one (funcall pts "cardinality_one"))))
      ("cardinality_zero_or_one"
       (append (funcall circle (funcall pts "circle_outline" 1.5) bg 0.8)
               (funcall card-one (funcall pts "cardinality_one" -0.5))))
      ("cardinality_zero_or_many"
       (append (funcall lines-to-tip (funcall pts "cardinality_many"))
               (funcall circle (funcall pts "circle_outline" 1.5) bg 0.8)))
      (_ (funcall lines-to-tip (funcall pts head))))))

;;;; SVG text

(defun esketch-render--xml (s)
  (replace-regexp-in-string
   "[&<>\"]"
   (lambda (m) (pcase m ("&" "&amp;") ("<" "&lt;") (">" "&gt;") (_ "&quot;")))
   s t t))

(defun esketch-render--attrs (&rest kv)
  (let ((out nil))
    (while kv
      (when (cadr kv)
        (push (format " %s=\"%s\"" (car kv)
                      (let ((v (cadr kv)))
                        (esketch-render--xml (if (numberp v) (esketch-render--num v) v))))
              out))
      (setq kv (cddr kv)))
    (apply #'concat (nreverse out))))

(defun esketch-render--drawable-svg (drawable &optional extra)
  "SVG for DRAWABLE as roughjs's RoughSVG.draw writes it, with 2 decimals.
EXTRA is a string of attributes for the enclosing <g>."
  (let ((o (plist-get drawable :options))
        (paths nil))
    (dolist (set (plist-get drawable :sets))
      (let ((d (esketch-render--ops-to-path set esketch-render--decimals)))
        (push
         (pcase (plist-get set :type)
           ('path
            (format "<path%s/>"
                    (esketch-render--attrs
                     "d" d "stroke" (plist-get o :stroke)
                     "stroke-width" (plist-get o :strokeWidth) "fill" "none"
                     "stroke-dasharray"
                     (let ((dash (plist-get o :strokeLineDash)))
                       (and dash (mapconcat #'esketch-render--num dash " "))))))
           ('fillPath
            (format "<path%s/>"
                    (esketch-render--attrs
                     "d" d "stroke" "none" "stroke-width" "0"
                     "fill" (or (plist-get o :fill) "")
                     "fill-rule" (and (member (plist-get drawable :shape)
                                            '("curve" "polygon"))
                                      "evenodd"))))
           ('fillSketch
            (let ((fw (plist-get o :fillWeight)))
              (format "<path%s/>"
                      (esketch-render--attrs
                       "d" d "stroke" (or (plist-get o :fill) "")
                       "stroke-width" (if (< fw 0) (/ (plist-get o :strokeWidth) 2.0) fw)
                       "fill" "none")))))
         paths)))
    (concat "<g" (or extra "") ">" (apply #'concat (nreverse paths)) "</g>")))

(defconst esketch-render--fonts
  ;; id name generic-fallback units-per-em ascender descender
  '((1 "Virgil" "sans-serif" 1000 886 -374)
    (2 "Helvetica" "sans-serif" 2048 1577 -471)
    (3 "Cascadia" "monospace" 2048 1900 -480)
    (5 "Excalifont" "sans-serif" 1000 886 -374)
    (6 "Nunito" "sans-serif" 1000 1011 -353)
    (7 "Lilita One" "sans-serif" 1000 923 -220)
    (8 "Comic Shanns" "monospace" 1000 750 -250)
    (9 "Liberation Sans" "sans-serif" 2048 1854 -434)
    (10 "Assistant" "sans-serif" 2048 1021 -287))
  "Excalidraw's font ids and the hhea metrics it places text with.")

(defun esketch-render--font-family (id)
  (let ((f (assq id esketch-render--fonts)))
    (if (not f)
        "Segoe UI Emoji"
      (concat (nth 1 f) (if (= id 5) ", Xiaolai" "") ", " (nth 2 f)
              ", Segoe UI Emoji"))))

(defun esketch-render--vertical-offset (id font-size line-px)
  (let* ((m (or (assq id esketch-render--fonts) (assq 5 esketch-render--fonts)))
         (em (/ (float font-size) (nth 3 m)))
         (gap (/ (+ (- line-px (* em (nth 4 m))) (* em (nth 5 m))) 2)))
    (+ (* em (nth 4 m)) gap)))

(defun esketch-render--text-svg (el)
  (let* ((lines (split-string (replace-regexp-in-string
                               "\r\n?" "\n" (esketch-get el "text"))
                              "\n"))
         (size (esketch-get el "fontSize"))
         (line-px (* size (esketch-get el "lineHeight")))
         (align (esketch-get el "textAlign"))
         (x (pcase align
              ("center" (/ (esketch-get el "width") 2.0))
              ("right" (esketch-get el "width"))
              (_ 0)))
         (voff (esketch-render--vertical-offset (esketch-get el "fontFamily")
                                                size line-px))
         (anchor (pcase align ("center" "middle") ("right" "end") (_ "start")))
         (i -1))
    (mapconcat
     (lambda (line)
       (setq i (1+ i))
       (format "<text%s>%s</text>"
               (esketch-render--attrs
                "x" x "y" (+ (* i line-px) voff)
                "font-family" (esketch-render--font-family
                               (esketch-get el "fontFamily"))
                "font-size" (concat (esketch-render--num size) "px")
                "fill" (esketch-get el "strokeColor")
                "text-anchor" anchor "style" "white-space: pre;"
                "direction" "ltr" "dominant-baseline" "alphabetic")
               (esketch-render--xml line)))
     lines "")))

;;;; Legacy and incomplete elements

(defconst esketch-render--line-heights
  '((1 . 1.25) (2 . 1.15) (3 . 1.2) (5 . 1.25) (6 . 1.25) (7 . 1.15)
    (8 . 1.25) (9 . 1.15) (10 . 1.25))
  "Excalidraw's default line height per font id.")

(defun esketch-render--js-or (v default)
  "JavaScript's V || DEFAULT."
  (if (or (null v) (eq v :null) (eq v :false) (equal v "") (equal v 0) (equal v 0.0))
      default
    v))

(defun esketch-render--js-nullish (v default)
  "JavaScript's V ?? DEFAULT."
  (if (or (null v) (eq v :null)) default v))

(defun esketch-render--arrowhead (head)
  (pcase head
    ((or 'nil :null) :null)
    ("dot" "circle")
    ("crowfoot_one" "cardinality_one")
    ("crowfoot_many" "cardinality_many")
    ("crowfoot_one_or_many" "cardinality_one_or_many")
    (_ head)))

(defun esketch-render--restore (el)
  "A copy of EL with the defaults Excalidraw's restore fills in on load.
Only drawing sees the copy; the document itself is never changed."
  (let* ((e (copy-tree el t))
         (type (esketch-get e "type"))
         (set (lambda (k v) (esketch-put e k v))))
    (funcall set "fillStyle" (esketch-render--js-or (esketch-get e "fillStyle") "solid"))
    (funcall set "strokeWidth" (esketch-render--js-or (esketch-get e "strokeWidth") 2))
    (funcall set "strokeStyle" (esketch-render--js-nullish (esketch-get e "strokeStyle") "solid"))
    (funcall set "roughness" (esketch-render--js-nullish (esketch-get e "roughness") 1))
    (funcall set "opacity" (esketch-render--js-nullish (esketch-get e "opacity") 100))
    (funcall set "angle" (esketch-render--js-or (esketch-get e "angle") 0))
    (funcall set "x" (esketch-render--js-nullish (esketch-get e "x") 0))
    (funcall set "y" (esketch-render--js-nullish (esketch-get e "y") 0))
    (funcall set "strokeColor" (esketch-render--js-or (esketch-get e "strokeColor") "#1e1e1e"))
    (funcall set "backgroundColor"
             (esketch-render--js-or (esketch-get e "backgroundColor") "transparent"))
    (funcall set "width" (esketch-render--js-or (esketch-get e "width") 0))
    (funcall set "height" (esketch-render--js-or (esketch-get e "height") 0))
    (funcall set "seed" (esketch-render--js-nullish (esketch-get e "seed") 1))
    (funcall set "roundness"
             (cond ((esketch-obj-p (esketch-get e "roundness")) (esketch-get e "roundness"))
                   ((equal (esketch-get e "strokeSharpness") "round")
                    (list :obj (cons "type"
                                     (if (member type '("rectangle" "embeddable" "iframe" "image"))
                                         1 2))))
                   (t :null)))
    (pcase type
      ("text"
       (let* ((size (let ((s (esketch-get e "fontSize"))) (if (numberp s) s 20)))
              (family (esketch-render--js-nullish (esketch-get e "fontFamily") 5))
              (text (let ((s (esketch-get e "text"))) (if (stringp s) s "")))
              (h (esketch-get e "height"))
              (detected (and (numberp h) (> h 0)
                             (/ (float h) (length (split-string text "\r\n?\\|\n")) size))))
         (funcall set "fontSize" size)
         (funcall set "fontFamily" family)
         (funcall set "text" text)
         (funcall set "textAlign" (esketch-render--js-or (esketch-get e "textAlign") "left"))
         (funcall set "lineHeight"
                  (esketch-render--js-or
                   (esketch-get e "lineHeight")
                   (if (and detected (> detected 0)) detected
                     (or (cdr (assq family esketch-render--line-heights)) 1.25))))))
      ((or "line" "draw" "arrow")
       (unless (and (vectorp (esketch-get e "points")) (> (length (esketch-get e "points")) 0))
         (funcall set "points" (vector (vector 0 0)
                                       (vector (esketch-get e "width") (esketch-get e "height")))))
       (let* ((pts (append (esketch-get e "points") nil))
              (p0 (car pts)))
         (when (or (/= (aref p0 0) 0) (/= (aref p0 1) 0))
           (funcall set "x" (+ (esketch-get e "x") (aref p0 0)))
           (funcall set "y" (+ (esketch-get e "y") (aref p0 1)))
           (setq pts (mapcar (lambda (p) (vector (- (aref p 0) (aref p0 0))
                                                 (- (aref p 1) (aref p0 1))))
                             pts))
           (funcall set "points" (vconcat pts)))
         (let ((xs (mapcar (lambda (p) (aref p 0)) pts))
               (ys (mapcar (lambda (p) (aref p 1)) pts)))
           (funcall set "width" (- (apply #'max xs) (apply #'min xs)))
           (funcall set "height" (- (apply #'max ys) (apply #'min ys)))))
       (funcall set "startArrowhead" (esketch-render--arrowhead (esketch-get e "startArrowhead")))
       (if (equal type "arrow")
           (funcall set "endArrowhead"
                    (if (esketch-has e "endArrowhead")
                        (esketch-render--arrowhead (esketch-get e "endArrowhead"))
                      "arrow"))
         (funcall set "type" "line")
         (funcall set "endArrowhead" (esketch-render--arrowhead (esketch-get e "endArrowhead"))))))
    e))

(defun esketch-render--invisible-p (el)
  "Non-nil for what Excalidraw drops before exporting: deleted elements,
empty text, and elements too small to see (isInvisiblySmallElement)."
  (let ((type (esketch-get el "type"))
        (pts (esketch-get el "points")))
    (or (not (esketch-live-p el))
        (and (equal type "text")
             (let ((s (esketch-get el "text"))) (or (not (stringp s)) (equal s ""))))
        (if (member type '("arrow" "line" "draw" "freedraw"))
            (and (vectorp pts)
                 (or (< (length pts) 2)
                     (and (= (length pts) 2) (equal type "arrow")
                          (< (abs (- (aref (aref pts 0) 0) (aref (aref pts 1) 0))) 0.1)
                          (< (abs (- (aref (aref pts 0) 1) (aref (aref pts 1) 1))) 0.1))))
          (and (equal (esketch-get el "width") 0) (equal (esketch-get el "height") 0))))))

;;;; Elements and documents

(defun esketch-render--local-bounds (el)
  "Unrotated bounds of EL relative to its x, y: (X1 Y1 X2 Y2)."
  (if (member (esketch-get el "type") '("arrow" "line" "freedraw"))
      (let ((xs (mapcar #'car (esketch-render--points el)))
            (ys (mapcar #'cadr (esketch-render--points el))))
        (list (apply #'min xs) (apply #'min ys) (apply #'max xs) (apply #'max ys)))
    (list 0 0 (esketch-get el "width") (esketch-get el "height"))))

(defun esketch-render--text-origin (doc el)
  "Where text EL is drawn: inside an arrow it sits on the arrow's middle."
  (let* ((cid (esketch-get el "containerId"))
         (c (and (stringp cid) (esketch-element doc cid))))
    (if (and c (equal (esketch-get c "type") "arrow"))
        (let* ((pts (esketch-render--points c))
               (n (length pts))
               (mid (if (cl-oddp n)
                        (nth (/ n 2) pts)
                      (let ((a (nth (1- (/ n 2)) pts)) (b (nth (/ n 2) pts)))
                        (list (/ (+ (car a) (car b)) 2.0)
                              (/ (+ (cadr a) (cadr b)) 2.0))))))
          (list (- (+ (esketch-get c "x") (car mid)) (/ (esketch-get el "width") 2.0))
                (- (+ (esketch-get c "y") (cadr mid)) (/ (esketch-get el "height") 2.0))))
      (list (esketch-get el "x") (esketch-get el "y")))))

(defun esketch-render-element-svg (doc el dx dy &optional bg)
  "SVG for element EL of DOC, shifted by DX, DY.  BG is the canvas color."
  (let* ((type (esketch-get el "type"))
         (origin (if (equal type "text") (esketch-render--text-origin doc el)
                   (list (esketch-get el "x") (esketch-get el "y"))))
         (ox (+ (car origin) dx)) (oy (+ (cadr origin) dy))
         (b (esketch-render--local-bounds el))
         (cx (/ (+ (nth 0 b) (nth 2 b)) 2.0))
         (cy (/ (+ (nth 1 b) (nth 3 b)) 2.0))
         (deg (/ (* 180 (or (esketch-get el "angle") 0)) float-pi))
         (opacity (/ (or (esketch-get el "opacity") 100) 100.0))
         (fade (and (/= opacity 1)
                    (esketch-render--attrs "stroke-opacity" opacity
                                           "fill-opacity" opacity)))
         (transform (esketch-render--attrs
                     "transform"
                     (format "translate(%s %s) rotate(%s %s %s)"
                             (esketch-render--num ox) (esketch-render--num oy)
                             (esketch-render--num deg) (esketch-render--num cx)
                             (esketch-render--num cy)))))
    (pcase type
      ((or "rectangle" "diamond" "ellipse")
       (mapconcat (lambda (d)
                    (esketch-render--drawable-svg
                     d (concat fade " stroke-linecap=\"round\"" transform)))
                  (esketch-render--shape-drawables el bg) ""))
      ((or "line" "arrow")
       (concat "<g stroke-linecap=\"round\">"
               (mapconcat
                (lambda (d)
                  (esketch-render--drawable-svg
                   d (concat fade transform
                             (and (equal type "line")
                                  (esketch-render--loop-p (esketch-render--points el))
                                  (not (equal (esketch-get el "backgroundColor")
                                              "transparent"))
                                  " fill-rule=\"evenodd\""))))
                (esketch-render--shape-drawables el bg) "")
               "</g>"))
      ("freedraw"
       (format "<g%s%s>%s<path%s/></g>" transform (or fade "")
               (if (esketch-render--loop-p (esketch-render--points el))
                   (let ((svg (esketch-render--drawable-svg
                               (esketch-rough-curve
                                (esketch-rough--simplify (esketch-render--points el) 0.75)
                                (plist-put (esketch-render--options el) :stroke "none")))))
                     (substring svg 3 -4))
                 "")
               (esketch-render--attrs "fill" (esketch-get el "strokeColor")
                                      "d" (esketch-freehand-svg-path el))))
      ("text"
       (format "<g%s%s>%s</g>" (or fade "") transform (esketch-render--text-svg el)))
      (_ ""))))

(defun esketch-render--doc-bounds (doc)
  (let (x1 y1 x2 y2)
    (mapc (lambda (el)
            (when (esketch-live-p el)
              (let* ((b (esketch-render--local-bounds el))
                     (o (if (equal (esketch-get el "type") "text")
                            (esketch-render--text-origin doc el)
                          (list (esketch-get el "x") (esketch-get el "y"))))
                     (ax1 (+ (car o) (nth 0 b))) (ay1 (+ (cadr o) (nth 1 b)))
                     (ax2 (+ (car o) (nth 2 b))) (ay2 (+ (cadr o) (nth 3 b))))
                (setq x1 (if x1 (min x1 ax1) ax1) y1 (if y1 (min y1 ay1) ay1)
                      x2 (if x2 (max x2 ax2) ax2) y2 (if y2 (max y2 ay2) ay2)))))
          (esketch-elements doc))
    (if x1 (list x1 y1 x2 y2) (list 0 0 0 0))))

(defun esketch-render-svg (doc)
  "DOC as one standalone SVG document string."
  (let* ((doc (list :obj
                    (cons "elements"
                          (vconcat (mapcar #'esketch-render--restore
                                           (cl-remove-if #'esketch-render--invisible-p
                                                         (esketch-elements doc)))))
                    (cons "appState" (esketch-get doc "appState"))))
         (pad esketch-render--padding)
         (bg (let ((app (esketch-get doc "appState")))
               (or (and app (stringp (esketch-get app "viewBackgroundColor"))
                        (esketch-get app "viewBackgroundColor"))
                   "#ffffff")))
         (b (esketch-render--doc-bounds doc))
         (w (+ (- (nth 2 b) (nth 0 b)) (* 2 pad)))
         (h (+ (- (nth 3 b) (nth 1 b)) (* 2 pad)))
         (dx (+ (- (nth 0 b)) pad)) (dy (+ (- (nth 1 b)) pad)))
    (concat
     (format "<svg%s>"
             (esketch-render--attrs
              "version" "1.1" "xmlns" "http://www.w3.org/2000/svg"
              "viewBox" (format "0 0 %s %s" (esketch-render--num w)
                                (esketch-render--num h))
              "width" w "height" h))
     (format "<rect%s/>" (esketch-render--attrs "x" 0 "y" 0 "width" w "height" h
                                                "fill" bg))
     (mapconcat (lambda (el)
                  (if (esketch-live-p el)
                      (esketch-render-element-svg doc el dx dy bg)
                    ""))
                (esketch-elements doc) "")
     "</svg>")))

(provide 'esketch-render)
;;; esketch-render.el ends here
