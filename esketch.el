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

(cl-defstruct (esketch-ed (:constructor esketch-ed--make))
  efile file overlay view (scale esketch-scale)
  selected previous undo redo point on-close)

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
    (when v
      (setq x1 (min x1 (nth 0 v)) y1 (min y1 (nth 1 v))
            x2 (max x2 (+ (nth 0 v) (nth 2 v))) y2 (max y2 (+ (nth 1 v) (nth 3 v)))))
    (setf (esketch-ed-view ed) (list x1 y1 (max 200 (- x2 x1)) (max 120 (- y2 y1))))))

(defun esketch-ed-doc (ed)
  (esketch-file-doc (esketch-ed-efile ed)))

(defun esketch--selection-svg (ed)
  (let* ((doc (esketch-ed-doc ed))
         (el (and (esketch-ed-selected ed) (esketch-element doc (esketch-ed-selected ed)))))
    (when el
      (let ((b (esketch-render-element-bounds doc el)) (pad 6))
        (format "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"1\" stroke-dasharray=\"6 4\"/>"
                (esketch-render--num (- (nth 0 b) pad)) (esketch-render--num (- (nth 1 b) pad))
                (esketch-render--num (+ (- (nth 2 b) (nth 0 b)) (* 2 pad)))
                (esketch-render--num (+ (- (nth 3 b) (nth 1 b)) (* 2 pad)))
                esketch--selection-color)))))

(defun esketch--redisplay (ed)
  (esketch--fit-view ed)
  (overlay-put (esketch-ed-overlay ed) 'display
               (create-image (esketch-render-svg (esketch-ed-doc ed) (esketch-ed-view ed)
                                                 (esketch--selection-svg ed))
                             'svg t :scale (esketch-ed-scale ed))))

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

;;;; Commands

(defun esketch--select (ed id)
  (unless (equal id (esketch-ed-selected ed))
    (when (esketch-ed-selected ed)
      (setf (esketch-ed-previous ed) (esketch-ed-selected ed)))
    (setf (esketch-ed-selected ed) id)))

(defun esketch-mouse-down (event)
  "Select what is under the mouse."
  (interactive "e")
  (let* ((ed (esketch--ed-or-error))
         (p (esketch--posn-point ed (event-start event))))
    (setf (esketch-ed-point ed) p)
    (esketch--select ed (esketch--hit (esketch-ed-doc ed) (car p) (cadr p)))
    (esketch--redisplay ed)))

(defun esketch-mouse-drag (event)
  "Move the selection by the distance dragged."
  (interactive "e")
  (let* ((ed (esketch--ed-or-error))
         (a (esketch--posn-point ed (event-start event)))
         (b (esketch--posn-point ed (event-end event)))
         (id (esketch-ed-selected ed)))
    (when id
      (esketch--edit ed
        (esketch-move (esketch-ed-doc ed) id (- (car b) (car a)) (- (cadr b) (cadr a))))
      (setf (esketch-ed-point ed) b))))

(defun esketch--nudge (dx dy)
  (let ((ed (esketch--ed-or-error)))
    (when (esketch-ed-selected ed)
      (esketch--edit ed (esketch-move (esketch-ed-doc ed) (esketch-ed-selected ed) dx dy)))))

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
  "Delete the selected element."
  (interactive)
  (let ((ed (esketch--ed-or-error)))
    (when (esketch-ed-selected ed)
      (esketch--edit ed
        (esketch-delete (esketch-ed-doc ed) (esketch-ed-selected ed))
        (setf (esketch-ed-selected ed) nil)))))

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

(defun esketch-connect ()
  "Draw an arrow from the previously selected element to the selected one."
  (interactive)
  (let* ((ed (esketch--ed-or-error))
         (doc (esketch-ed-doc ed))
         (from (esketch-ed-previous ed)) (to (esketch-ed-selected ed)))
    (unless (and from to (not (equal from to))
                 (esketch-element doc from) (esketch-element doc to))
      (user-error "Select one element, then another"))
    (let* ((ba (esketch-render-element-bounds doc (esketch-element doc from)))
           (bb (esketch-render-element-bounds doc (esketch-element doc to)))
           (ca (list (/ (+ (nth 0 ba) (nth 2 ba)) 2.0) (/ (+ (nth 1 ba) (nth 3 ba)) 2.0)))
           (cb (list (/ (+ (nth 0 bb) (nth 2 bb)) 2.0) (/ (+ (nth 1 bb) (nth 3 bb)) 2.0)))
           (gap 5)
           (pa (esketch--edge-point (esketch-get (esketch-element doc from) "type") ba (car ca) (cadr ca) (car cb) (cadr cb)))
           (pb (esketch--edge-point (esketch-get (esketch-element doc to) "type") bb (car cb) (cadr cb) (car ca) (cadr ca)))
           (len (max 1 (sqrt (+ (expt (- (car pb) (car pa)) 2) (expt (- (cadr pb) (cadr pa)) 2)))))
           (ux (/ (- (car pb) (car pa)) len)) (uy (/ (- (cadr pb) (cadr pa)) len))
           (sx (+ (car pa) (* gap ux))) (sy (+ (cadr pa) (* gap uy)))
           (ex (- (car pb) (* gap ux))) (ey (- (cadr pb) (* gap uy))))
      (esketch--edit ed
        (let* ((arrow (esketch-new-element "arrow" sx sy (- ex sx) (- ey sy)))
               (id (esketch-add doc arrow)))
          (esketch-put arrow "roundness" :null)
          (esketch-put arrow "width" (abs (- ex sx)))
          (esketch-put arrow "height" (abs (- ey sy)))
          (esketch-bind doc id 'start from)
          (esketch-bind doc id 'end to)
          (esketch--select ed id))))))

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
       (t
        (let* ((p (esketch--anchor ed))
               (tx (esketch-new-element "text" (car p) (cadr p) 0 0)))
          (esketch-put tx "text" text)
          (esketch-put tx "originalText" text)
          (let ((sz (esketch--text-size 5 20 text)))
            (esketch-put tx "width" (car sz))
            (esketch-put tx "height" (cadr sz)))
          (esketch--select ed (esketch-add doc tx))))))))

(defun esketch--label (doc el)
  (let ((b (cl-find "text" (esketch--bound-list el)
                    :key (lambda (x) (esketch-get x "type")) :test #'equal)))
    (and b (esketch--live-element doc (esketch-get b "id")))))

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

;;;; Editor setup

(defvar esketch-edit-map
  (let ((m (make-sparse-keymap)))
    (define-key m [down-mouse-1] #'esketch-mouse-down)
    (define-key m [mouse-1] #'ignore)
    (define-key m [drag-mouse-1] #'esketch-mouse-drag)
    (define-key m [double-mouse-1] #'esketch-edit-text)
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
