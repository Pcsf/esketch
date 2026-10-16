;;; esketch.el --- Excalidraw-style diagrams in Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pcsf

;; Author: Pcsf <7274075+Pcsf@users.noreply.github.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: multimedia, outlines
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

;; Views and edits Excalidraw (.excalidraw) drawings inside Emacs.  The
;; drawing is shown as an image in an overlay; the same editor serves a
;; drawing's own buffer (`esketch-open') and a drawing edited in place in an
;; Org buffer (esketch-org.el).
;;
;; Mouse: click selects, drag moves.  Keys are in `esketch-edit-map'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'esketch-json)
(require 'esketch-model)
(require 'esketch-render)
(require 'filenotify)

(defgroup esketch nil
  "Excalidraw-style diagrams."
  :group 'multimedia)

(defcustom esketch-scale 1.0
  "Display scale of drawings being edited."
  :type 'number)

(defcustom esketch-view-margin 40
  "Free space kept around a drawing while editing, in drawing pixels."
  :type 'number)

(defcustom esketch-directory (expand-file-name "esketch" user-emacs-directory)
  "Directory where new drawings are created."
  :type 'directory)

(defcustom esketch-new-shape-size '(160 . 80)
  "Width and height of a shape added from the keyboard."
  :type '(cons number number))

(defconst esketch--selection-color "#4a47b1")

(defconst esketch--handle-size 8
  "Side of the resize handle, in screen pixels.")

(defconst esketch--min-size 10
  "Smallest width and height a resize leaves a shape.")

(defconst esketch--zoom-step 1.25)
(defconst esketch--zoom-range '(0.25 . 4))

(cl-defstruct (esketch-ed (:constructor esketch-ed--make))
  efile file overlay view (scale esketch-scale)
  selected selection previous undo redo point on-close browsed watch point-file
  tool gesture free)

(defvar-local esketch--ed nil
  "The editor active in this buffer.")

;;;; Display

(defun esketch--fit-view (ed)
  "Grow ED's view so the whole drawing fits, never shrink it."
  (let* ((b (esketch-render-bounds (esketch-ed-doc ed)))
         (m esketch-view-margin)
         (x1 (- (nth 0 b) m)) (y1 (- (nth 1 b) m))
         (x2 (+ (nth 2 b) m)) (y2 (+ (nth 3 b) m))
         (v (esketch-ed-view ed)))
    (unless (and v (esketch-ed-free ed))
      (when v
        (setq x1 (min x1 (nth 0 v)) y1 (min y1 (nth 1 v))
              x2 (max x2 (+ (nth 0 v) (nth 2 v))) y2 (max y2 (+ (nth 1 v) (nth 3 v)))))
      (setf (esketch-ed-view ed) (list x1 y1 (max 200 (- x2 x1)) (max 120 (- y2 y1)))))))

(defun esketch-ed-doc (ed)
  (esketch-file-doc (esketch-ed-efile ed)))

(defun esketch--selected-ids (ed)
  "Ids of the live selected elements of ED."
  (let ((doc (esketch-ed-doc ed)))
    (cl-remove-if-not (lambda (id) (esketch--live-element doc id))
                      (esketch-ed-selection ed))))

(defconst esketch--handle-pad 6
  "Gap between an element and its selection box and handle, in drawing pixels.")

(defun esketch--handle (ed)
  "Centre (X Y) of the resize handle of ED's selection, or nil.
Only one rectangle, ellipse, diamond or text has a handle."
  (let ((ids (esketch--selected-ids ed)) (doc (esketch-ed-doc ed)))
    (when (and ids (null (cdr ids)))
      (let ((el (esketch-element doc (car ids))))
        (when (and (member (esketch-get el "type") '("rectangle" "ellipse" "diamond" "text"))
                   (not (stringp (esketch-get el "containerId"))))
          (let ((b (esketch-render-element-bounds doc el)) (pad esketch--handle-pad))
            (list (+ (nth 2 b) pad) (+ (nth 3 b) pad))))))))

(defun esketch--on-handle-p (ed p)
  (let ((h (esketch--handle ed)) (r (/ 6.0 (esketch-ed-scale ed))))
    (and h (<= (abs (- (car p) (car h))) r) (<= (abs (- (cadr p) (cadr h))) r))))

(defun esketch--selection-svg (ed)
  (let ((doc (esketch-ed-doc ed)) (pad esketch--handle-pad) (parts nil))
    (dolist (id (esketch--selected-ids ed))
      (let ((b (esketch-render-element-bounds doc (esketch-element doc id))))
        (push (format "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"1\" stroke-dasharray=\"6 4\"/>"
                      (esketch-render--num (- (nth 0 b) pad)) (esketch-render--num (- (nth 1 b) pad))
                      (esketch-render--num (+ (- (nth 2 b) (nth 0 b)) (* 2 pad)))
                      (esketch-render--num (+ (- (nth 3 b) (nth 1 b)) (* 2 pad)))
                      esketch--selection-color)
              parts)))
    (let ((h (esketch--handle ed)))
      (when h
        (let ((side (/ esketch--handle-size (float (esketch-ed-scale ed)))))
          (push (format "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"#ffffff\" stroke=\"%s\" stroke-width=\"1\"/>"
                        (esketch-render--num (- (car h) (/ side 2))) (esketch-render--num (- (cadr h) (/ side 2)))
                        (esketch-render--num side) (esketch-render--num side)
                        esketch--selection-color)
                parts))))
    (apply #'concat (nreverse parts))))

(defun esketch-image (svg scale &optional name)
  "SVG as an image at SCALE, or a note when this Emacs cannot show SVG
(a terminal, or a build without librsvg): the browser editor still works."
  (if (and (or noninteractive (display-images-p)) (image-type-available-p 'svg))
      (create-image svg 'svg t :scale scale)
    (propertize (format "[drawing%s: this Emacs cannot show SVG; b edits it in the browser]"
                        (if name (concat " " name) ""))
                'face 'link)))

(defun esketch--redisplay (ed)
  (esketch--fit-view ed)
  (overlay-put (esketch-ed-overlay ed) 'display
               (esketch-image (esketch-render-svg (esketch-ed-doc ed) (esketch-ed-view ed)
                                                  (esketch--selection-svg ed))
                              (esketch-ed-scale ed)
                              (file-name-nondirectory (esketch-ed-file ed)))))

;;;; Coordinates and hit testing

(defun esketch--posn-point (ed posn)
  "Drawing coordinates (X Y) of mouse position POSN over ED's image."
  (let ((xy (posn-object-x-y posn)) (v (esketch-ed-view ed)) (s (esketch-ed-scale ed)))
    (list (+ (nth 0 v) (/ (car xy) (float s)))
          (+ (nth 1 v) (/ (cdr xy) (float s))))))

(defun esketch--segment-distance (px py ax ay bx by)
  (let* ((dx (- bx ax)) (dy (- by ay)) (l2 (+ (* dx dx) (* dy dy)))
         (tt (if (= l2 0) 0 (max 0 (min 1 (/ (+ (* (- px ax) dx) (* (- py ay) dy)) l2))))))
    (sqrt (+ (expt (- px (+ ax (* tt dx))) 2) (expt (- py (+ ay (* tt dy))) 2)))))

(defun esketch--hit-p (doc el x y)
  (let ((type (esketch-get el "type")))
    (if (member type '("arrow" "line" "freedraw"))
        (let* ((ox (esketch-get el "x")) (oy (esketch-get el "y"))
               (pts (mapcar (lambda (p) (list (+ ox (aref p 0)) (+ oy (aref p 1))))
                            (esketch-get el "points"))))
          (cl-loop for (a b) on pts while b
                   thereis (< (esketch--segment-distance x y (car a) (cadr a)
                                                         (car b) (cadr b))
                              8)))
      (let ((b (esketch-render-element-bounds doc el)))
        (and (<= (nth 0 b) x (nth 2 b)) (<= (nth 1 b) y (nth 3 b)))))))

(defun esketch--hit (doc x y)
  "Id of the topmost live element at X, Y; text in a shape gives the shape."
  (let ((found nil))
    (mapc (lambda (el)
            (when (and (esketch-live-p el) (esketch--hit-p doc el x y))
              (setq found el)))
          (esketch-elements doc))
    (when found
      (let ((cid (esketch-get found "containerId")))
        (if (and (stringp cid) (esketch-element doc cid))
            cid
          (esketch-get found "id"))))))

;;;; Undo

(defun esketch--snapshot (ed)
  (push (copy-tree (esketch-ed-doc ed) t) (esketch-ed-undo ed))
  (setf (esketch-ed-redo ed) nil))

(defun esketch--set-doc (ed doc)
  (setf (esketch-file-doc (esketch-ed-efile ed)) doc))

(defun esketch--ed-or-error ()
  (or esketch--ed (user-error "No drawing is being edited here")))

(defmacro esketch--edit (ed &rest body)
  "Record an undo step for ED, run BODY, redisplay."
  (declare (indent 1))
  `(progn (esketch--snapshot ,ed) (prog1 (progn ,@body) (esketch--redisplay ,ed))))

(defun esketch-undo ()
  "Undo the last change to the drawing."
  (interactive)
  (let ((ed (esketch--ed-or-error)))
    (unless (esketch-ed-undo ed) (user-error "Nothing to undo"))
    (push (esketch-ed-doc ed) (esketch-ed-redo ed))
    (esketch--set-doc ed (pop (esketch-ed-undo ed)))
    (esketch--redisplay ed)))

(defun esketch-redo ()
  "Redo the last undone change."
  (interactive)
  (let ((ed (esketch--ed-or-error)))
    (unless (esketch-ed-redo ed) (user-error "Nothing to redo"))
    (push (esketch-ed-doc ed) (esketch-ed-undo ed))
    (esketch--set-doc ed (pop (esketch-ed-redo ed)))
    (esketch--redisplay ed)))

;;;; Selection

(defun esketch--set-selection (ed ids)
  "Select IDS in ED; the last one is the primary selection."
  (let* ((ids (delete-dups (copy-sequence ids)))
         (new (car (last ids))))
    (unless (equal new (esketch-ed-selected ed))
      (when (esketch-ed-selected ed)
        (setf (esketch-ed-previous ed) (esketch-ed-selected ed))))
    (setf (esketch-ed-selection ed) ids
          (esketch-ed-selected ed) new)))

(defun esketch--select (ed id)
  (esketch--set-selection ed (and id (list id))))

(defun esketch--toggle (ed id)
  (let ((ids (esketch-ed-selection ed)))
    (esketch--set-selection ed (if (member id ids) (remove id ids) (append ids (list id))))))

(defun esketch--cycle (n)
  (let* ((ed (esketch--ed-or-error))
         (doc (esketch-ed-doc ed))
         (ids (cl-loop for el across (esketch-elements doc)
                       when (and (esketch-live-p el)
                                 (not (esketch--live-element doc (esketch-get el "containerId"))))
                       collect (esketch-get el "id")))
         (at (cl-position (esketch-ed-selected ed) ids :test #'equal)))
    (unless ids (user-error "Nothing to select"))
    (esketch--select ed (nth (if at (mod (+ at n) (length ids)) (if (> n 0) 0 (1- (length ids))))
                             ids))
    (esketch--redisplay ed)))

(defun esketch-select-next ()
  "Select the next element in drawing order, wrapping around."
  (interactive) (esketch--cycle 1))

(defun esketch-select-previous ()
  "Select the previous element in drawing order, wrapping around."
  (interactive) (esketch--cycle -1))

;;;; Mouse

(defun esketch--constrain (dx dy)
  "DX, DY projected onto the nearest of the eight multiples of 45 degrees."
  (let* ((a (atan dy dx))
         (k (mod (round (/ a (/ float-pi 4))) 8))
         (d (nth k '((1 0) (1 1) (0 1) (-1 1) (-1 0) (-1 -1) (0 -1) (1 -1))))
         (ux (car d)) (uy (cadr d))
         (tt (/ (+ (* dx ux) (* dy uy)) (float (+ (* ux ux) (* uy uy))))))
    (list (* tt ux) (* tt uy))))

(defun esketch--bindable (doc id)
  (let ((el (and id (esketch-element doc id))))
    (and el (member (esketch-get el "type") '("rectangle" "ellipse" "diamond")) el)))

(defun esketch-mouse-down (event)
  "Start a mouse gesture: select what is under the mouse.
With Control the element is added to or removed from the selection.
After `esketch-arrow-tool' the press starts an arrow; after
`esketch-text-tool' it places a text."
  (interactive "e")
  (let* ((ed (esketch--ed-or-error))
         (p (esketch--posn-point ed (event-start event)))
         (doc (esketch-ed-doc ed))
         (id (esketch--hit doc (car p) (cadr p))))
    (setf (esketch-ed-point ed) p
          (esketch-ed-gesture ed) nil)
    (cond
     ((eq (esketch-ed-tool ed) 'text)
      (setf (esketch-ed-tool ed) nil)
      (esketch-add-text (read-string "Text: ") p))
     ((eq (esketch-ed-tool ed) 'arrow)
      (setf (esketch-ed-gesture ed) 'arrow))
     ((esketch--on-handle-p ed p)
      (setf (esketch-ed-gesture ed) 'resize))
     ((memq 'control (event-modifiers event))
      (when id (esketch--toggle ed id)))
     ((and id (cdr (esketch-ed-selection ed)) (member id (esketch-ed-selection ed)))
      (setf (esketch-ed-gesture ed) (cons 'narrow id)))
     (t (esketch--select ed id)))
    (esketch--redisplay ed)))

(defun esketch-mouse-click (_event)
  "A press released where it began: a selected element becomes the only one."
  (interactive "e")
  (let* ((ed (esketch--ed-or-error)) (g (esketch-ed-gesture ed)))
    (setf (esketch-ed-gesture ed) nil
          (esketch-ed-tool ed) nil)
    (when (eq (car-safe g) 'narrow)
      (esketch--select ed (cdr g))
      (esketch--redisplay ed))))

(defun esketch-mouse-drag (event)
  "Finish a gesture that moved: move, resize or draw.
Shift keeps a move to multiples of 45 degrees and a resize to the
shape's proportions; Meta moves a copy of the selection."
  (interactive "e")
  (let* ((ed (esketch--ed-or-error))
         (a (esketch--posn-point ed (event-start event)))
         (b (esketch--posn-point ed (event-end event)))
         (mods (event-modifiers event))
         (g (esketch-ed-gesture ed))
         (dx (- (car b) (car a))) (dy (- (cadr b) (cadr a)))
         (ids (esketch--selected-ids ed)))
    (setf (esketch-ed-gesture ed) nil)
    (cond
     ((eq g 'arrow)
      (setf (esketch-ed-tool ed) nil)
      (esketch--draw-arrow ed a b))
     ((eq g 'resize)
      (when ids
        (esketch--edit ed
          (esketch-resize (esketch-ed-doc ed) (car ids) dx dy (and (memq 'shift mods) t)))))
     (ids
      (when (memq 'shift mods)
        (let ((c (esketch--constrain dx dy))) (setq dx (car c) dy (cadr c))))
      (esketch--edit ed
        (if (memq 'meta mods)
            (let ((new (esketch-duplicate (esketch-ed-doc ed) ids)))
              (esketch-move-many (esketch-ed-doc ed) new dx dy)
              (esketch--set-selection ed new))
          (esketch-move-many (esketch-ed-doc ed) ids dx dy)))))
    (setf (esketch-ed-point ed) b)))

(defun esketch-mouse-pan (event)
  "Pan the view by the distance dragged."
  (interactive "e")
  (let* ((ed (esketch--ed-or-error))
         (a (esketch--posn-point ed (event-start event)))
         (b (esketch--posn-point ed (event-end event)))
         (v (esketch-ed-view ed)))
    (setf (esketch-ed-view ed) (list (- (nth 0 v) (- (car b) (car a)))
                                     (- (nth 1 v) (- (cadr b) (cadr a)))
                                     (nth 2 v) (nth 3 v))
          (esketch-ed-free ed) t)
    (esketch--redisplay ed)))

(defun esketch--zoom (ed event factor)
  "Scale ED's display by FACTOR, keeping the drawing point under EVENT fixed."
  (let* ((s (esketch-ed-scale ed))
         (s2 (min (cdr esketch--zoom-range) (max (car esketch--zoom-range) (* s factor))))
         (v (esketch-ed-view ed))
         (xy (and event (posn-object-x-y (event-start event)))))
    (unless (= s s2)
      (let* ((px (if xy (car xy) (/ (* (nth 2 v) s) 2.0)))
             (py (if xy (cdr xy) (/ (* (nth 3 v) s) 2.0)))
             (x (+ (nth 0 v) (/ px s))) (y (+ (nth 1 v) (/ py s))))
        (setf (esketch-ed-view ed) (list (- x (/ px s2)) (- y (/ py s2))
                                         (* (nth 2 v) (/ s s2)) (* (nth 3 v) (/ s s2)))
              (esketch-ed-scale ed) s2
              (esketch-ed-free ed) t)
        (esketch--redisplay ed)))))

(defun esketch-zoom-in (event)
  "Zoom in one step around the mouse position of EVENT."
  (interactive "e") (esketch--zoom (esketch--ed-or-error) event esketch--zoom-step))

(defun esketch-zoom-out (event)
  "Zoom out one step around the mouse position of EVENT."
  (interactive "e") (esketch--zoom (esketch--ed-or-error) event (/ esketch--zoom-step)))

(defun esketch-view-reset ()
  "Show the whole drawing at the default scale again."
  (interactive)
  (let ((ed (esketch--ed-or-error)))
    (setf (esketch-ed-view ed) nil
          (esketch-ed-scale ed) esketch-scale
          (esketch-ed-free ed) nil)
    (esketch--redisplay ed)))

(defun esketch-arrow-tool ()
  "Draw an arrow with the next drag."
  (interactive)
  (setf (esketch-ed-tool (esketch--ed-or-error)) 'arrow)
  (message "Drag to draw an arrow"))

(defun esketch-text-tool ()
  "Place a text at the next click."
  (interactive)
  (setf (esketch-ed-tool (esketch--ed-or-error)) 'text)
  (message "Click where the text goes"))

;;;; Keyboard commands

(defun esketch--nudge (dx dy)
  (let* ((ed (esketch--ed-or-error)) (ids (esketch--selected-ids ed)))
    (when ids
      (esketch--edit ed (esketch-move-many (esketch-ed-doc ed) ids dx dy)))))

(defun esketch-nudge-left (&optional n)
  "Move the selection N pixels left (1 by default)."
  (interactive "p") (esketch--nudge (- (or n 1)) 0))
(defun esketch-nudge-right (&optional n)
  "Move the selection N pixels right (1 by default)."
  (interactive "p") (esketch--nudge (or n 1) 0))
(defun esketch-nudge-up (&optional n)
  "Move the selection N pixels up (1 by default)."
  (interactive "p") (esketch--nudge 0 (- (or n 1))))
(defun esketch-nudge-down (&optional n)
  "Move the selection N pixels down (1 by default)."
  (interactive "p") (esketch--nudge 0 (or n 1)))
(defun esketch-nudge-left-10 () "Move the selection 10 pixels left."
  (interactive) (esketch--nudge -10 0))
(defun esketch-nudge-right-10 () "Move the selection 10 pixels right."
  (interactive) (esketch--nudge 10 0))
(defun esketch-nudge-up-10 () "Move the selection 10 pixels up."
  (interactive) (esketch--nudge 0 -10))
(defun esketch-nudge-down-10 () "Move the selection 10 pixels down."
  (interactive) (esketch--nudge 0 10))

(defun esketch-delete-selected ()
  "Delete the selected elements."
  (interactive)
  (let* ((ed (esketch--ed-or-error)) (ids (esketch--selected-ids ed)))
    (when ids
      (esketch--edit ed
        (dolist (id ids) (esketch-delete (esketch-ed-doc ed) id))
        (esketch--select ed nil)))))

(defun esketch-duplicate-selected ()
  "Copy the selection 20 pixels down and right, and select the copies."
  (interactive)
  (let* ((ed (esketch--ed-or-error)) (ids (esketch--selected-ids ed)))
    (when ids
      (esketch--edit ed
        (let ((new (esketch-duplicate (esketch-ed-doc ed) ids)))
          (esketch-move-many (esketch-ed-doc ed) new 20 20)
          (esketch--set-selection ed new))))))

(defun esketch--anchor (ed)
  "Where a new shape goes: the last click, or the middle of the view."
  (or (esketch-ed-point ed)
      (let ((v (esketch-ed-view ed)))
        (list (+ (nth 0 v) (/ (nth 2 v) 2.0)) (+ (nth 1 v) (/ (nth 3 v) 2.0))))))

(defun esketch-add-shape (type)
  "Add a shape of TYPE centred on the last click."
  (interactive (list (completing-read "Shape: " '("rectangle" "ellipse" "diamond") nil t)))
  (let* ((ed (esketch--ed-or-error))
         (p (esketch--anchor ed))
         (w (car esketch-new-shape-size)) (h (cdr esketch-new-shape-size)))
    (esketch--edit ed
      (let ((id (esketch-add (esketch-ed-doc ed)
                             (esketch-new-element type (- (car p) (/ w 2.0))
                                                  (- (cadr p) (/ h 2.0)) w h))))
        (esketch--select ed id)))))

(defun esketch-add-rectangle () "Add a rectangle at the last click."
  (interactive) (esketch-add-shape "rectangle"))
(defun esketch-add-ellipse () "Add an ellipse at the last click."
  (interactive) (esketch-add-shape "ellipse"))
(defun esketch-add-diamond () "Add a diamond at the last click."
  (interactive) (esketch-add-shape "diamond"))

(defun esketch--edge-point (type b cx cy tx ty)
  "Where the ray from the centre CX, CY toward TX, TY leaves the outline
of a TYPE shape with bounding box B."
  (let* ((dx (- tx cx)) (dy (- ty cy))
         (hw (/ (- (nth 2 b) (nth 0 b)) 2.0)) (hh (/ (- (nth 3 b) (nth 1 b)) 2.0))
         (ax (if (> hw 0) (/ (abs dx) hw) 0)) (ay (if (> hh 0) (/ (abs dy) hh) 0))
         (k (pcase type
              ("ellipse" (sqrt (+ (* ax ax) (* ay ay))))
              ("diamond" (+ ax ay))
              (_ (max ax ay)))))
    (if (<= k 0) (list cx cy) (list (+ cx (/ dx k)) (+ cy (/ dy k))))))

(defconst esketch--arrow-gap 5
  "Space between a bound arrow end and the outline of its shape.")

(defun esketch--arrow-ends (doc from to)
  "Start and end points ((X Y) (X Y)) of an arrow from FROM to TO.
Each is a shape element, whose end sits just off its outline, or a
point (X Y) used as it is."
  (let* ((box (lambda (e) (and (esketch-obj-p e) (esketch-render-element-bounds doc e))))
         (ba (funcall box from)) (bb (funcall box to))
         (ca (if ba (list (/ (+ (nth 0 ba) (nth 2 ba)) 2.0) (/ (+ (nth 1 ba) (nth 3 ba)) 2.0)) from))
         (cb (if bb (list (/ (+ (nth 0 bb) (nth 2 bb)) 2.0) (/ (+ (nth 1 bb) (nth 3 bb)) 2.0)) to))
         (pa (if ba (esketch--edge-point (esketch-get from "type") ba (car ca) (cadr ca) (car cb) (cadr cb)) ca))
         (pb (if bb (esketch--edge-point (esketch-get to "type") bb (car cb) (cadr cb) (car ca) (cadr ca)) cb))
         (len (max 1 (sqrt (+ (expt (- (car pb) (car pa)) 2) (expt (- (cadr pb) (cadr pa)) 2)))))
         (ux (/ (- (car pb) (car pa)) len)) (uy (/ (- (cadr pb) (cadr pa)) len))
         (g esketch--arrow-gap))
    (list (if ba (list (+ (car pa) (* g ux)) (+ (cadr pa) (* g uy))) pa)
          (if bb (list (- (car pb) (* g ux)) (- (cadr pb) (* g uy))) pb))))

(defun esketch--add-arrow (ed from to)
  "Add and select an arrow from FROM to TO, each a shape (bound) or a point."
  (let* ((doc (esketch-ed-doc ed))
         (ends (esketch--arrow-ends doc from to))
         (s (car ends)) (e (cadr ends)))
    (esketch--edit ed
      (let* ((arrow (esketch-new-element "arrow" (car s) (cadr s)
                                         (- (car e) (car s)) (- (cadr e) (cadr s))))
             (id (esketch-add doc arrow)))
        (esketch-put arrow "roundness" :null)
        (esketch-put arrow "width" (abs (- (car e) (car s))))
        (esketch-put arrow "height" (abs (- (cadr e) (cadr s))))
        (when (esketch-obj-p from) (esketch-bind doc id 'start (esketch-get from "id")))
        (when (esketch-obj-p to) (esketch-bind doc id 'end (esketch-get to "id")))
        (esketch--select ed id)))))

(defun esketch--draw-arrow (ed a b)
  "Add an arrow from the point A to B; an end inside a shape binds to it."
  (let* ((doc (esketch-ed-doc ed))
         (sa (esketch--bindable doc (esketch--hit doc (car a) (cadr a))))
         (sb (esketch--bindable doc (esketch--hit doc (car b) (cadr b)))))
    (when (and sa sb (equal (esketch-get sa "id") (esketch-get sb "id")))
      (setq sa nil sb nil))
    (esketch--add-arrow ed (or sa a) (or sb b))))

(defun esketch-connect ()
  "Draw an arrow from the previously selected element to the selected one."
  (interactive)
  (let* ((ed (esketch--ed-or-error))
         (doc (esketch-ed-doc ed))
         (from (esketch-ed-previous ed)) (to (esketch-ed-selected ed)))
    (unless (and from to (not (equal from to))
                 (esketch-element doc from) (esketch-element doc to))
      (user-error "Select one element, then another"))
    (esketch--add-arrow ed (esketch-element doc from) (esketch-element doc to))))

;;;; Resizing

(defun esketch--refit-text (el k)
  "Scale the font of text EL by K and fit its box to the text."
  (let* ((text (esketch-get el "text")) (font (esketch-get el "fontFamily"))
         (size (max 1 (round (* (esketch-get el "fontSize") k))))
         (sz (esketch--text-size font size text)))
    (while (and (< size 400) (or (< (car sz) esketch--min-size) (< (cadr sz) esketch--min-size)))
      (setq size (1+ size) sz (esketch--text-size font size text)))
    (esketch-put el "fontSize" size)
    (esketch-put el "width" (car sz))
    (esketch-put el "height" (cadr sz))))

(defun esketch--refit-arrow-end (doc arrow shape end)
  "Put END of ARROW back on SHAPE's outline, toward the arrow's other end."
  (let* ((pts (esketch--abs-points arrow))
         (cur (if (eq end 'start) (car pts) (car (last pts))))
         (other (if (eq end 'start) (car (last pts)) (car pts)))
         (b (esketch-render-element-bounds doc shape))
         (cx (/ (+ (nth 0 b) (nth 2 b)) 2.0)) (cy (/ (+ (nth 1 b) (nth 3 b)) 2.0))
         (p (esketch--edge-point (esketch-get shape "type") b cx cy (car other) (cdr other)))
         (dx (- (car other) (car p))) (dy (- (cdr other) (cadr p)))
         (len (sqrt (+ (* dx dx) (* dy dy))))
         (g (if (> len 0) esketch--arrow-gap 0))
         (nx (if (> len 0) (+ (car p) (* g (/ dx len))) (car p)))
         (ny (if (> len 0) (+ (cadr p) (* g (/ dy len))) (cadr p))))
    (esketch--shift-end arrow end (- nx (car cur)) (- ny (cdr cur)))
    (esketch--touch arrow)))

(defun esketch-resize (doc id dw dh &optional keep-ratio)
  "Grow the rectangle, ellipse, diamond or text ID by DW, DH, at least 10 x 10.
KEEP-RATIO keeps its proportions.  A text is resized by its font
size.  A bound label is centred again and arrow ends bound to the
shape are put back on its outline."
  (let ((el (esketch--live-element doc id)))
    (when (and el (member (esketch-get el "type") '("rectangle" "ellipse" "diamond" "text")))
      (let* ((w (float (esketch-get el "width"))) (h (float (esketch-get el "height")))
             (nw (max esketch--min-size (+ w dw))) (nh (max esketch--min-size (+ h dh)))
             (text (equal (esketch-get el "type") "text")))
        (when (or keep-ratio text)
          (let ((k (max (/ nw w) (/ nh h) (/ esketch--min-size w) (/ esketch--min-size h))))
            (setq nw (* w k) nh (* h k))))
        (if text
            (esketch--refit-text el (/ nh h))
          (esketch-put el "width" nw)
          (esketch-put el "height" nh))
        (esketch--touch el)
        (let ((label (esketch--label doc el)))
          (when label
            (esketch--place-label doc label el)
            (esketch--touch label)))
        (dolist (b (esketch--bound-list el))
          (let ((arrow (esketch--live-element doc (esketch-get b "id"))))
            (when (and arrow (esketch--linear-p arrow))
              (let ((s (equal (esketch--bound-to arrow 'start) id))
                    (e (equal (esketch--bound-to arrow 'end) id)))
                (unless (and s e)
                  (cond (s (esketch--refit-arrow-end doc arrow el 'start))
                        (e (esketch--refit-arrow-end doc arrow el 'end))))))))))))

(defun esketch--text-size (font size text)
  (let ((lines (split-string text "\n")))
    (list (or (esketch-render--text-width font size text)
              (* 0.6 size (apply #'max (mapcar #'length lines))))
          (* (length lines) size 1.25))))

(defun esketch--place-label (doc text-el container)
  "Centre TEXT-EL in CONTAINER, sized to its text, as Excalidraw does."
  (let* ((sz (esketch--text-size (esketch-get text-el "fontFamily")
                                 (esketch-get text-el "fontSize")
                                 (esketch-get text-el "text")))
         (b (esketch-render-element-bounds doc container)))
    (esketch-put text-el "width" (car sz))
    (esketch-put text-el "height" (cadr sz))
    (esketch-put text-el "x" (- (/ (+ (nth 0 b) (nth 2 b)) 2.0) (/ (car sz) 2.0)))
    (esketch-put text-el "y" (- (/ (+ (nth 1 b) (nth 3 b)) 2.0) (/ (cadr sz) 2.0)))))

(defun esketch-edit-text (text)
  "Set the text of the selection to TEXT.
A shape gets or updates its label; text is replaced; with nothing
selected, a text is added at the last click."
  (interactive
   (let* ((ed (esketch--ed-or-error))
          (doc (esketch-ed-doc ed))
          (el (and (esketch-ed-selected ed) (esketch-element doc (esketch-ed-selected ed))))
          (label (and el (esketch--label doc el))))
     (list (read-string "Text: " (cond (label (esketch-get label "text"))
                                       ((and el (equal (esketch-get el "type") "text"))
                                        (esketch-get el "text")))))))
  (let* ((ed (esketch--ed-or-error))
         (doc (esketch-ed-doc ed))
         (el (and (esketch-ed-selected ed) (esketch-element doc (esketch-ed-selected ed)))))
    (esketch--edit ed
      (cond
       ((and el (equal (esketch-get el "type") "text"))
        (esketch-put el "text" text)
        (esketch-put el "originalText" text)
        (let ((sz (esketch--text-size (esketch-get el "fontFamily")
                                      (esketch-get el "fontSize") text)))
          (esketch-put el "width" (car sz))
          (esketch-put el "height" (cadr sz)))
        (esketch--touch el))
       ((and el (member (esketch-get el "type") '("rectangle" "ellipse" "diamond")))
        (let ((label (esketch--label doc el)))
          (unless label
            (setq label (esketch-new-element "text" 0 0 0 0))
            (esketch-put label "textAlign" "center")
            (esketch-put label "verticalAlign" "middle")
            (esketch-put label "containerId" (esketch-get el "id"))
            (esketch-add doc label)
            (esketch--bound-add el (esketch-get label "id") "text")
            (esketch--touch el))
          (esketch-put label "text" text)
          (esketch-put label "originalText" text)
          (esketch--place-label doc label el)
          (esketch--touch label)))
       (t (esketch--select ed (esketch--new-text doc text (esketch--anchor ed))))))))

(defun esketch--new-text (doc text p)
  "Add a text TEXT at the point P to DOC; return its id."
  (let ((tx (esketch-new-element "text" (car p) (cadr p) 0 0)))
    (esketch-put tx "text" text)
    (esketch-put tx "originalText" text)
    (let ((sz (esketch--text-size (esketch-get tx "fontFamily") (esketch-get tx "fontSize") text)))
      (esketch-put tx "width" (car sz))
      (esketch-put tx "height" (cadr sz)))
    (esketch-add doc tx)))

(defun esketch-add-text (text &optional point)
  "Add the text TEXT at POINT (X Y), by default the last click, and select it."
  (interactive (list (read-string "Text: ")))
  (let ((ed (esketch--ed-or-error)))
    (if (string-empty-p text)
        (message "No text given")
      (esketch--edit ed
        (esketch--select ed (esketch--new-text (esketch-ed-doc ed) text
                                               (or point (esketch--anchor ed))))))))

(defun esketch--label (doc el)
  (let ((b (cl-find "text" (esketch--bound-list el)
                    :key (lambda (x) (esketch-get x "type")) :test #'equal)))
    (and b (esketch--live-element doc (esketch-get b "id")))))

;;;; Menus

(defconst esketch--menu-colors
  '(("Black" . "#1e1e1e") ("Red" . "#e03131") ("Green" . "#2f9e44")
    ("Blue" . "#1971c2") ("Orange" . "#f08c00")))

(defconst esketch--menu-backgrounds
  '(("None" . "transparent") ("Red" . "#ffc9c9") ("Green" . "#b2f2bb")
    ("Blue" . "#a5d8ff") ("Yellow" . "#ffec99")))

(defun esketch--menu-pane (title prop values &optional labels)
  "A menu pane TITLE whose items set PROP to each of VALUES."
  (cons title
        (mapcar (lambda (v)
                  (cons (if labels (format "%s %s" (car v) (cdr v)) (format "%s" v))
                        (cons prop (if labels (cdr v) v))))
                values)))

(defun esketch--font-targets (doc ids)
  "The texts a font size applies to: those of IDS, or their shapes' labels."
  (delq nil
        (mapcar (lambda (id)
                  (let ((el (esketch-element doc id)))
                    (if (equal (esketch-get el "type") "text") el (esketch--label doc el))))
                ids)))

(defun esketch-menu-spec (ed &optional id)
  "The `x-popup-menu' menu for the element ID of ED, or for empty canvas.
Each item's value is (PROPERTY . VALUE), applied by `esketch-menu-apply'."
  (if id
      (cons "Style"
            (append
             (list (esketch--menu-pane "Stroke" "strokeColor" esketch--menu-colors t)
                   (esketch--menu-pane "Background" "backgroundColor" esketch--menu-backgrounds t)
                   (esketch--menu-pane "Stroke width" "strokeWidth" '(1 2 4))
                   (esketch--menu-pane "Roughness" "roughness" '(0 1 2)))
             (when (esketch--font-targets (esketch-ed-doc ed)
                                          (or (esketch--selected-ids ed) (list id)))
               (list (esketch--menu-pane "Font size" "fontSize" '(16 20 28 36))))))
    (list "Add"
          (cons "Add here"
                (mapcar (lambda (type) (cons (capitalize type) (cons "add" type)))
                        '("rectangle" "ellipse" "diamond" "text"))))))

(defun esketch-menu-apply (ed choice &optional text)
  "Carry out CHOICE, an item value of `esketch-menu-spec', on ED.
Properties go to every selected element, as one undo step; adding goes
at the last click.  TEXT is the text to add, asked for when nil."
  (let ((prop (car choice)) (value (cdr choice)) (doc (esketch-ed-doc ed)))
    (cond
     ((equal prop "add")
      (if (equal value "text")
          (esketch-add-text (or text (read-string "Text: ")))
        (esketch-add-shape value)))
     ((equal prop "fontSize")
      (let ((targets (esketch--font-targets doc (esketch--selected-ids ed))))
        (when targets
          (esketch--edit ed
            (dolist (tx targets)
              (esketch-put tx "fontSize" value)
              (let ((c (esketch-get tx "containerId")))
                (if (and (stringp c) (esketch--live-element doc c))
                    (esketch--place-label doc tx (esketch-element doc c))
                  (let ((sz (esketch--text-size (esketch-get tx "fontFamily") value
                                                (esketch-get tx "text"))))
                    (esketch-put tx "width" (car sz))
                    (esketch-put tx "height" (cadr sz)))))
              (esketch--touch tx))))))
     (t
      (let ((ids (esketch--selected-ids ed)))
        (when ids
          (esketch--edit ed
            (dolist (id ids)
              (let ((el (esketch-element doc id)))
                (esketch-put el prop value)
                (esketch--touch el))))))))))

(defun esketch-context-menu (event)
  "Pop up the style menu of the element under the mouse, or the add menu."
  (interactive "e")
  (let* ((ed (esketch--ed-or-error))
         (p (esketch--posn-point ed (event-start event)))
         (id (esketch--hit (esketch-ed-doc ed) (car p) (cadr p))))
    (setf (esketch-ed-point ed) p)
    (cond ((null id) (esketch--select ed nil))
          ((not (member id (esketch-ed-selection ed))) (esketch--select ed id)))
    (esketch--redisplay ed)
    (let ((choice (x-popup-menu event (esketch-menu-spec ed id))))
      (when choice (esketch-menu-apply ed choice)))))

;;;; Saving and export

(defun esketch-save ()
  "Write the drawing to its file."
  (interactive)
  (let ((ed (esketch--ed-or-error)))
    (esketch-write-file (esketch-ed-efile ed) (esketch-ed-file ed))
    (set-buffer-modified-p nil)
    (message "Wrote %s" (esketch-ed-file ed))))

;;;###autoload
(defun esketch-export-svg (file &optional out)
  "Write the drawing FILE as a standalone SVG to OUT (FILE with .svg)."
  (interactive "fDrawing: ")
  (let ((out (or out (concat (file-name-sans-extension file) ".svg"))))
    (with-temp-file out
      (insert (esketch-render-svg (esketch-file-doc (esketch-read-file file)))))
    out))

;;;; Browser editor

(defconst esketch--dir (file-name-directory (or load-file-name buffer-file-name))
  "Directory esketch was loaded from; the page template lives below it.")

(defcustom esketch-page-directory temporary-file-directory
  "Where `esketch-browse' writes the editor page."
  :type 'directory)

(defun esketch-page-write (doc name file)
  "Write the offline Excalidraw page for DOC to FILE; NAME names saves."
  (let ((json (replace-regexp-in-string
               "</" "<\\/" (esketch-json-write-to-string doc) t t)))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents (expand-file-name "assets/esketch-page.html" esketch--dir)))
      (goto-char (point-min))
      (search-forward "__ESKETCH_NAME__")
      (replace-match (replace-regexp-in-string "[<>&]" "_" name) t t)
      (search-forward "__ESKETCH_DATA__")
      (replace-match json t t)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region nil nil file nil 'silent)))
    file))

(defun esketch-browse ()
  "Open the drawing in the browser editor (Excalidraw, offline).
Its Send to Emacs button copies the drawing and saves it to the
download directory; `esketch-import' brings it back."
  (interactive)
  (let* ((ed (esketch--ed-or-error))
         (name (file-name-base (esketch-ed-file ed)))
         (page (expand-file-name (format "esketch-%s.html" name) esketch-page-directory)))
    (esketch-page-write (esketch-ed-doc ed) name page)
    (setf (esketch-ed-browsed ed) (float-time))
    (esketch--watch ed)
    (browse-url-of-file page)
    page))

;;;; Coming back from the browser

(defcustom esketch-download-directory
  (or (and (fboundp 'xdg-user-dir) (ignore-errors (xdg-user-dir "DOWNLOAD")))
      (expand-file-name "~/Downloads"))
  "Where the browser saves what its Send to Emacs button sends."
  :type 'directory)

(declare-function xdg-user-dir "xdg" (name))

(defun esketch--summary (old new)
  (let ((ids (lambda (d) (mapcar (lambda (e) (cons (esketch-get e "id") e))
                                (cl-remove-if-not #'esketch-live-p
                                                  (append (esketch-elements d) nil)))))
        (added 0) (changed 0) (removed 0))
    (let ((o (funcall ids old)) (n (funcall ids new)))
      (dolist (e n)
        (let ((was (cdr (assoc (car e) o))))
          (cond ((null was) (setq added (1+ added)))
                ((not (equal (esketch-get was "version") (esketch-get (cdr e) "version")))
                 (setq changed (1+ changed))))))
      (dolist (e o) (unless (assoc (car e) n) (setq removed (1+ removed)))))
    (format "%d added, %d changed, %d removed" added changed removed)))

(defun esketch--parse-drawing (json)
  (let ((doc (condition-case nil (esketch-json-read-from-string json)
               (error (user-error "Not an Excalidraw drawing")))))
    (unless (and (esketch-obj-p doc) (equal (esketch-get doc "type") "excalidraw")
                 (vectorp (esketch-get doc "elements")))
      (user-error "Not an Excalidraw drawing"))
    doc))

(defun esketch-import-json (json &optional ed)
  "Replace the drawing of ED with JSON, as one undo step.  Return a summary."
  (let* ((ed (or ed (esketch--ed-or-error)))
         (doc (esketch--parse-drawing json))
         (summary (esketch--summary (esketch-ed-doc ed) doc)))
    (esketch--snapshot ed)
    (esketch--set-doc ed doc)
    (esketch--redisplay ed)
    (message "From the browser: %s (u undoes)" summary)
    summary))

(defun esketch--download-candidate (ed)
  "Newest save of ED's drawing in the download directory since the page opened."
  (let* ((name (regexp-quote (file-name-base (esketch-ed-file ed))))
         (re (concat "\\`" name " ?\\(?:([0-9]+)\\)?\\.excalidraw\\'"))
         (since (or (esketch-ed-browsed ed) 0))
         (best nil) (best-time 0))
    (when (file-directory-p esketch-download-directory)
      (dolist (f (directory-files esketch-download-directory t re))
        (let ((tm (float-time (file-attribute-modification-time (file-attributes f)))))
          (when (and (>= tm since) (> tm best-time))
            (setq best f best-time tm)))))
    best))

(defun esketch-import ()
  "Bring the drawing back from the browser editor.
Uses the clipboard when it holds a drawing, else the newest save in
`esketch-download-directory'."
  (interactive)
  (let* ((ed (esketch--ed-or-error))
         (clip (ignore-errors (gui-get-selection 'CLIPBOARD 'UTF8_STRING)))
         (from-clip (and (stringp clip) (string-match-p "\"type\": *\"excalidraw\"" clip))))
    (if from-clip
        (esketch-import-json clip ed)
      (let ((f (esketch--download-candidate ed)))
        (unless f (user-error "Nothing from the browser yet: use its Send to Emacs button"))
        (esketch-import-json (with-temp-buffer
                               (let ((coding-system-for-read 'utf-8-unix))
                                 (insert-file-contents f))
                               (buffer-string))
                             ed)))))

(defvar esketch-after-external-save-hook nil
  "Run with the drawing file after a browser save was written to it.")

(defun esketch--watch (ed)
  "Import saves from the browser into ED as they land."
  (esketch--unwatch ed)
  (when (and (file-directory-p esketch-download-directory)
             (fboundp 'file-notify-add-watch))
    (let ((buf (current-buffer)))
      (setf (esketch-ed-watch ed)
            (ignore-errors
              (file-notify-add-watch
               esketch-download-directory '(change)
               (lambda (event)
                 (when (memq (nth 1 event) '(created changed))
                   (run-at-time 0.2 nil #'esketch--on-download ed buf)))))))))

(defun esketch--unwatch (ed)
  (when (esketch-ed-watch ed)
    (ignore-errors (file-notify-rm-watch (esketch-ed-watch ed)))
    (setf (esketch-ed-watch ed) nil)))

(defun esketch--on-download (ed buf)
  (let ((f (esketch--download-candidate ed)))
    (when (and f (not (equal f (esketch-ed-point-file ed))))
      (let ((json (with-temp-buffer
                    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents f))
                    (buffer-string))))
        (when (ignore-errors (esketch--parse-drawing json))
          (setf (esketch-ed-point-file ed) f)
          (setf (esketch-ed-browsed ed)
                (float-time (file-attribute-modification-time (file-attributes f))))
          (if (and (buffer-live-p buf) (overlay-buffer (esketch-ed-overlay ed)))
              (with-current-buffer buf (esketch-import-json json ed))
            (esketch--unwatch ed)
            (let ((ef (esketch-ed-efile ed)))
              (setf (esketch-file-doc ef) (esketch--parse-drawing json))
              (esketch-write-file ef (esketch-ed-file ed))
              (run-hook-with-args 'esketch-after-external-save-hook (esketch-ed-file ed)))))))))

;;;; Editor setup

(defvar esketch-edit-map
  (let ((m (make-sparse-keymap)))
    (dolist (k '([down-mouse-1] [S-down-mouse-1] [C-down-mouse-1] [M-down-mouse-1]))
      (define-key m k #'esketch-mouse-down))
    (define-key m [mouse-1] #'esketch-mouse-click)
    (define-key m [C-mouse-1] #'ignore)
    (define-key m [drag-mouse-1] #'esketch-mouse-drag)
    (define-key m [S-drag-mouse-1] #'esketch-mouse-drag)
    (define-key m [M-drag-mouse-1] #'esketch-mouse-drag)
    (define-key m [C-drag-mouse-1] #'ignore)
    (define-key m [double-mouse-1] #'esketch-edit-text)
    (define-key m [down-mouse-2] #'ignore)
    (define-key m [mouse-2] #'ignore)
    (define-key m [drag-mouse-2] #'esketch-mouse-pan)
    (define-key m [down-mouse-3] #'esketch-context-menu)
    (define-key m [mouse-3] #'ignore)
    (dolist (k '([C-wheel-up] [C-mouse-4]))
      (define-key m k #'esketch-zoom-in))
    (dolist (k '([C-wheel-down] [C-mouse-5]))
      (define-key m k #'esketch-zoom-out))
    (define-key m (kbd "TAB") #'esketch-select-next)
    (define-key m (kbd "<backtab>") #'esketch-select-previous)
    (define-key m "a" #'esketch-arrow-tool)
    (define-key m "t" #'esketch-text-tool)
    (define-key m "D" #'esketch-duplicate-selected)
    (define-key m "0" #'esketch-view-reset)
    (define-key m (kbd "RET") #'esketch-edit-text)
    (define-key m (kbd "DEL") #'esketch-delete-selected)
    (define-key m (kbd "<delete>") #'esketch-delete-selected)
    (define-key m (kbd "<left>") #'esketch-nudge-left)
    (define-key m (kbd "<right>") #'esketch-nudge-right)
    (define-key m (kbd "<up>") #'esketch-nudge-up)
    (define-key m (kbd "<down>") #'esketch-nudge-down)
    (define-key m (kbd "S-<left>") #'esketch-nudge-left-10)
    (define-key m (kbd "S-<right>") #'esketch-nudge-right-10)
    (define-key m (kbd "S-<up>") #'esketch-nudge-up-10)
    (define-key m (kbd "S-<down>") #'esketch-nudge-down-10)
    (define-key m "r" #'esketch-add-rectangle)
    (define-key m "o" #'esketch-add-ellipse)
    (define-key m "d" #'esketch-add-diamond)
    (define-key m "c" #'esketch-connect)
    (define-key m "b" #'esketch-browse)
    (define-key m "i" #'esketch-import)
    (define-key m "u" #'esketch-undo)
    (define-key m (kbd "C-/") #'esketch-undo)
    (define-key m "U" #'esketch-redo)
    (define-key m (kbd "C-?") #'esketch-redo)
    m)
  "Keys and mouse bindings over a drawing being edited.")

(defun esketch--start (file overlay)
  "Start editing FILE in OVERLAY of the current buffer; return the editor."
  (let ((ed (esketch-ed--make :efile (esketch-read-file file)
                              :file (expand-file-name file)
                              :overlay overlay)))
    (overlay-put overlay 'keymap esketch-edit-map)
    (overlay-put overlay 'esketch-editor t)
    (setq esketch--ed ed)
    (esketch--redisplay ed)
    ed))

(defvar esketch-file-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-x C-s") #'esketch-save)
    (define-key m (kbd "C-c C-e") #'esketch-export-current-svg)
    m))

(define-derived-mode esketch-file-mode special-mode "esketch"
  "A drawing in its own buffer."
  (setq buffer-read-only t))

(defun esketch-export-current-svg ()
  "Export the drawing of this buffer as SVG next to its file."
  (interactive)
  (let ((ed (esketch--ed-or-error)))
    (message "Wrote %s" (esketch-export-svg (esketch-ed-file ed)))))

;;;###autoload
(defun esketch-open (file)
  "Open the Excalidraw drawing FILE for viewing and editing.  Return the buffer."
  (interactive "fDrawing: ")
  (let ((buf (generate-new-buffer (format "*esketch %s*" (file-name-nondirectory file)))))
    (with-current-buffer buf
      (esketch-file-mode)
      (let ((inhibit-read-only t))
        (insert " ")
        (esketch--start file (make-overlay (point-min) (point-max))))
      (goto-char (point-min)))
    (when (called-interactively-p 'any) (pop-to-buffer buf))
    buf))

(provide 'esketch)
;;; esketch.el ends here
