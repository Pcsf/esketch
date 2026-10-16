;;; esketch-rough.el --- roughjs 4.6.4 generator for esketch  -*- lexical-binding: t; -*-

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

;; This file is a port of roughjs 4.6.4 (with path-data-parser,
;; points-on-path, points-on-curve and hachure-fill), which is MIT licensed:
;;
;;   MIT License
;;
;;   Copyright (c) 2019 Preet Shihn
;;
;;   Permission is hereby granted, free of charge, to any person obtaining a
;;   copy of this software and associated documentation files (the
;;   "Software"), to deal in the Software without restriction, including
;;   without limitation the rights to use, copy, modify, merge, publish,
;;   distribute, sublicense, and/or sell copies of the Software, and to
;;   permit persons to whom the Software is furnished to do so, subject to
;;   the following conditions:
;;
;;   The above copyright notice and this permission notice shall be included
;;   in all copies or substantial portions of the Software.
;;
;;   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
;;   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
;;   IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
;;   CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
;;   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
;;   SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

;;; Commentary:

;; Produces the same hand-drawn geometry as Excalidraw's roughjs 4.6.4
;; generator, number for number, from pure Emacs Lisp.  Arithmetic keeps
;; roughjs's order of floating-point operations, and the seeded generator
;; reproduces Math.imul's signed 32-bit wraparound.
;;
;; Options are a plist whose keys are roughjs option names (:seed,
;; :roughness, :fillStyle, ...).  A missing key takes the roughjs default.
;;
;; Every shape function returns a drawable
;;   (:shape NAME :options FULL-OPTIONS :sets SETS)
;; where each set is (:type TYPE :ops OPS), TYPE is path, fillPath or
;; fillSketch, and each op is (OP . NUMBERS) with OP move, bcurveTo or lineTo.
;;
;; roughjs draws dot fills with Math.random, and uses it when the seed is 0.
;; `esketch-rough-math-random' stands in for it so callers can make those
;; reproducible.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'esketch-json)

;;;; Random

(defvar esketch-rough-math-random #'esketch-rough--default-random
  "Function of no arguments returning a float in [0, 1), like Math.random.")

(defun esketch-rough--default-random ()
  (/ (float (random 1073741824)) 1073741824.0))

(defun esketch-rough--imul (a b)
  "Math.imul of A and B."
  (let ((r (logand (* a b) #xFFFFFFFF)))
    (if (>= r #x80000000) (- r #x100000000) r)))

(defun esketch-rough--random-next (r)
  "Next value of the roughjs Random R, a cons whose car is its state."
  (let ((s (car r)))
    (if (/= s 0)
        (let ((n (esketch-rough--imul 48271 s)))
          (setcar r n)
          (/ (float (logand #x7FFFFFFF n)) 2147483648.0))
      (funcall esketch-rough-math-random))))

(defun esketch-rough--random (o)
  "Draw from the randomizer of options O, creating it on first use."
  (let ((cell (plist-get o :randomizer)))
    (unless cell
      (setq cell (list (plist-get o :seed)))
      (setcar (cdr (plist-member o :randomizer)) cell))
    (esketch-rough--random-next cell)))

;;;; Options

(defconst esketch-rough--defaults
  '(:maxRandomnessOffset 2.0 :roughness 1.0 :bowing 1.0 :stroke "#000"
    :strokeWidth 1.0 :curveTightness 0.0 :curveFitting 0.95
    :curveStepCount 9.0 :fillStyle "hachure" :fillWeight -1.0
    :hachureAngle -41.0 :hachureGap -1.0 :dashOffset -1.0 :dashGap -1.0
    :zigzagOffset -1.0 :seed 0 :disableMultiStroke nil
    :disableMultiStrokeFill nil :preserveVertices nil
    :fillShapeRoughnessGain 0.8))

(defun esketch-rough--options (opts)
  "The roughjs defaults overridden by plist OPTS."
  (let ((o (copy-sequence esketch-rough--defaults)))
    (while opts
      (let ((k (car opts)) (v (cadr opts)))
        (when v
          (setq o (plist-put o k (cond ((eq k :seed) (truncate v))
                                       ((numberp v) (float v))
                                       (t v))))))
      (setq opts (cddr opts)))
    o))

(defun esketch-rough--internal (full)
  (append (copy-sequence full) (list :randomizer nil)))

(defun esketch-rough--with (o &rest kvs)
  "A copy of O with KVS set; the copy shares O's randomizer."
  (let ((c (copy-sequence o)))
    (while kvs
      (setq c (plist-put c (car kvs) (cadr kvs)))
      (setq kvs (cddr kvs)))
    c))

(defun esketch-rough--clone-alter-seed (o)
  (let ((c (copy-sequence o)) (seed (plist-get o :seed)))
    (setcar (cdr (plist-member c :randomizer)) nil)
    (when (/= seed 0) (plist-put c :seed (1+ seed)))
    c))

(defun esketch-rough--truthy (v)
  (and v (not (equal v ""))))

(defun esketch-rough--floats (points)
  (mapcar (lambda (p) (list (float (car p)) (float (cadr p)))) points))

;;;; Offsets and lines

(defun esketch-rough--offset (min max o &optional gain)
  (* (* (plist-get o :roughness) (or gain 1.0))
     (+ (* (esketch-rough--random o) (- max min)) min)))

(defun esketch-rough--offset-opt (x o &optional gain)
  (esketch-rough--offset (- x) x o gain))

(defun esketch-rough--line-ops (x1 y1 x2 y2 o move overlay)
  (let* ((dx (- x1 x2)) (dy (- y1 y2))
         (length-sq (+ (* dx dx) (* dy dy)))
         (len (sqrt length-sq))
         (gain (cond ((< len 200) 1.0)
                     ((> len 500) 0.4)
                     (t (+ (* -0.0016668 len) 1.233334))))
         (offset (or (plist-get o :maxRandomnessOffset) 0.0))
         (offset (if (> (* (* offset offset) 100.0) length-sq)
                     (/ len 10.0)
                   offset))
         (half-offset (/ offset 2.0))
         (diverge (+ 0.2 (* (esketch-rough--random o) 0.2)))
         (bowing (plist-get o :bowing))
         (max-ro (plist-get o :maxRandomnessOffset))
         (mid-x (/ (* (* bowing max-ro) (- y2 y1)) 200.0))
         (mid-y (/ (* (* bowing max-ro) (- x1 x2)) 200.0))
         (mid-x (esketch-rough--offset-opt mid-x o gain))
         (mid-y (esketch-rough--offset-opt mid-y o gain))
         (pv (plist-get o :preserveVertices))
         (half (lambda () (esketch-rough--offset-opt half-offset o gain)))
         (full (lambda () (esketch-rough--offset-opt offset o gain)))
         (ops nil))
    (when move
      (let ((r (if overlay half full)))
        (push (list 'move
                    (+ x1 (if pv 0.0 (funcall r)))
                    (+ y1 (if pv 0.0 (funcall r))))
              ops)))
    (let ((r (if overlay half full)))
      (push (list 'bcurveTo
                  (+ mid-x x1 (* (- x2 x1) diverge) (funcall r))
                  (+ mid-y y1 (* (- y2 y1) diverge) (funcall r))
                  (+ mid-x x1 (* (* 2.0 (- x2 x1)) diverge) (funcall r))
                  (+ mid-y y1 (* (* 2.0 (- y2 y1)) diverge) (funcall r))
                  (+ x2 (if pv 0.0 (funcall r)))
                  (+ y2 (if pv 0.0 (funcall r))))
            ops))
    (nreverse ops)))

(defun esketch-rough--double-line (x1 y1 x2 y2 o &optional filling)
  (let* ((single (plist-get o (if filling :disableMultiStrokeFill
                                :disableMultiStroke)))
         (o1 (esketch-rough--line-ops x1 y1 x2 y2 o t nil)))
    (if single
        o1
      (append o1 (esketch-rough--line-ops x1 y1 x2 y2 o t t)))))

(defun esketch-rough--set (type ops)
  (list :type type :ops ops))

(defun esketch-rough--linear-path (points close o)
  (let* ((pv (vconcat points)) (len (length pv)))
    (cond
     ((> len 2)
      (let ((ops nil))
        (dotimes (i (1- len))
          (let ((a (aref pv i)) (b (aref pv (1+ i))))
            (setq ops (nconc ops (esketch-rough--double-line
                                  (car a) (cadr a) (car b) (cadr b) o)))))
        (when close
          (let ((a (aref pv (1- len))) (b (aref pv 0)))
            (setq ops (nconc ops (esketch-rough--double-line
                                  (car a) (cadr a) (car b) (cadr b) o)))))
        (esketch-rough--set 'path ops)))
     ((= len 2)
      (let ((a (aref pv 0)) (b (aref pv 1)))
        (esketch-rough--set 'path (esketch-rough--double-line
                                   (car a) (cadr a) (car b) (cadr b) o))))
     (t (esketch-rough--set 'path nil)))))

(defun esketch-rough--rectangle-set (x y w h o)
  (esketch-rough--linear-path
   (list (list x y) (list (+ x w) y) (list (+ x w) (+ y h)) (list x (+ y h)))
   t o))

;;;; Curves

(defun esketch-rough--curve-ops (points o)
  "The bcurveTo ops of roughjs's _curve for POINTS."
  (let* ((pv (vconcat points)) (len (length pv)) (ops nil))
    (cond
     ((> len 3)
      (let ((s (- 1.0 (plist-get o :curveTightness))))
        (push (list 'move (car (aref pv 1)) (cadr (aref pv 1))) ops)
        (let ((i 1))
          (while (< (+ i 2) len)
            (let ((c (aref pv i)) (n (aref pv (1+ i)))
                  (pr (aref pv (1- i))) (n2 (aref pv (+ i 2))))
              (push (list 'bcurveTo
                          (+ (car c) (/ (- (* s (car n)) (* s (car pr))) 6.0))
                          (+ (cadr c) (/ (- (* s (cadr n)) (* s (cadr pr))) 6.0))
                          (+ (car n) (/ (- (* s (car c)) (* s (car n2))) 6.0))
                          (+ (cadr n) (/ (- (* s (cadr c)) (* s (cadr n2))) 6.0))
                          (car n) (cadr n))
                    ops))
            (setq i (1+ i))))))
     ((= len 3)
      (push (list 'move (car (aref pv 1)) (cadr (aref pv 1))) ops)
      (push (list 'bcurveTo
                  (car (aref pv 1)) (cadr (aref pv 1))
                  (car (aref pv 2)) (cadr (aref pv 2))
                  (car (aref pv 2)) (cadr (aref pv 2)))
            ops))
     ((= len 2)
      (setq ops (reverse (esketch-rough--double-line
                          (car (aref pv 0)) (cadr (aref pv 0))
                          (car (aref pv 1)) (cadr (aref pv 1)) o)))))
    (nreverse ops)))

(defun esketch-rough--curve-with-offset (points offset o)
  (let* ((pv (vconcat points)) (len (length pv)) (ps nil))
    (dotimes (_ 2)
      (push (list (+ (car (aref pv 0)) (esketch-rough--offset-opt offset o))
                  (+ (cadr (aref pv 0)) (esketch-rough--offset-opt offset o)))
            ps))
    (cl-loop for i from 1 below len
             do (dotimes (_ (if (= i (1- len)) 2 1))
                  (push (list (+ (car (aref pv i))
                                 (esketch-rough--offset-opt offset o))
                              (+ (cadr (aref pv i))
                                 (esketch-rough--offset-opt offset o)))
                        ps)))
    (esketch-rough--curve-ops (nreverse ps) o)))

(defun esketch-rough--curve (points o)
  (let* ((roughness (plist-get o :roughness))
         (o1 (esketch-rough--curve-with-offset
              points (* 1.0 (+ 1.0 (* roughness 0.2))) o)))
    (unless (plist-get o :disableMultiStroke)
      (setq o1 (append o1 (esketch-rough--curve-with-offset
                           points (* 1.5 (+ 1.0 (* roughness 0.22)))
                           (esketch-rough--clone-alter-seed o)))))
    (esketch-rough--set 'path o1)))

;;;; Ellipse

(defun esketch-rough--ellipse-params (width height o)
  (let* ((psq (sqrt (* (* float-pi 2.0)
                       (sqrt (/ (+ (expt (/ width 2.0) 2) (expt (/ height 2.0) 2))
                                2.0)))))
         (step-count (float
                      (ceiling
                       (max (plist-get o :curveStepCount)
                            (* (/ (plist-get o :curveStepCount) (sqrt 200.0))
                               psq)))))
         (increment (/ (* float-pi 2.0) step-count))
         (rx (abs (/ width 2.0)))
         (ry (abs (/ height 2.0)))
         (randomness (- 1.0 (plist-get o :curveFitting))))
    (setq rx (+ rx (esketch-rough--offset-opt (* rx randomness) o)))
    (setq ry (+ ry (esketch-rough--offset-opt (* ry randomness) o)))
    (list increment rx ry)))

(defun esketch-rough--ellipse-points (increment cx cy rx ry offset overlap o)
  "Cons of (ALL-POINTS) and (CORE-POINTS), as roughjs _computeEllipsePoints."
  (let ((all nil) (core nil))
    (if (= (plist-get o :roughness) 0)
        (progn
          (setq increment (/ increment 4.0))
          (push (list (+ cx (* rx (cos (- increment))))
                      (+ cy (* ry (sin (- increment)))))
                all)
          (let ((angle 0.0))
            (while (<= angle (* float-pi 2.0))
              (let ((p (list (+ cx (* rx (cos angle)))
                             (+ cy (* ry (sin angle))))))
                (push p core)
                (push p all))
              (setq angle (+ angle increment))))
          (push (list (+ cx (* rx (cos 0.0))) (+ cy (* ry (sin 0.0)))) all)
          (push (list (+ cx (* rx (cos increment)))
                      (+ cy (* ry (sin increment))))
                all))
      (let ((rad-offset (- (esketch-rough--offset-opt 0.5 o) (/ float-pi 2.0))))
        (push (list (+ (esketch-rough--offset-opt offset o) cx
                       (* (* 0.9 rx) (cos (- rad-offset increment))))
                    (+ (esketch-rough--offset-opt offset o) cy
                       (* (* 0.9 ry) (sin (- rad-offset increment)))))
              all)
        (let ((end-angle (- (+ (* float-pi 2.0) rad-offset) 0.01))
              (angle rad-offset))
          (while (< angle end-angle)
            (let ((p (list (+ (esketch-rough--offset-opt offset o) cx
                              (* rx (cos angle)))
                           (+ (esketch-rough--offset-opt offset o) cy
                              (* ry (sin angle))))))
              (push p core)
              (push p all))
            (setq angle (+ angle increment))))
        (push (list (+ (esketch-rough--offset-opt offset o) cx
                       (* rx (cos (+ rad-offset (* float-pi 2.0)
                                     (* overlap 0.5)))))
                    (+ (esketch-rough--offset-opt offset o) cy
                       (* ry (sin (+ rad-offset (* float-pi 2.0)
                                     (* overlap 0.5))))))
              all)
        (push (list (+ (esketch-rough--offset-opt offset o) cx
                       (* (* 0.98 rx) (cos (+ rad-offset overlap))))
                    (+ (esketch-rough--offset-opt offset o) cy
                       (* (* 0.98 ry) (sin (+ rad-offset overlap)))))
              all)
        (push (list (+ (esketch-rough--offset-opt offset o) cx
                       (* (* 0.9 rx) (cos (+ rad-offset (* overlap 0.5)))))
                    (+ (esketch-rough--offset-opt offset o) cy
                       (* (* 0.9 ry) (sin (+ rad-offset (* overlap 0.5))))))
              all)))
    (cons (nreverse all) (nreverse core))))

(defun esketch-rough--ellipse-with-params (x y o params)
  "Cons of the estimated points and the outline set."
  (let* ((increment (nth 0 params)) (rx (nth 1 params)) (ry (nth 2 params))
         (pts (esketch-rough--ellipse-points
               increment x y rx ry 1.0
               (* increment (esketch-rough--offset
                             0.1 (esketch-rough--offset 0.4 1.0 o) o))
               o))
         (o1 (esketch-rough--curve-ops (car pts) o)))
    (when (and (not (plist-get o :disableMultiStroke))
               (/= (plist-get o :roughness) 0))
      (let ((pts2 (esketch-rough--ellipse-points increment x y rx ry 1.5 0.0 o)))
        (setq o1 (append o1 (esketch-rough--curve-ops (car pts2) o)))))
    (cons (cdr pts) (esketch-rough--set 'path o1))))

(defun esketch-rough--ellipse-set (x y width height o)
  (cdr (esketch-rough--ellipse-with-params
        x y o (esketch-rough--ellipse-params width height o))))

;;;; Path data (path-data-parser)

(defconst esketch-rough--param-counts
  '((?A . 7) (?a . 7) (?C . 6) (?c . 6) (?H . 1) (?h . 1) (?L . 2) (?l . 2)
    (?M . 2) (?m . 2) (?Q . 4) (?q . 4) (?S . 4) (?s . 4) (?T . 2) (?t . 2)
    (?V . 1) (?v . 1) (?Z . 0) (?z . 0)))

(defun esketch-rough--number-token (text)
  (float (string-to-number
          (replace-regexp-in-string "\\.\\([eE]\\|\\'\\)" ".0\\1" text))))

(defun esketch-rough--tokenize (d)
  "Tokens of path data D: (cmd . CHAR), (num . FLOAT) and a final (eod)."
  (let ((tokens nil))
    (while (not (string= d ""))
      (cond
       ((string-match "\\`[ \t\r\n,]+" d)
        (setq d (substring d (match-end 0))))
       ((string-match "\\`[aAcChHlLmMqQsStTvVzZ]" d)
        (push (cons 'cmd (aref d 0)) tokens)
        (setq d (substring d 1)))
       ((string-match
         "\\`\\(?:[-+]?[0-9]+\\(?:\\.[0-9]*\\)?\\|[-+]?\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?"
         d)
        (push (cons 'num (esketch-rough--number-token (match-string 0 d)))
              tokens)
        (setq d (substring d (match-end 0))))
       (t (error "esketch-rough: bad path data"))))
    (vconcat (nreverse tokens) (list (list 'eod)))))

(defun esketch-rough--parse-path (d)
  "Segments (CHAR . DATA) of path data D."
  (let* ((tokens (esketch-rough--tokenize d))
         (segments nil) (mode nil) (index 0))
    (cl-block parse
      (while (not (eq (car (aref tokens index)) 'eod))
        (let ((token (aref tokens index)) (count 0) (params nil))
          (cond
           ((null mode)
            (if (memq (cdr token) '(?M ?m))
                (setq index (1+ index)
                      mode (cdr token)
                      count (cdr (assq mode esketch-rough--param-counts)))
              (cl-return-from parse
                (esketch-rough--parse-path (concat "M0,0" d)))))
           ((eq (car token) 'num)
            (setq count (cdr (assq mode esketch-rough--param-counts))))
           (t
            (setq index (1+ index)
                  mode (cdr token)
                  count (cdr (assq mode esketch-rough--param-counts)))))
          (when (and (= count 0) (eq (car token) 'num))
            (error "esketch-rough: bad path data"))
          (unless (< (+ index count) (length tokens))
            (error "esketch-rough: path data ended short"))
          (dotimes (i count)
            (let ((tk (aref tokens (+ index i))))
              (unless (eq (car tk) 'num)
                (error "esketch-rough: parameter is not a number"))
              (push (cdr tk) params)))
          (push (cons mode (nreverse params)) segments)
          (setq index (+ index count))
          (cond ((eq mode ?M) (setq mode ?L))
                ((eq mode ?m) (setq mode ?l)))))
      (nreverse segments))))

(defun esketch-rough--absolutize (segments)
  (let ((cx 0.0) (cy 0.0) (subx 0.0) (suby 0.0) (out nil))
    (dolist (seg segments)
      (let ((data (cdr seg)))
        (cl-case (car seg)
          (?M (push (cons ?M (copy-sequence data)) out)
              (setq cx (nth 0 data) cy (nth 1 data)
                    subx cx suby cy))
          (?m (setq cx (+ cx (nth 0 data)) cy (+ cy (nth 1 data)))
              (push (list ?M cx cy) out)
              (setq subx cx suby cy))
          (?L (push (cons ?L (copy-sequence data)) out)
              (setq cx (nth 0 data) cy (nth 1 data)))
          (?l (setq cx (+ cx (nth 0 data)) cy (+ cy (nth 1 data)))
              (push (list ?L cx cy) out))
          (?C (push (cons ?C (copy-sequence data)) out)
              (setq cx (nth 4 data) cy (nth 5 data)))
          ((?c ?Q ?q ?S ?s)
           (let ((key (upcase (car seg))) (nd data))
             (when (/= (car seg) key)
               (setq nd (cl-loop for v in data for i from 0
                                 collect (if (= (% i 2) 1) (+ v cy) (+ v cx)))))
             (push (cons key (copy-sequence nd)) out)
             (let ((n (length nd)))
               (setq cx (nth (- n 2) nd) cy (nth (- n 1) nd)))))
          (?A (push (cons ?A (copy-sequence data)) out)
              (setq cx (nth 5 data) cy (nth 6 data)))
          (?a (setq cx (+ cx (nth 5 data)) cy (+ cy (nth 6 data)))
              (push (list ?A (nth 0 data) (nth 1 data) (nth 2 data)
                          (nth 3 data) (nth 4 data) cx cy)
                    out))
          (?H (push (cons ?H (copy-sequence data)) out)
              (setq cx (nth 0 data)))
          (?h (setq cx (+ cx (nth 0 data)))
              (push (list ?H cx) out))
          (?V (push (cons ?V (copy-sequence data)) out)
              (setq cy (nth 0 data)))
          (?v (setq cy (+ cy (nth 0 data)))
              (push (list ?V cy) out))
          (?T (push (cons ?T (copy-sequence data)) out)
              (setq cx (nth 0 data) cy (nth 1 data)))
          (?t (setq cx (+ cx (nth 0 data)) cy (+ cy (nth 1 data)))
              (push (list ?T cx cy) out))
          ((?Z ?z) (push (list ?Z) out)
           (setq cx subx cy suby)))))
    (nreverse out)))

(defun esketch-rough--rotate (x y angle)
  (list (- (* x (cos angle)) (* y (sin angle)))
        (+ (* x (sin angle)) (* y (cos angle)))))

(defun esketch-rough--arc-to-cubic (x1 y1 x2 y2 r1 r2 angle large sweep
                                       recursive)
  "Cubic curves approximating an SVG arc, as path-data-parser."
  (let ((angle-rad (/ (* float-pi angle) 180.0))
        (params nil) (f1 0.0) (f2 0.0) (cx 0.0) (cy 0.0))
    (if recursive
        (setq f1 (nth 0 recursive) f2 (nth 1 recursive)
              cx (nth 2 recursive) cy (nth 3 recursive))
      (let* ((p1 (esketch-rough--rotate x1 y1 (- angle-rad)))
             (p2 (esketch-rough--rotate x2 y2 (- angle-rad))))
        (setq x1 (nth 0 p1) y1 (nth 1 p1) x2 (nth 0 p2) y2 (nth 1 p2))
        (let* ((x (/ (- x1 x2) 2.0)) (y (/ (- y1 y2) 2.0))
               (h (+ (/ (* x x) (* r1 r1)) (/ (* y y) (* r2 r2)))))
          (when (> h 1)
            (setq h (sqrt h) r1 (* h r1) r2 (* h r2)))
          (let* ((sign (if (= large sweep) -1.0 1.0))
                 (r1-pow (* r1 r1)) (r2-pow (* r2 r2))
                 (left (- (- (* r1-pow r2-pow) (* (* r1-pow y) y))
                          (* (* r2-pow x) x)))
                 (right (+ (* (* r1-pow y) y) (* (* r2-pow x) x)))
                 (k (* sign (sqrt (abs (/ left right))))))
            (setq cx (+ (/ (* (* k r1) y) r2) (/ (+ x1 x2) 2.0))
                  cy (+ (/ (* (* k (- r2)) x) r1) (/ (+ y1 y2) 2.0)))
            (setq f1 (asin (string-to-number
                            (format "%.9f" (/ (- y1 cy) r2))))
                  f2 (asin (string-to-number
                            (format "%.9f" (/ (- y2 cy) r2)))))
            (setq f1 (float f1) f2 (float f2))
            (when (< x1 cx) (setq f1 (- float-pi f1)))
            (when (< x2 cx) (setq f2 (- float-pi f2)))
            (when (< f1 0) (setq f1 (+ (* float-pi 2.0) f1)))
            (when (< f2 0) (setq f2 (+ (* float-pi 2.0) f2)))
            (when (and (/= sweep 0) (> f1 f2)) (setq f1 (- f1 (* float-pi 2.0))))
            (when (and (= sweep 0) (> f2 f1)) (setq f2 (- f2 (* float-pi 2.0))))))))
    (let ((df (- f2 f1))
          (limit (/ (* float-pi 120.0) 180.0)))
      (when (> (abs df) limit)
        (let ((f2old f2) (x2old x2) (y2old y2))
          (setq f2 (if (and (/= sweep 0) (> f2 f1))
                       (+ f1 (* limit 1.0))
                     (+ f1 (* limit -1.0))))
          (setq x2 (+ cx (* r1 (cos f2))) y2 (+ cy (* r2 (sin f2))))
          (setq params (esketch-rough--arc-to-cubic
                        x2 y2 x2old y2old r1 r2 angle 0.0 sweep
                        (list f2 f2old cx cy)))))
      (setq df (- f2 f1))
      (let* ((c1 (cos f1)) (s1 (sin f1)) (c2 (cos f2)) (s2 (sin f2))
             (tn (tan (/ df 4.0)))
             (hx (* (* (/ 4.0 3.0) r1) tn))
             (hy (* (* (/ 4.0 3.0) r2) tn))
             (m1 (list x1 y1))
             (m2 (list (+ x1 (* hx s1)) (- y1 (* hy c1))))
             (m3 (list (+ x2 (* hx s2)) (- y2 (* hy c2))))
             (m4 (list x2 y2)))
        (setq m2 (list (- (* 2.0 (nth 0 m1)) (nth 0 m2))
                       (- (* 2.0 (nth 1 m1)) (nth 1 m2))))
        (if recursive
            (append (list m2 m3 m4) params)
          (let ((all (vconcat (list m2 m3 m4) params)) (curves nil) (i 0))
            (while (< i (length all))
              (let ((a (esketch-rough--rotate (car (aref all i))
                                              (cadr (aref all i)) angle-rad))
                    (b (esketch-rough--rotate (car (aref all (+ i 1)))
                                              (cadr (aref all (+ i 1)))
                                              angle-rad))
                    (c (esketch-rough--rotate (car (aref all (+ i 2)))
                                              (cadr (aref all (+ i 2)))
                                              angle-rad)))
                (push (append a b c) curves))
              (setq i (+ i 3)))
            (nreverse curves)))))))

(defun esketch-rough--normalize (segments)
  "Segments reduced to M, L, C and Z."
  (let ((out nil) (last-type nil) (cx 0.0) (cy 0.0) (subx 0.0) (suby 0.0)
        (lcx 0.0) (lcy 0.0))
    (dolist (seg segments)
      (let ((key (car seg)) (data (cdr seg)))
        (cl-case key
          (?M (push (cons ?M (copy-sequence data)) out)
              (setq cx (nth 0 data) cy (nth 1 data) subx cx suby cy))
          (?C (push (cons ?C (copy-sequence data)) out)
              (setq cx (nth 4 data) cy (nth 5 data)
                    lcx (nth 2 data) lcy (nth 3 data)))
          (?L (push (cons ?L (copy-sequence data)) out)
              (setq cx (nth 0 data) cy (nth 1 data)))
          (?H (setq cx (nth 0 data))
              (push (list ?L cx cy) out))
          (?V (setq cy (nth 0 data))
              (push (list ?L cx cy) out))
          (?S (let (cx1 cy1)
                (if (memq last-type '(?C ?S))
                    (setq cx1 (+ cx (- cx lcx)) cy1 (+ cy (- cy lcy)))
                  (setq cx1 cx cy1 cy))
                (push (cons ?C (cons cx1 (cons cy1 (copy-sequence data)))) out)
                (setq lcx (nth 0 data) lcy (nth 1 data)
                      cx (nth 2 data) cy (nth 3 data))))
          (?T (let* ((x (nth 0 data)) (y (nth 1 data)) x1 y1)
                (if (memq last-type '(?Q ?T))
                    (setq x1 (+ cx (- cx lcx)) y1 (+ cy (- cy lcy)))
                  (setq x1 cx y1 cy))
                (let ((cx1 (+ cx (/ (* 2.0 (- x1 cx)) 3.0)))
                      (cy1 (+ cy (/ (* 2.0 (- y1 cy)) 3.0)))
                      (cx2 (+ x (/ (* 2.0 (- x1 x)) 3.0)))
                      (cy2 (+ y (/ (* 2.0 (- y1 y)) 3.0))))
                  (push (list ?C cx1 cy1 cx2 cy2 x y) out))
                (setq lcx x1 lcy y1 cx x cy y)))
          (?Q (let* ((x1 (nth 0 data)) (y1 (nth 1 data))
                     (x (nth 2 data)) (y (nth 3 data))
                     (cx1 (+ cx (/ (* 2.0 (- x1 cx)) 3.0)))
                     (cy1 (+ cy (/ (* 2.0 (- y1 cy)) 3.0)))
                     (cx2 (+ x (/ (* 2.0 (- x1 x)) 3.0)))
                     (cy2 (+ y (/ (* 2.0 (- y1 y)) 3.0))))
                (push (list ?C cx1 cy1 cx2 cy2 x y) out)
                (setq lcx x1 lcy y1 cx x cy y)))
          (?A (let ((r1 (abs (nth 0 data))) (r2 (abs (nth 1 data)))
                    (x (nth 5 data)) (y (nth 6 data)))
                (cond
                 ((or (= r1 0) (= r2 0))
                  (push (list ?C cx cy x y x y) out)
                  (setq cx x cy y))
                 ((or (/= cx x) (/= cy y))
                  (dolist (curve (esketch-rough--arc-to-cubic
                                  cx cy x y r1 r2 (nth 2 data) (nth 3 data)
                                  (nth 4 data) nil))
                    (push (cons ?C curve) out))
                  (setq cx x cy y)))))
          (?Z (push (list ?Z) out)
              (setq cx subx cy suby))))
      (setq last-type (car seg)))
    (nreverse out)))

;;;; Points on curves (points-on-curve, points-on-path)

(defun esketch-rough--lerp (a b tt)
  (list (+ (car a) (* (- (car b) (car a)) tt))
        (+ (cadr a) (* (- (cadr b) (cadr a)) tt))))

(defun esketch-rough--dist-sq (p1 p2)
  (let ((dx (- (car p1) (car p2))) (dy (- (cadr p1) (cadr p2))))
    (+ (* dx dx) (* dy dy))))

(defun esketch-rough--dist-to-segment-sq (p v w)
  (let ((l2 (esketch-rough--dist-sq v w)))
    (if (= l2 0)
        (esketch-rough--dist-sq p v)
      (let ((tt (/ (+ (* (- (car p) (car v)) (- (car w) (car v)))
                      (* (- (cadr p) (cadr v)) (- (cadr w) (cadr v))))
                   l2)))
        (setq tt (max 0.0 (min 1.0 tt)))
        (esketch-rough--dist-sq p (esketch-rough--lerp v w tt))))))

(defun esketch-rough--flatness (pv offset)
  (let* ((p1 (aref pv offset)) (p2 (aref pv (+ offset 1)))
         (p3 (aref pv (+ offset 2))) (p4 (aref pv (+ offset 3)))
         (ux (- (- (* 3.0 (car p2)) (* 2.0 (car p1))) (car p4)))
         (uy (- (- (* 3.0 (cadr p2)) (* 2.0 (cadr p1))) (cadr p4)))
         (vx (- (- (* 3.0 (car p3)) (* 2.0 (car p4))) (car p1)))
         (vy (- (- (* 3.0 (cadr p3)) (* 2.0 (cadr p4))) (cadr p1))))
    (setq ux (* ux ux) uy (* uy uy) vx (* vx vx) vy (* vy vy))
    (when (< ux vx) (setq ux vx))
    (when (< uy vy) (setq uy vy))
    (+ ux uy)))

(defun esketch-rough--split-bezier (pv offset tolerance out)
  "Flatten the cubic at OFFSET in PV, pushing points onto (car OUT)."
  (if (< (esketch-rough--flatness pv offset) tolerance)
      (let ((p0 (aref pv offset)))
        (if (car out)
            (when (> (sqrt (esketch-rough--dist-sq (car (car out)) p0)) 1)
              (push p0 (car out)))
          (push p0 (car out)))
        (push (aref pv (+ offset 3)) (car out)))
    (let* ((p1 (aref pv offset)) (p2 (aref pv (+ offset 1)))
           (p3 (aref pv (+ offset 2))) (p4 (aref pv (+ offset 3)))
           (q1 (esketch-rough--lerp p1 p2 0.5))
           (q2 (esketch-rough--lerp p2 p3 0.5))
           (q3 (esketch-rough--lerp p3 p4 0.5))
           (r1 (esketch-rough--lerp q1 q2 0.5))
           (r2 (esketch-rough--lerp q2 q3 0.5))
           (red (esketch-rough--lerp r1 r2 0.5)))
      (esketch-rough--split-bezier (vector p1 q1 r1 red) 0 tolerance out)
      (esketch-rough--split-bezier (vector red r2 q3 p4) 0 tolerance out))))

(defun esketch-rough--simplify-points (pv start end epsilon out)
  "Ramer-Douglas-Peucker over PV[START, END), pushing onto (car OUT)."
  (let ((s (aref pv start)) (e (aref pv (1- end))) (max-d 0.0) (max-n 1))
    (cl-loop for i from (1+ start) below (1- end)
             do (let ((d (esketch-rough--dist-to-segment-sq (aref pv i) s e)))
                  (when (> d max-d) (setq max-d d max-n i))))
    (if (> (sqrt max-d) epsilon)
        (progn
          (esketch-rough--simplify-points pv start (1+ max-n) epsilon out)
          (esketch-rough--simplify-points pv max-n end epsilon out))
      (unless (car out) (push s (car out)))
      (push e (car out)))))

(defun esketch-rough--simplify (points distance)
  (let ((out (list nil)) (pv (vconcat points)))
    (esketch-rough--simplify-points pv 0 (length pv) distance out)
    (nreverse (car out))))

(defun esketch-rough--points-on-bezier-curves (points tolerance &optional distance)
  (let* ((pv (vconcat points))
         (out (list nil))
         (segments (/ (float (1- (length pv))) 3.0))
         (i 0))
    (while (< i segments)
      (esketch-rough--split-bezier pv (* i 3) tolerance out)
      (setq i (1+ i)))
    (let ((new (nreverse (car out))))
      (if (and distance (> distance 0))
          (let ((nv (vconcat new)) (o2 (list nil)))
            (esketch-rough--simplify-points nv 0 (length nv) distance o2)
            (nreverse (car o2)))
        new))))

(defun esketch-rough--points-on-path (d tolerance distance)
  "Polylines approximating path data D, simplified by DISTANCE."
  (let ((normalized (esketch-rough--normalize
                     (esketch-rough--absolutize
                      (esketch-rough--parse-path d))))
        (sets nil) (current nil) (start (list 0.0 0.0)) (pending nil))
    (cl-flet ((append-pending-curve
                ()
                (when (>= (length pending) 4)
                  (dolist (p (esketch-rough--points-on-bezier-curves
                              (reverse pending) tolerance))
                    (push p current)))
                (setq pending nil)))
      (cl-flet ((append-pending-points
                  ()
                  (append-pending-curve)
                  (when current
                    (push (nreverse current) sets)
                    (setq current nil))))
        (dolist (seg normalized)
          (let ((data (cdr seg)))
            (cl-case (car seg)
              (?M (append-pending-points)
                  (setq start (list (nth 0 data) (nth 1 data)))
                  (push start current))
              (?L (append-pending-curve)
                  (push (list (nth 0 data) (nth 1 data)) current))
              (?C (unless pending
                    (let ((last (if current (car current) start)))
                      (push (list (car last) (cadr last)) pending)))
                  (push (list (nth 0 data) (nth 1 data)) pending)
                  (push (list (nth 2 data) (nth 3 data)) pending)
                  (push (list (nth 4 data) (nth 5 data)) pending))
              (?Z (append-pending-curve)
                  (push (list (car start) (cadr start)) current)))))
        (append-pending-points)))
    (setq sets (nreverse sets))
    (if (or (null distance) (= distance 0))
        sets
      (let ((out nil))
        (dolist (set sets)
          (let ((simplified (esketch-rough--simplify set distance)))
            (when simplified (push simplified out))))
        (nreverse out)))))

;;;; SVG path outline

(defun esketch-rough--bezier-to (x1 y1 x2 y2 x y current o)
  (let* ((max-ro (plist-get o :maxRandomnessOffset))
         (ros (vector (if (/= max-ro 0) max-ro 1.0)
                      (+ (if (/= max-ro 0) max-ro 1.0) 0.3)))
         (iterations (if (plist-get o :disableMultiStroke) 1 2))
         (pv (plist-get o :preserveVertices))
         (ops nil))
    (dotimes (i iterations)
      (if (= i 0)
          (push (list 'move (car current) (cadr current)) ops)
        (push (list 'move
                    (+ (car current)
                       (if pv 0.0 (esketch-rough--offset-opt (aref ros 0) o)))
                    (+ (cadr current)
                       (if pv 0.0 (esketch-rough--offset-opt (aref ros 0) o))))
              ops))
      (let ((f (if pv
                   (list x y)
                 (list (+ x (esketch-rough--offset-opt (aref ros i) o))
                       (+ y (esketch-rough--offset-opt (aref ros i) o))))))
        (push (list 'bcurveTo
                    (+ x1 (esketch-rough--offset-opt (aref ros i) o))
                    (+ y1 (esketch-rough--offset-opt (aref ros i) o))
                    (+ x2 (esketch-rough--offset-opt (aref ros i) o))
                    (+ y2 (esketch-rough--offset-opt (aref ros i) o))
                    (car f) (cadr f))
              ops)))
    (nreverse ops)))

(defun esketch-rough--svg-path (d o)
  (let ((ops nil) (first (list 0.0 0.0)) (current (list 0.0 0.0)))
    (dolist (seg (esketch-rough--normalize
                  (esketch-rough--absolutize (esketch-rough--parse-path d))))
      (let ((data (cdr seg)))
        (cl-case (car seg)
          (?M (setq current (list (nth 0 data) (nth 1 data))
                    first (list (nth 0 data) (nth 1 data))))
          (?L (setq ops (nconc ops (esketch-rough--double-line
                                    (car current) (cadr current)
                                    (nth 0 data) (nth 1 data) o)))
              (setq current (list (nth 0 data) (nth 1 data))))
          (?C (setq ops (nconc ops (esketch-rough--bezier-to
                                    (nth 0 data) (nth 1 data) (nth 2 data)
                                    (nth 3 data) (nth 4 data) (nth 5 data)
                                    current o)))
              (setq current (list (nth 4 data) (nth 5 data))))
          (?Z (setq ops (nconc ops (esketch-rough--double-line
                                    (car current) (cadr current)
                                    (car first) (cadr first) o)))
              (setq current (list (car first) (cadr first)))))))
    (esketch-rough--set 'path ops)))

;;;; Fills

(defun esketch-rough--solid-fill-polygon (polygons o)
  (let ((ops nil))
    (dolist (points polygons)
      (when points
        (let ((offset (or (plist-get o :maxRandomnessOffset) 0.0)))
          (when (> (length points) 2)
            (push (list 'move
                        (+ (car (car points))
                           (esketch-rough--offset-opt offset o))
                        (+ (cadr (car points))
                           (esketch-rough--offset-opt offset o)))
                  ops)
            (dolist (p (cdr points))
              (push (list 'lineTo
                          (+ (car p) (esketch-rough--offset-opt offset o))
                          (+ (cadr p) (esketch-rough--offset-opt offset o)))
                    ops))))))
    (esketch-rough--set 'fillPath (nreverse ops))))

(defun esketch-rough--js-round (x)
  (let ((f (ffloor x)))
    (if (>= (- x f) 0.5) (+ f 1.0) f)))

(defun esketch-rough--rotate-points (points degrees)
  "Rotate POINTS in place about the origin by DEGREES."
  (when points
    (let* ((angle (* (/ float-pi 180.0) degrees))
           (c (cos angle)) (s (sin angle)))
      (dolist (p points)
        (let ((x (car p)) (y (cadr p)))
          (setcar p (+ (- (* (- x 0.0) c) (* (- y 0.0) s)) 0.0))
          (setcar (cdr p) (+ (+ (* (- x 0.0) s) (* (- y 0.0) c)) 0.0)))))))

(defun esketch-rough--straight-hachure-lines (polygons gap step)
  (let ((vertex-array nil) (lines nil) (edges nil))
    (dolist (polygon polygons)
      (when polygon
        (let ((vertices (copy-sequence polygon)))
          (let ((a (car vertices)) (b (car (last vertices))))
            (unless (and (= (car a) (car b)) (= (cadr a) (cadr b)))
              (setq vertices (append vertices (list (list (car a) (cadr a)))))))
          (when (> (length vertices) 2)
            (push vertices vertex-array)))))
    (setq vertex-array (nreverse vertex-array))
    (setq gap (max gap 0.1))
    (dolist (vertices vertex-array)
      (let ((vv (vconcat vertices)))
        (dotimes (i (1- (length vv)))
          (let ((p1 (aref vv i)) (p2 (aref vv (1+ i))))
            (when (/= (cadr p1) (cadr p2))
              (let ((ymin (min (cadr p1) (cadr p2))))
                (push (vector ymin
                              (max (cadr p1) (cadr p2))
                              (if (= ymin (cadr p1)) (car p1) (car p2))
                              (/ (- (car p2) (car p1)) (- (cadr p2) (cadr p1))))
                      edges)))))))
    (setq edges (sort (nreverse edges)
                      (lambda (e1 e2)
                        (cond ((< (aref e1 0) (aref e2 0)) t)
                              ((> (aref e1 0) (aref e2 0)) nil)
                              ((< (aref e1 2) (aref e2 2)) t)
                              ((> (aref e1 2) (aref e2 2)) nil)
                              ((= (aref e1 1) (aref e2 1)) nil)
                              (t (< (aref e1 1) (aref e2 1)))))))
    (when edges
      (let ((active nil) (y (aref (car edges) 0)) (iteration 0))
        (while (or active edges)
          (when edges
            (let ((removed nil))
              (while (and edges (<= (aref (car edges) 0) y))
                (push (pop edges) removed))
              (dolist (e (nreverse removed))
                (setq active (nconc active (list (cons y e)))))))
          (setq active (cl-remove-if (lambda (ae) (<= (aref (cdr ae) 1) y))
                                     active))
          (setq active (sort active (lambda (a b)
                                      (< (aref (cdr a) 2) (aref (cdr b) 2)))))
          (when (or (/= step 1)
                    (= (mod (float iteration) gap) 0))
            (when (> (length active) 1)
              (let ((av (vconcat active)) (i 0))
                (while (< (1+ i) (length av))
                  (let ((ce (cdr (aref av i))) (ne (cdr (aref av (1+ i)))))
                    (push (list (list (esketch-rough--js-round (aref ce 2)) y)
                                (list (esketch-rough--js-round (aref ne 2)) y))
                          lines))
                  (setq i (+ i 2))))))
          (setq y (+ y step))
          (dolist (ae active)
            (aset (cdr ae) 2 (+ (aref (cdr ae) 2)
                                (* step (aref (cdr ae) 3)))))
          (setq iteration (1+ iteration)))))
    (nreverse lines)))

(defun esketch-rough--hachure-lines (polygons gap angle step)
  (let ((gap (max gap 0.1)))
    (when (/= angle 0)
      (dolist (polygon polygons) (esketch-rough--rotate-points polygon angle)))
    (let ((lines (esketch-rough--straight-hachure-lines polygons gap step)))
      (when (/= angle 0)
        (dolist (polygon polygons)
          (esketch-rough--rotate-points polygon (- angle)))
        (let ((pts nil))
          (dolist (line lines) (push (car line) pts) (push (cadr line) pts))
          (esketch-rough--rotate-points (nreverse pts) (- angle))))
      lines)))

(defun esketch-rough--hachure-gap (o)
  (let ((gap (plist-get o :hachureGap)))
    (when (< gap 0) (setq gap (* (plist-get o :strokeWidth) 4.0)))
    (max gap 0.1)))

(defun esketch-rough--polygon-hachure-lines (polygons o)
  (let ((angle (+ (plist-get o :hachureAngle) 90.0))
        (gap (esketch-rough--hachure-gap o))
        (skip 1))
    (when (>= (plist-get o :roughness) 1)
      (let* ((cell (plist-get o :randomizer))
             (r (and cell (esketch-rough--random-next cell))))
        (when (> (if (and r (/= r 0)) r (funcall esketch-rough-math-random)) 0.7)
          (setq skip gap))))
    (esketch-rough--hachure-lines polygons gap angle skip)))

(defun esketch-rough--line-length (line)
  (let ((p1 (car line)) (p2 (cadr line)))
    (let ((dx (- (car p1) (car p2))) (dy (- (cadr p1) (cadr p2))))
      (sqrt (+ (* dx dx) (* dy dy))))))

(defun esketch-rough--render-lines (lines o)
  (let ((ops nil))
    (dolist (line lines)
      (setq ops (nconc ops (esketch-rough--double-line
                            (car (car line)) (cadr (car line))
                            (car (cadr line)) (cadr (cadr line)) o t))))
    ops))

(defun esketch-rough--hachure-fill (polygons o)
  (esketch-rough--set
   'fillSketch
   (esketch-rough--render-lines
    (esketch-rough--polygon-hachure-lines polygons o) o)))

(defun esketch-rough--hatch-fill (polygons o)
  (let* ((set (esketch-rough--hachure-fill polygons o))
         (o2 (esketch-rough--with o :hachureAngle
                                  (+ (plist-get o :hachureAngle) 90.0)))
         (set2 (esketch-rough--hachure-fill polygons o2)))
    (esketch-rough--set 'fillSketch
                        (append (plist-get set :ops) (plist-get set2 :ops)))))

(defun esketch-rough--zigzag-fill (polygons o)
  (let* ((gap (plist-get o :hachureGap)))
    (when (< gap 0) (setq gap (* (plist-get o :strokeWidth) 4.0)))
    (setq gap (max gap 0.1))
    (let* ((o2 (esketch-rough--with o :hachureGap gap))
           (lines (esketch-rough--polygon-hachure-lines polygons o2))
           (zz-angle (* (/ float-pi 180.0) (plist-get o :hachureAngle)))
           (dgx (* (* gap 0.5) (cos zz-angle)))
           (dgy (* (* gap 0.5) (sin zz-angle)))
           (zz nil))
      (dolist (line lines)
        (let ((p1 (car line)) (p2 (cadr line)))
          (when (/= (esketch-rough--line-length (list p1 p2)) 0)
            (push (list (list (- (car p1) dgx) (+ (cadr p1) dgy))
                        (list (car p2) (cadr p2)))
                  zz)
            (push (list (list (+ (car p1) dgx) (- (cadr p1) dgy))
                        (list (car p2) (cadr p2)))
                  zz))))
      (esketch-rough--set 'fillSketch
                          (esketch-rough--render-lines (nreverse zz) o)))))

(defun esketch-rough--fill-gap (o)
  "Gap for the dots, dashed and zigzag-line fillers."
  (let ((gap (plist-get o :hachureGap)))
    (if (< gap 0) (* (plist-get o :strokeWidth) 4.0) gap)))

(defun esketch-rough--dots-fill (polygons o)
  (let* ((o (esketch-rough--with o :hachureAngle 0.0))
         (lines (esketch-rough--polygon-hachure-lines polygons o))
         (gap (let ((g (plist-get o :hachureGap)))
                (when (< g 0) (setq g (* (plist-get o :strokeWidth) 4.0)))
                (max g 0.1)))
         (fweight (plist-get o :fillWeight))
         (ops nil))
    (when (< fweight 0) (setq fweight (/ (plist-get o :strokeWidth) 2.0)))
    (let ((ro (/ gap 4.0)))
      (dolist (line lines)
        (let* ((len (esketch-rough--line-length line))
               (dl (/ len gap))
               (count (1- (ceiling dl)))
               (offset (- len (* count gap)))
               (x (- (/ (+ (car (car line)) (car (cadr line))) 2.0)
                     (/ gap 4.0)))
               (min-y (min (cadr (car line)) (cadr (cadr line)))))
          (dotimes (i count)
            (let* ((y (+ (+ min-y offset) (* i gap)))
                   (cx (+ (- x ro) (* (* (funcall esketch-rough-math-random) 2.0) ro)))
                   (cy (+ (- y ro) (* (* (funcall esketch-rough-math-random) 2.0) ro))))
              (setq ops (nconc ops (plist-get
                                    (esketch-rough--ellipse-set
                                     cx cy fweight fweight o)
                                    :ops))))))))
    (esketch-rough--set 'fillSketch ops)))

(defun esketch-rough--ordered-ends (line)
  "The ends of LINE with the smaller x first."
  (let ((p1 (car line)) (p2 (cadr line)))
    (if (> (car p1) (car p2)) (cons p2 p1) (cons p1 p2))))

(defun esketch-rough--dashed-fill (polygons o)
  (let* ((lines (esketch-rough--polygon-hachure-lines polygons o))
         (hg (plist-get o :hachureGap))
         (base (if (< hg 0) (* (plist-get o :strokeWidth) 4.0) hg))
         (offset (if (< (plist-get o :dashOffset) 0) base
                   (plist-get o :dashOffset)))
         (gap (if (< (plist-get o :dashGap) 0) base (plist-get o :dashGap)))
         (ops nil))
    (dolist (line lines)
      (let* ((len (esketch-rough--line-length line))
             (count (ffloor (/ len (+ offset gap))))
             (start-offset (/ (- (+ len gap) (* count (+ offset gap))) 2.0))
             (ends (esketch-rough--ordered-ends line))
             (p1 (car ends)) (p2 (cdr ends))
             (alpha (atan (/ (- (cadr p2) (cadr p1)) (- (car p2) (car p1)))))
             (i 0))
        (while (< i count)
          (let* ((lstart (* i (+ offset gap)))
                 (lend (+ lstart offset))
                 (sx (+ (+ (car p1) (* lstart (cos alpha)))
                        (* start-offset (cos alpha))))
                 (sy (+ (+ (cadr p1) (* lstart (sin alpha)))
                        (* start-offset (sin alpha))))
                 (ex (+ (+ (car p1) (* lend (cos alpha)))
                        (* start-offset (cos alpha))))
                 (ey (+ (+ (cadr p1) (* lend (sin alpha)))
                        (* start-offset (sin alpha)))))
            (setq ops (nconc ops (esketch-rough--double-line sx sy ex ey o t))))
          (setq i (1+ i)))))
    (esketch-rough--set 'fillSketch ops)))

(defun esketch-rough--zigzag-line-fill (polygons o)
  (let* ((gap (esketch-rough--fill-gap o))
         (zo (if (< (plist-get o :zigzagOffset) 0) gap
               (plist-get o :zigzagOffset)))
         (o (esketch-rough--with o :hachureGap (+ gap zo)))
         (lines (esketch-rough--polygon-hachure-lines polygons o))
         (ops nil))
    (dolist (line lines)
      (let* ((len (esketch-rough--line-length line))
             (count (esketch-rough--js-round (/ len (* 2.0 zo))))
             (ends (esketch-rough--ordered-ends line))
             (p1 (car ends)) (p2 (cdr ends))
             (alpha (atan (/ (- (cadr p2) (cadr p1)) (- (car p2) (car p1)))))
             (i 0))
        (while (< i count)
          (let* ((lstart (* (* i 2.0) zo))
                 (lend (* (* (+ i 1.0) 2.0) zo))
                 (dz (sqrt (* 2.0 (expt zo 2))))
                 (sx (+ (car p1) (* lstart (cos alpha))))
                 (sy (+ (cadr p1) (* lstart (sin alpha))))
                 (ex (+ (car p1) (* lend (cos alpha))))
                 (ey (+ (cadr p1) (* lend (sin alpha))))
                 (mx (+ sx (* dz (cos (+ alpha (/ float-pi 4.0))))))
                 (my (+ sy (* dz (sin (+ alpha (/ float-pi 4.0)))))))
            (setq ops (nconc ops
                             (esketch-rough--double-line sx sy mx my o t)
                             (esketch-rough--double-line mx my ex ey o t))))
          (setq i (1+ i)))))
    (esketch-rough--set 'fillSketch ops)))

(defun esketch-rough--pattern-fill-polygons (polygons o)
  (let ((style (plist-get o :fillStyle)))
    (cond
     ((equal style "zigzag") (esketch-rough--zigzag-fill polygons o))
     ((equal style "cross-hatch") (esketch-rough--hatch-fill polygons o))
     ((equal style "dots") (esketch-rough--dots-fill polygons o))
     ((equal style "dashed") (esketch-rough--dashed-fill polygons o))
     ((equal style "zigzag-line") (esketch-rough--zigzag-line-fill polygons o))
     (t (esketch-rough--hachure-fill polygons o)))))

(defun esketch-rough--merged-shape (ops)
  "OPS without any move after the first op."
  (cl-loop for op in ops for i from 0
           unless (and (> i 0) (eq (car op) 'move)) collect op))

(defun esketch-rough--fill-roughness (o)
  (let ((r (plist-get o :roughness)))
    (if (/= r 0) (+ r (plist-get o :fillShapeRoughnessGain)) 0.0)))

;;;; Shapes

(defun esketch-rough--drawable (shape full sets)
  (list :shape shape :options full :sets sets))

(defun esketch-rough--solid-p (o)
  (equal (plist-get o :fillStyle) "solid"))

(defun esketch-rough--stroked-p (o)
  (not (equal (plist-get o :stroke) "none")))

(defun esketch-rough-line (x1 y1 x2 y2 opts)
  "A roughjs line from (X1 Y1) to (X2 Y2) drawn with OPTS."
  (let* ((full (esketch-rough--options opts))
         (o (esketch-rough--internal full)))
    (esketch-rough--drawable
     "line" full
     (list (esketch-rough--set
            'path (esketch-rough--double-line
                   (float x1) (float y1) (float x2) (float y2) o))))))

(defun esketch-rough-rectangle (x y w h opts)
  "A roughjs rectangle at (X Y) of size W by H drawn with OPTS."
  (let* ((full (esketch-rough--options opts))
         (o (esketch-rough--internal full))
         (x (float x)) (y (float y)) (w (float w)) (h (float h))
         (outline (esketch-rough--rectangle-set x y w h o))
         (sets nil))
    (when (esketch-rough--truthy (plist-get o :fill))
      (let ((points (list (list x y) (list (+ x w) y)
                          (list (+ x w) (+ y h)) (list x (+ y h)))))
        (push (if (esketch-rough--solid-p o)
                  (esketch-rough--solid-fill-polygon (list points) o)
                (esketch-rough--pattern-fill-polygons (list points) o))
              sets)))
    (when (esketch-rough--stroked-p o) (push outline sets))
    (esketch-rough--drawable "rectangle" full (nreverse sets))))

(defun esketch-rough--ellipse (shape x y width height opts)
  (let* ((full (esketch-rough--options opts))
         (o (esketch-rough--internal full))
         (x (float x)) (y (float y)) (width (float width)) (height (float height))
         (params (esketch-rough--ellipse-params width height o))
         (response (esketch-rough--ellipse-with-params x y o params))
         (sets nil))
    (when (esketch-rough--truthy (plist-get o :fill))
      (if (esketch-rough--solid-p o)
          (push (esketch-rough--set
                 'fillPath
                 (plist-get (cdr (esketch-rough--ellipse-with-params
                                  x y o params))
                            :ops))
                sets)
        (push (esketch-rough--pattern-fill-polygons (list (car response)) o)
              sets)))
    (when (esketch-rough--stroked-p o) (push (cdr response) sets))
    (esketch-rough--drawable shape full (nreverse sets))))

(defun esketch-rough-ellipse (x y w h opts)
  "A roughjs ellipse centred on (X Y) of size W by H drawn with OPTS."
  (esketch-rough--ellipse "ellipse" x y w h opts))

(defun esketch-rough-circle (x y d opts)
  "A roughjs circle centred on (X Y) of diameter D drawn with OPTS."
  (esketch-rough--ellipse "circle" x y d d opts))

(defun esketch-rough-linear-path (points opts)
  "A roughjs open polyline through POINTS, a list of (X Y), drawn with OPTS."
  (let* ((full (esketch-rough--options opts))
         (o (esketch-rough--internal full)))
    (esketch-rough--drawable
     "linearPath" full
     (list (esketch-rough--linear-path (esketch-rough--floats points) nil o)))))

(defun esketch-rough-polygon (points opts)
  "A roughjs closed polygon through POINTS, a list of (X Y), drawn with OPTS."
  (let* ((full (esketch-rough--options opts))
         (o (esketch-rough--internal full))
         (points (esketch-rough--floats points))
         (outline (esketch-rough--linear-path points t o))
         (sets nil))
    (when (esketch-rough--truthy (plist-get o :fill))
      (push (if (esketch-rough--solid-p o)
                (esketch-rough--solid-fill-polygon (list points) o)
              (esketch-rough--pattern-fill-polygons (list points) o))
            sets))
    (when (esketch-rough--stroked-p o) (push outline sets))
    (esketch-rough--drawable "polygon" full (nreverse sets))))

(defun esketch-rough--curve-to-bezier (points)
  (let ((len (length points)))
    (if (= len 3)
        (list (copy-sequence (nth 0 points)) (copy-sequence (nth 1 points))
              (copy-sequence (nth 2 points)) (copy-sequence (nth 2 points)))
      (let* ((pv (vconcat (list (nth 0 points)) points
                          (list (car (last points)))))
             (out (list (copy-sequence (aref pv 0))))
             (s 1.0))
        (cl-loop for i from 1 while (< (+ i 2) (length pv))
                 do (let ((c (aref pv i)) (n (aref pv (1+ i)))
                          (pr (aref pv (1- i))) (n2 (aref pv (+ i 2))))
                      (push (list (+ (car c) (/ (- (* s (car n)) (* s (car pr))) 6.0))
                                  (+ (cadr c) (/ (- (* s (cadr n)) (* s (cadr pr))) 6.0)))
                            out)
                      (push (list (+ (car n) (/ (- (* s (car c)) (* s (car n2))) 6.0))
                                  (+ (cadr n) (/ (- (* s (cadr c)) (* s (cadr n2))) 6.0)))
                            out)
                      (push (list (car n) (cadr n)) out)))
        (nreverse out)))))

(defun esketch-rough-curve (points opts)
  "A roughjs curve through POINTS, a list of (X Y), drawn with OPTS."
  (let* ((full (esketch-rough--options opts))
         (o (esketch-rough--internal full))
         (points (esketch-rough--floats points))
         (outline (esketch-rough--curve points o))
         (fill (plist-get o :fill))
         (sets nil))
    (when (and (esketch-rough--truthy fill) (not (equal fill "none"))
               (>= (length points) 3))
      (if (esketch-rough--solid-p o)
          (let ((shape (esketch-rough--curve
                        points
                        (esketch-rough--with
                         o :disableMultiStroke t
                         :roughness (esketch-rough--fill-roughness o)))))
            (push (esketch-rough--set
                   'fillPath
                   (esketch-rough--merged-shape (plist-get shape :ops)))
                  sets))
        (let ((poly (esketch-rough--points-on-bezier-curves
                     (esketch-rough--curve-to-bezier points) 10.0
                     (/ (+ 1.0 (plist-get o :roughness)) 2.0))))
          (push (esketch-rough--pattern-fill-polygons (list poly) o) sets))))
    (when (esketch-rough--stroked-p o) (push outline sets))
    (esketch-rough--drawable "curve" full (nreverse sets))))

(defun esketch-rough--clean-path-data (d)
  (let ((s (replace-regexp-in-string "\n" " " d)))
    (replace-regexp-in-string "-[ \t\n\r\f\v]" "-" s)))

(defun esketch-rough-path (d opts)
  "A roughjs shape for SVG path data D drawn with OPTS."
  (let* ((full (esketch-rough--options opts))
         (o (esketch-rough--internal full))
         (sets nil))
    (when (and d (not (string= d "")))
      (let* ((d (esketch-rough--clean-path-data d))
             (fill (plist-get o :fill))
             (has-fill (and (esketch-rough--truthy fill)
                            (not (equal fill "transparent"))
                            (not (equal fill "none"))))
             (simplification (plist-get o :simplification))
             (simplified (and simplification (< simplification 1)))
             (distance (if simplified
                           (- 4.0 (* 4.0 simplification))
                         (/ (+ 1.0 (plist-get o :roughness)) 2.0)))
             (point-sets (esketch-rough--points-on-path d 1.0 distance))
             (shape (esketch-rough--svg-path d o)))
        (when has-fill
          (if (esketch-rough--solid-p o)
              (if (= (length point-sets) 1)
                  (let ((fill-shape
                         (esketch-rough--svg-path
                          d (esketch-rough--with
                             o :disableMultiStroke t
                             :roughness (esketch-rough--fill-roughness o)))))
                    (push (esketch-rough--set
                           'fillPath
                           (esketch-rough--merged-shape
                            (plist-get fill-shape :ops)))
                          sets))
                (push (esketch-rough--solid-fill-polygon point-sets o) sets))
            (push (esketch-rough--pattern-fill-polygons point-sets o) sets)))
        (when (esketch-rough--stroked-p o)
          (if simplified
              (dolist (set point-sets)
                (push (esketch-rough--linear-path set nil o) sets))
            (push shape sets)))))
    (esketch-rough--drawable "path" full (nreverse sets))))

;;;; Output

(defun esketch-rough-ops-to-path (set)
  "The SVG path data for SET, as roughjs's opsToPath writes it."
  (let ((parts nil))
    (dolist (op (plist-get set :ops))
      (let ((n (mapcar #'esketch-json-number-string (cdr op))))
        (push (pcase (car op)
                ('move (format "M%s %s " (nth 0 n) (nth 1 n)))
                ('bcurveTo (format "C%s %s, %s %s, %s %s " (nth 0 n) (nth 1 n)
                                   (nth 2 n) (nth 3 n) (nth 4 n) (nth 5 n)))
                ('lineTo (format "L%s %s " (nth 0 n) (nth 1 n)))
                (_ ""))
              parts)))
    (string-trim (apply #'concat (nreverse parts)))))

(provide 'esketch-rough)

;;; esketch-rough.el ends here
