;;; esketch-freehand.el --- Freehand strokes for esketch  -*- lexical-binding: t; -*-

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

;; This file ports perfect-freehand 1.2.0, which is distributed under the
;; MIT license:
;;
;; MIT License
;;
;; Copyright (c) 2021 Stephen Ruiz Ltd
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; perfect-freehand's getStroke and getStrokePoints, plus the SVG path
;; Excalidraw builds from a freedraw element.  Floating-point operations run
;; in the library's order so the outline matches it to the last digits; Math.hypot
;; follows V8's scaled, compensated summation for the same reason.
;;
;; Points are lists (X Y) or (X Y PRESSURE).  Options are a plist:
;; :size :thinning :smoothing :streamline :easing :simulatePressure :last
;; :start :end.  :start and :end are plists with :cap, :easing and :taper.
;; JavaScript false is :false (or nil) for :simulatePressure, :last and :cap,
;; and :false for :taper; absent keys take the library defaults.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'esketch-json)

(defconst esketch-freehand--rate-of-pressure-change 0.275)
(defconst esketch-freehand--fixed-pi (+ float-pi 1e-4))

;;;; Vector helpers

(defun esketch-freehand--hypot (a b)
  "Math.hypot(A, B) as V8 computes it."
  (let ((x (abs (float a))) (y (abs (float b))))
    (let ((mx (max x y)))
      (if (= mx 0.0)
          0.0
        (let ((sum 0.0) (comp 0.0))
          (dolist (v (list x y))
            (let* ((n (/ v mx))
                   (summand (- (* n n) comp))
                   (prelim (+ sum summand)))
              (setq comp (- (- prelim sum) summand)
                    sum prelim)))
          (* (sqrt sum) mx))))))

(defsubst esketch-freehand--add (a b)
  (list (+ (car a) (car b)) (+ (cadr a) (cadr b))))

(defsubst esketch-freehand--sub (a b)
  (list (- (car a) (car b)) (- (cadr a) (cadr b))))

(defsubst esketch-freehand--mul (a k)
  (list (* (car a) k) (* (cadr a) k)))

(defsubst esketch-freehand--per (a)
  (list (cadr a) (- (car a))))

(defsubst esketch-freehand--dpr (a b)
  (+ (* (car a) (car b)) (* (cadr a) (cadr b))))

(defun esketch-freehand--uni (a)
  (let ((n (esketch-freehand--hypot (car a) (cadr a))))
    (list (/ (car a) n) (/ (cadr a) n))))

(defun esketch-freehand--dist (a b)
  (esketch-freehand--hypot (- (cadr a) (cadr b)) (- (car a) (car b))))

(defun esketch-freehand--dist2 (a b)
  (let ((d (esketch-freehand--sub a b)))
    (+ (* (car d) (car d)) (* (cadr d) (cadr d)))))

(defun esketch-freehand--rot (a c r)
  "A rotated by R radians around C."
  (let* ((s (sin r)) (co (cos r))
         (px (- (car a) (car c))) (py (- (cadr a) (cadr c))))
    (list (+ (- (* px co) (* py s)) (car c))
          (+ (+ (* px s) (* py co)) (cadr c)))))

(defun esketch-freehand--lrp (a b tt)
  (esketch-freehand--add a (esketch-freehand--mul (esketch-freehand--sub b a) tt)))

(defun esketch-freehand--prj (a b c)
  (esketch-freehand--add a (esketch-freehand--mul b c)))

(defun esketch-freehand--radius (size thinning pressure easing)
  (* size (funcall easing (- 0.5 (* thinning (- 0.5 pressure))))))

;;;; Options

(defun esketch-freehand--opt (opts key default)
  (let ((cell (plist-member opts key)))
    (if cell (cadr cell) default)))

(defun esketch-freehand--true (v)
  (not (memq v '(nil :false))))

(defun esketch-freehand--num (v)
  "V as a float, or nil when it is not a number."
  (and (numberp v) (float v)))

(defun esketch-freehand--taper (spec total size)
  (let ((v (plist-get spec :taper)))
    (cond ((eq v :false) 0.0)
          ((eq v t) (max size total))
          ((numberp v) (float v))
          (t 0.0))))

;;;; Stroke points

(defun esketch-freehand-stroke-points (points options)
  "perfect-freehand getStrokePoints: POINTS as a list of plists.
Each has :point, :pressure, :vector, :distance and :running-length."
  (when points
    (let* ((streamline (float (esketch-freehand--opt options :streamline 0.5)))
           (size (float (esketch-freehand--opt options :size 16)))
           (last (esketch-freehand--true (esketch-freehand--opt options :last nil)))
           (tt (+ 0.15 (* (- 1 streamline) 0.85)))
           (pts (mapcar (lambda (p)
                          (append (list (float (car p)) (float (cadr p)))
                                  (let ((pr (nth 2 p))) (and pr (list pr)))))
                        points)))
      (when (= (length pts) 2)
        (let ((end (cadr pts)) (first (car pts)))
          (setq pts (list first))
          (dotimes (i 4)
            (setq pts (append pts (list (esketch-freehand--lrp
                                         first end (/ (float (1+ i)) 4))))))))
      (when (= (length pts) 1)
        (setq pts (list (car pts)
                        (append (esketch-freehand--add (car pts) '(1.0 1.0))
                                (nthcdr 2 (car pts))))))
      (let* ((v (vconcat pts))
             (maxi (1- (length v)))
             (pressure0 (esketch-freehand--num (nth 2 (aref v 0))))
             (prev (list :point (list (car (aref v 0)) (cadr (aref v 0)))
                         :pressure (if (and pressure0 (>= pressure0 0)) pressure0 0.25)
                         :vector (list 1.0 1.0) :distance 0.0 :running-length 0.0))
             (out (list prev))
             (reached nil)
             (running 0.0))
        (cl-loop
         for i from 1 to maxi
         do (let* ((cur (aref v i))
                   (point (if (and last (= i maxi))
                              (list (car cur) (cadr cur))
                            (esketch-freehand--lrp (plist-get prev :point) cur tt))))
              (unless (let ((pp (plist-get prev :point)))
                        (and (= (car pp) (car point)) (= (cadr pp) (cadr point))))
                (let ((distance (esketch-freehand--dist point (plist-get prev :point)))
                      (pr (esketch-freehand--num (nth 2 cur))))
                  (setq running (+ running distance))
                  (unless (and (< i maxi) (not reached)
                               (if (< running size) t (setq reached t) nil))
                    (setq prev (list :point point
                                     :pressure (if (and pr (>= pr 0)) pr 0.5)
                                     :vector (esketch-freehand--uni
                                              (esketch-freehand--sub
                                               (plist-get prev :point) point))
                                     :distance distance
                                     :running-length running))
                    (push prev out))))))
        (setq out (nreverse out))
        (setf (plist-get (car out) :vector)
              (if (cdr out) (plist-get (cadr out) :vector) (list 0.0 0.0)))
        out))))

;;;; Outline

(defun esketch-freehand--outline (stroke-points options)
  (let* ((sp (vconcat stroke-points))
         (n (length sp))
         (size (float (esketch-freehand--opt options :size 16)))
         (smoothing (float (esketch-freehand--opt options :smoothing 0.5)))
         (thinning (float (esketch-freehand--opt options :thinning 0.5)))
         (simulate (esketch-freehand--true
                    (esketch-freehand--opt options :simulatePressure t)))
         (easing (esketch-freehand--opt options :easing #'identity))
         (last (esketch-freehand--true (esketch-freehand--opt options :last nil)))
         (start (esketch-freehand--opt options :start nil))
         (end (esketch-freehand--opt options :end nil))
         (cap-start (esketch-freehand--true (esketch-freehand--opt start :cap t)))
         (start-easing (esketch-freehand--opt
                        start :easing (lambda (u) (* u (- 2 u)))))
         (cap-end (esketch-freehand--true (esketch-freehand--opt end :cap t)))
         (end-easing (esketch-freehand--opt
                      end :easing (lambda (u) (let ((u (1- u))) (1+ (* u u u))))))
         (rate esketch-freehand--rate-of-pressure-change)
         (fpi esketch-freehand--fixed-pi))
    (if (or (= n 0) (<= size 0))
        nil
      (let* ((total (plist-get (aref sp (1- n)) :running-length))
             (taper-start (esketch-freehand--taper start total size))
             (taper-end (esketch-freehand--taper end total size))
             (min-dist (let ((m (* size smoothing))) (* m m)))
             (lefts nil) (rights nil)
             (prev-pressure
              (let ((acc (plist-get (aref sp 0) :pressure)))
                (dotimes (i (min n 10))
                  (let ((pressure (plist-get (aref sp i) :pressure)))
                    (when simulate
                      (let* ((s (min 1.0 (/ (plist-get (aref sp i) :distance) size)))
                             (r (min 1.0 (- 1 s))))
                        (setq pressure (min 1.0 (+ acc (* (- r acc) (* s rate)))))))
                    (setq acc (/ (+ acc pressure) 2))))
                acc))
             (radius (esketch-freehand--radius
                      size thinning (plist-get (aref sp (1- n)) :pressure) easing))
             (first-radius nil)
             (prev-vector (plist-get (aref sp 0) :vector))
             (pl (plist-get (aref sp 0) :point))
             (pr pl) (tl pl) (tr pr)
             (prev-sharp nil))
        (dotimes (i n)
          (let* ((cur (aref sp i))
                 (pressure (plist-get cur :pressure))
                 (point (plist-get cur :point))
                 (vector (plist-get cur :vector))
                 (distance (plist-get cur :distance))
                 (running (plist-get cur :running-length)))
            (unless (and (< i (1- n)) (< (- total running) 3))
              (if (/= thinning 0)
                  (progn
                    (when simulate
                      (let* ((s (min 1.0 (/ distance size)))
                             (r (min 1.0 (- 1 s))))
                        (setq pressure (min 1.0 (+ prev-pressure
                                                   (* (- r prev-pressure) (* s rate)))))))
                    (setq radius (esketch-freehand--radius
                                  size thinning pressure easing)))
                (setq radius (/ size 2)))
              (unless first-radius (setq first-radius radius))
              (let ((ts (if (< running taper-start)
                            (funcall start-easing (/ running taper-start))
                          1))
                    (te (if (< (- total running) taper-end)
                            (funcall end-easing (/ (- total running) taper-end))
                          1)))
                (setq radius (max 0.01 (* radius (min ts te)))))
              (let* ((next-vector (plist-get (aref sp (if (< i (1- n)) (1+ i) i))
                                             :vector))
                     (next-dpr (if (< i (1- n))
                                   (esketch-freehand--dpr vector next-vector)
                                 1))
                     (prev-dpr (esketch-freehand--dpr vector prev-vector))
                     (sharp (and (< prev-dpr 0) (not prev-sharp)))
                     (next-sharp (< next-dpr 0)))
                (cond
                 ((or sharp next-sharp)
                  (let ((offset (esketch-freehand--mul
                                 (esketch-freehand--per prev-vector) radius))
                        (step (/ 1.0 13)) (u 0.0))
                    (while (<= u 1)
                      (setq tl (esketch-freehand--rot
                                (esketch-freehand--sub point offset) point (* fpi u)))
                      (push tl lefts)
                      (setq tr (esketch-freehand--rot
                                (esketch-freehand--add point offset) point (* fpi (- u))))
                      (push tr rights)
                      (setq u (+ u step))))
                  (setq pl tl pr tr)
                  (when next-sharp (setq prev-sharp t)))
                 (t
                  (setq prev-sharp nil)
                  (if (= i (1- n))
                      (let ((offset (esketch-freehand--mul
                                     (esketch-freehand--per vector) radius)))
                        (push (esketch-freehand--sub point offset) lefts)
                        (push (esketch-freehand--add point offset) rights))
                    (let ((offset (esketch-freehand--mul
                                   (esketch-freehand--per
                                    (esketch-freehand--lrp next-vector vector next-dpr))
                                   radius)))
                      (setq tl (esketch-freehand--sub point offset))
                      (when (or (<= i 1) (> (esketch-freehand--dist2 pl tl) min-dist))
                        (push tl lefts)
                        (setq pl tl))
                      (setq tr (esketch-freehand--add point offset))
                      (when (or (<= i 1) (> (esketch-freehand--dist2 pr tr) min-dist))
                        (push tr rights)
                        (setq pr tr))
                      (setq prev-pressure pressure prev-vector vector)))))))))
        (let* ((lefts (nreverse lefts))
               (rights-rev rights)
               (rights (reverse rights-rev))
               (first-point (let ((p (plist-get (aref sp 0) :point)))
                              (list (car p) (cadr p))))
               (last-point (if (> n 1)
                               (let ((p (plist-get (aref sp (1- n)) :point)))
                                 (list (car p) (cadr p)))
                             (esketch-freehand--add (plist-get (aref sp 0) :point)
                                                    '(1.0 1.0))))
               (start-cap nil) (end-cap nil)
               (tapered (or (/= taper-start 0) (/= taper-end 0))))
          (cl-block done
            (if (= n 1)
                (when (or (not tapered) last)
                  (let ((s (esketch-freehand--prj
                            first-point
                            (esketch-freehand--uni
                             (esketch-freehand--per
                              (esketch-freehand--sub first-point last-point)))
                            (- (if (and first-radius (/= first-radius 0))
                                   first-radius radius))))
                        (step (/ 1.0 13)) (dots nil))
                    (let ((u step))
                      (while (<= u 1)
                        (push (esketch-freehand--rot s first-point (* fpi 2 u)) dots)
                        (setq u (+ u step))))
                    (cl-return-from done (nreverse dots))))
              (unless (or (/= taper-start 0) (and (/= taper-end 0) (= n 1)))
                (if cap-start
                    (let ((step (/ 1.0 13)))
                      (let ((u step))
                        (while (<= u 1)
                          (push (esketch-freehand--rot (car rights) first-point (* fpi u))
                                start-cap)
                          (setq u (+ u step))))
                      (setq start-cap (nreverse start-cap)))
                  (let* ((cv (esketch-freehand--sub (car lefts) (car rights)))
                         (a (esketch-freehand--mul cv 0.5))
                         (b (esketch-freehand--mul cv 0.51)))
                    (setq start-cap (list (esketch-freehand--sub first-point a)
                                          (esketch-freehand--sub first-point b)
                                          (esketch-freehand--add first-point b)
                                          (esketch-freehand--add first-point a))))))
              (let ((direction (esketch-freehand--per
                                (let ((v (plist-get (aref sp (1- n)) :vector)))
                                  (list (- (car v)) (- (cadr v)))))))
                (cond
                 ((or (/= taper-end 0) (and (/= taper-start 0) (= n 1)))
                  (setq end-cap (list last-point)))
                 (cap-end
                  (let ((s (esketch-freehand--prj last-point direction radius))
                        (step (/ 1.0 29)))
                    (let ((u step))
                      (while (< u 1)
                        (push (esketch-freehand--rot s last-point (* fpi 3 u)) end-cap)
                        (setq u (+ u step))))
                    (setq end-cap (nreverse end-cap))))
                 (t
                  (setq end-cap
                        (list (esketch-freehand--add
                               last-point (esketch-freehand--mul direction radius))
                              (esketch-freehand--add
                               last-point (esketch-freehand--mul direction (* radius 0.99)))
                              (esketch-freehand--sub
                               last-point (esketch-freehand--mul direction (* radius 0.99)))
                              (esketch-freehand--sub
                               last-point (esketch-freehand--mul direction radius))))))))
            (append lefts end-cap rights-rev start-cap)))))))

(defun esketch-freehand-stroke (points options)
  "perfect-freehand getStroke: the outline of POINTS as a list of (X Y)."
  (esketch-freehand--outline (esketch-freehand-stroke-points points options) options))

;;;; Excalidraw freedraw element

(defun esketch-freehand--med (a b)
  (list (/ (+ (car a) (car b)) 2) (/ (+ (cadr a) (cadr b)) 2)))

(defun esketch-freehand--fmt (p)
  (concat (esketch-json-number-string (car p)) ","
          (esketch-json-number-string (cadr p))))

(defun esketch-freehand-svg-path (element)
  "The SVG path data Excalidraw draws for the freedraw ELEMENT."
  (let* ((simulate (esketch-freehand--true (esketch-get element "simulatePressure")))
         (pts (mapcar (lambda (p) (list (float (aref p 0)) (float (aref p 1))))
                      (append (esketch-get element "points") nil)))
         (pressures (append (esketch-get element "pressures") nil))
         (input (cond (simulate pts)
                      (pts (let ((i -1))
                             (mapcar (lambda (p)
                                       (setq i (1+ i))
                                       (append p (let ((v (nth i pressures)))
                                                   (and (numberp v) (list v)))))
                                     pts)))
                      (t (list (list 0.0 0.0 0.5)))))
         (so (esketch-get element "strokeOptions"))
         (streamline (let ((s (and so (esketch-get so "streamline"))))
                       (if (numberp s) s 0.5)))
         (outline (esketch-freehand-stroke
                   input
                   (list :simulatePressure simulate
                         :size (* (esketch-get element "strokeWidth") 4.25)
                         :thinning 0.6 :smoothing 0.5 :streamline streamline
                         :easing (lambda (u) (sin (/ (* u float-pi) 2)))
                         :last t))))
    (if (null outline)
        ""
      (let* ((first (car outline))
             (parts (list "Q" (esketch-freehand--fmt first) "M"))
             (rest outline))
        (while rest
          (let* ((p (car rest)) (next (cadr rest)))
            (if next
                (setq parts (cons (esketch-freehand--fmt (esketch-freehand--med p next))
                                  (cons (esketch-freehand--fmt p) parts)))
              (setq parts (cons "Z"
                                (cons (esketch-freehand--fmt first)
                                      (cons "L"
                                            (cons (esketch-freehand--fmt
                                                   (esketch-freehand--med p first))
                                                  (cons (esketch-freehand--fmt p)
                                                        parts))))))))
          (setq rest (cdr rest)))
        (let ((case-fold-search nil))
          (replace-regexp-in-string
           "\\([ \t\n]?[A-Z]?,?-?[0-9]*\\.[0-9]?[0-9]?\\)[-0-9e]*" "\\1"
           (mapconcat #'identity (nreverse parts) " ")))))))

(provide 'esketch-freehand)
;;; esketch-freehand.el ends here
