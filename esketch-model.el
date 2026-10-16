;;; esketch-model.el --- Excalidraw document edits for esketch  -*- lexical-binding: t; -*-

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

;; Edits on an Excalidraw document as read by esketch-json: add, move,
;; delete, bind and unbind, each keeping the links between arrows, shapes and
;; their text consistent the way Excalidraw expects:
;;
;;   arrow.startBinding/endBinding.elementId  <->  shape.boundElements {arrow}
;;   text.containerId                         <->  shape.boundElements {text}
;;
;; Deletion is soft (isDeleted true), as in Excalidraw.  Every changed element
;; gets a new version, versionNonce and updated time, which Excalidraw uses
;; to reconcile copies of a drawing.

;;; Code:

(require 'cl-lib)
(require 'esketch-json)

;;;; Lookup

(defun esketch-elements (doc)
  (or (esketch-get doc "elements") []))

(defun esketch-element (doc id)
  (cl-find id (esketch-elements doc)
           :key (lambda (el) (esketch-get el "id")) :test #'equal))

(defun esketch-live-p (el)
  (not (eq (esketch-get el "isDeleted") t)))

(defun esketch--live-element (doc id)
  (let ((el (and (stringp id) (esketch-element doc id))))
    (and el (esketch-live-p el) el)))

(defun esketch--linear-p (el)
  (member (esketch-get el "type") '("arrow" "line")))

(defun esketch--binding-key (end)
  (pcase end
    ('start "startBinding")
    ('end "endBinding")
    (_ (error "esketch: end must be `start' or `end', not %S" end))))

(defun esketch--bound-to (arrow end)
  "Id of the element ARROW's END is bound to, or nil."
  (let ((b (esketch-get arrow (esketch--binding-key end))))
    (and (esketch-obj-p b) (esketch-get b "elementId"))))

;;;; Identity, ordering, versions

(defconst esketch--id-alphabet
  "useandom-26T198340PX75pxJACKVERYMINDBUSHWOLF_GQZbfghjklqvwyzrict"
  "nanoid's URL-safe alphabet, which Excalidraw ids use.")

(defun esketch-new-id ()
  (let ((s (make-string 21 ?a)))
    (dotimes (i 21) (aset s i (aref esketch--id-alphabet (random 64))))
    s))

(defun esketch--now-ms ()
  (truncate (* 1000 (float-time))))

(defun esketch--touch (el)
  (esketch-put el "version" (1+ (or (esketch-get el "version") 0)))
  (esketch-put el "versionNonce" (random 2147483647))
  (esketch-put el "updated" (esketch--now-ms)))

(defconst esketch--base62
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

(defun esketch--int-length (head)
  (cond ((<= ?a head ?z) (+ (- head ?a) 2))
        ((<= ?A head ?Z) (+ (- ?Z head) 2))
        (t (error "esketch: bad index head %c" head))))

(defun esketch--midpoint-after (a)
  "Shortest base-62 fraction above A, as the fractional-indexing library does."
  (let ((da (if (string= a "") 0 (cl-position (aref a 0) esketch--base62))))
    (if (> (- 62 da) 1)
        (string (aref esketch--base62 (round (* 0.5 (+ da 62)))))
      (concat (string (aref esketch--base62 da))
              (esketch--midpoint-after (substring a 1))))))

(defun esketch-index-after (key)
  "Fractional index key sorting after KEY (nil for none).
Excalidraw orders elements by these keys; this is the library's
generateKeyBetween(KEY, null)."
  (if (null key)
      "a0"
    (let* ((len (esketch--int-length (aref key 0)))
           (int (substring key 0 len))
           (frac (substring key len))
           (i (1- len))
           (trailing ""))
      (catch 'done
        (while (>= i 1)
          (let ((d (1+ (cl-position (aref int i) esketch--base62))))
            (if (= d 62)
                (setq trailing (concat "0" trailing))
              (throw 'done (concat (substring int 0 i)
                                   (string (aref esketch--base62 d))
                                   trailing))))
          (setq i (1- i)))
        (let ((head (aref int 0)))
          (if (eq head ?z)
              (concat int (esketch--midpoint-after frac))
            (let* ((h (if (eq head ?Z) ?a (1+ head)))
                   (delta (- (esketch--int-length h) (esketch--int-length head))))
              (concat (string h)
                      (cond ((> delta 0) (concat trailing "0"))
                            ((< delta 0) (substring trailing 1))
                            (t trailing))))))))))

(defun esketch--last-index (doc)
  "Greatest index key in DOC, nil when empty, or :null when any is missing."
  (let ((best nil) (missing nil))
    (mapc (lambda (el)
            (let ((k (esketch-get el "index")))
              (if (stringp k)
                  (when (or (null best) (string< best k)) (setq best k))
                (setq missing t))))
          (esketch-elements doc))
    (if missing :null best)))

;;;; boundElements lists

;; Files saved before 2021 list only arrow ids, in boundElementIds.

(defun esketch--bound-list (el)
  (let ((b (esketch-get el "boundElements"))
        (legacy (esketch-get el "boundElementIds")))
    (cond ((vectorp b) (append b nil))
          ((vectorp legacy)
           (mapcar (lambda (id) (list :obj (cons "id" id) (cons "type" "arrow")))
                   legacy)))))

(defun esketch--migrate-legacy (el)
  "Move EL's boundElementIds into boundElements, as Excalidraw does on load."
  (when (and (not (vectorp (esketch-get el "boundElements")))
             (esketch-has el "boundElementIds"))
    (let ((entries (vconcat (esketch--bound-list el))))
      (esketch-del el "boundElementIds")
      (esketch-put el "boundElements" entries))))

(defun esketch--bound-has (el id)
  (cl-some (lambda (e) (equal (esketch-get e "id") id)) (esketch--bound-list el)))

(defun esketch--bound-add (el id type)
  (esketch--migrate-legacy el)
  (unless (esketch--bound-has el id)
    (esketch-put el "boundElements"
                 (vconcat (esketch--bound-list el)
                          (list (list :obj (cons "id" id) (cons "type" type)))))))

(defun esketch--bound-remove (el id)
  (esketch--migrate-legacy el)
  (when (esketch--bound-has el id)
    (esketch-put el "boundElements"
                 (vconcat (cl-remove-if (lambda (e) (equal (esketch-get e "id") id))
                                        (esketch--bound-list el))))))

;;;; Linear element geometry

(defun esketch--abs-points (el)
  (let ((x (esketch-get el "x")) (y (esketch-get el "y")))
    (mapcar (lambda (p) (cons (+ x (aref p 0)) (+ y (aref p 1))))
            (esketch-get el "points"))))

(defun esketch--set-abs-points (el pts)
  "Store absolute PTS in EL the way Excalidraw normalises them.
The first point is the element origin and width and height are the
extent of the points."
  (let ((x0 (caar pts)) (y0 (cdar pts))
        (xs (mapcar #'car pts)) (ys (mapcar #'cdr pts)))
    (esketch-put el "x" x0)
    (esketch-put el "y" y0)
    (esketch-put el "points"
                 (vconcat (mapcar (lambda (p) (vector (- (car p) x0) (- (cdr p) y0)))
                                  pts)))
    (esketch-put el "width" (- (apply #'max xs) (apply #'min xs)))
    (esketch-put el "height" (- (apply #'max ys) (apply #'min ys)))))

(defun esketch--shift-end (arrow end dx dy)
  (let* ((pts (esketch--abs-points arrow))
         (cell (if (eq end 'start) pts (last pts))))
    (setcar cell (cons (+ (caar cell) dx) (+ (cdar cell) dy)))
    (esketch--set-abs-points arrow pts)))

(defun esketch--translate (el dx dy)
  (esketch-put el "x" (+ (esketch-get el "x") dx))
  (esketch-put el "y" (+ (esketch-get el "y") dy)))

;;;; Edits

(defun esketch-new-element (type x y width height)
  "A fresh element of TYPE with Excalidraw's default fields."
  (let ((el (list :obj
                  (cons "id" (esketch-new-id)) (cons "type" type)
                  (cons "x" x) (cons "y" y)
                  (cons "width" width) (cons "height" height) (cons "angle" 0)
                  (cons "strokeColor" "#1e1e1e")
                  (cons "backgroundColor" "transparent")
                  (cons "fillStyle" "solid") (cons "strokeWidth" 2)
                  (cons "strokeStyle" "solid") (cons "roughness" 1)
                  (cons "opacity" 100) (cons "groupIds" []) (cons "frameId" :null)
                  (cons "index" :null)
                  (cons "roundness"
                        (pcase type
                          ("rectangle" (list :obj (cons "type" 3)))
                          ((or "arrow" "line") (list :obj (cons "type" 2)))
                          (_ :null)))
                  (cons "seed" (1+ (random 2147483646)))
                  (cons "version" 1) (cons "versionNonce" (random 2147483647))
                  (cons "isDeleted" :false) (cons "boundElements" :null)
                  (cons "updated" (esketch--now-ms))
                  (cons "link" :null) (cons "locked" :false))))
    (pcase type
      ((or "arrow" "line")
       (esketch-put el "points" (vector (vector 0 0) (vector width height)))
       (esketch-put el "lastCommittedPoint" :null)
       (esketch-put el "startBinding" :null)
       (esketch-put el "endBinding" :null)
       (esketch-put el "startArrowhead" :null)
       (esketch-put el "endArrowhead" (if (equal type "arrow") "arrow" :null))
       (when (equal type "arrow") (esketch-put el "elbowed" :false)))
      ("freedraw"
       (esketch-put el "points" (vector (vector 0 0)))
       (esketch-put el "pressures" [])
       (esketch-put el "simulatePressure" t)
       (esketch-put el "lastCommittedPoint" :null))
      ("text"
       (esketch-put el "text" "")
       (esketch-put el "fontSize" 20)
       (esketch-put el "fontFamily" 5)
       (esketch-put el "textAlign" "left")
       (esketch-put el "verticalAlign" "top")
       (esketch-put el "containerId" :null)
       (esketch-put el "originalText" "")
       (esketch-put el "autoResize" t)
       (esketch-put el "lineHeight" 1.25)))
    el))

(defun esketch-add (doc el)
  "Append EL to DOC on top of everything else.  Return its id."
  (let ((last (esketch--last-index doc)))
    (esketch-put el "index" (if (eq last :null) :null (esketch-index-after last))))
  (esketch-put doc "elements" (vconcat (esketch-elements doc) (list el)))
  (esketch-get el "id"))

(defun esketch-unbind (doc arrow-id end)
  "Detach END (`start' or `end') of the arrow ARROW-ID from its shape."
  (let* ((arrow (esketch-element doc arrow-id))
         (target-id (esketch--bound-to arrow end))
         (other (if (eq end 'start) 'end 'start)))
    (when target-id
      (esketch-put arrow (esketch--binding-key end) :null)
      (esketch--touch arrow)
      (let ((target (esketch-element doc target-id)))
        (when (and target (not (equal (esketch--bound-to arrow other) target-id)))
          (esketch--bound-remove target arrow-id)
          (esketch--touch target))))))

(defun esketch-bind (doc arrow-id end target-id)
  "Bind END (`start' or `end') of the arrow ARROW-ID to TARGET-ID."
  (let ((arrow (esketch--live-element doc arrow-id))
        (target (esketch--live-element doc target-id)))
    (unless (and arrow (equal (esketch-get arrow "type") "arrow"))
      (error "esketch: %s is not a live arrow" arrow-id))
    (unless (and target (not (esketch--linear-p target)))
      (error "esketch: cannot bind to %s" target-id))
    (unless (equal (esketch--bound-to arrow end) target-id)
      (esketch-unbind doc arrow-id end)
      (esketch-put arrow (esketch--binding-key end)
                   (list :obj (cons "elementId" target-id) (cons "focus" 0)
                         (cons "gap" 5) (cons "fixedPoint" :null)))
      (esketch--bound-add target arrow-id "arrow")
      (esketch--touch arrow)
      (esketch--touch target))))

(defun esketch-move (doc id dx dy)
  "Move element ID by DX, DY with what is attached to it.
A shape carries its bound text and drags the arrow ends bound to it.
Text bound in a shape moves the shape.  An arrow moved on its own
leaves the shapes it was bound to."
  (let ((el (esketch--live-element doc id)))
    (when el
      (let ((container (esketch-get el "containerId")))
        (if (and (stringp container) (esketch--live-element doc container))
            (esketch-move doc container dx dy)
          (esketch--translate el dx dy)
          (esketch--touch el)
          (when (esketch--linear-p el)
            (dolist (end '(start end))
              (when (esketch--bound-to el end)
                (esketch-unbind doc id end))))
          (dolist (b (esketch--bound-list el))
            (let ((other (esketch--live-element doc (esketch-get b "id"))))
              (when other
                (if (equal (esketch-get b "type") "text")
                    (esketch--translate other dx dy)
                  (let ((s (equal (esketch--bound-to other 'start) id))
                        (e (equal (esketch--bound-to other 'end) id)))
                    (cond ((and s e) (esketch--translate other dx dy))
                          (s (esketch--shift-end other 'start dx dy))
                          (e (esketch--shift-end other 'end dx dy)))))
                (esketch--touch other)))))))))

(defun esketch-delete (doc id)
  "Delete element ID and undo every link to it.
A shape takes its bound text with it; arrows bound to it come loose."
  (let ((el (esketch--live-element doc id)))
    (when el
      (esketch-put el "isDeleted" t)
      (esketch--touch el)
      (mapc (lambda (other)
              (when (and (esketch-live-p other) (esketch--bound-has other id))
                (esketch--bound-remove other id)
                (esketch--touch other)))
            (esketch-elements doc))
      (dolist (b (esketch--bound-list el))
        (let ((other (esketch--live-element doc (esketch-get b "id"))))
          (when other
            (if (equal (esketch-get b "type") "text")
                (progn (esketch-put other "isDeleted" t)
                       (esketch--touch other))
              (dolist (end '(start end))
                (when (equal (esketch--bound-to other end) id)
                  (esketch-put other (esketch--binding-key end) :null)))
              (esketch--touch other))))))))

;;;; Consistency

;; A link has a forward side (an arrow's binding, a text's containerId) and a
;; back side (the shape's boundElements).  Excalidraw relies on every forward
;; link being listed on the back side; that is an error.  Back-side entries
;; whose forward link is gone are left behind by Excalidraw itself and are
;; harmless; those are stale.

(defun esketch--link-problems (doc)
  "Return (ERRORS . STALE) for the live elements of DOC."
  (let ((errs nil) (stale nil))
    (mapc
     (lambda (el)
       (when (esketch-live-p el)
         (let ((id (esketch-get el "id")))
           (when (esketch--linear-p el)
             (dolist (end '(start end))
               (let ((tid (esketch--bound-to el end)))
                 (when tid
                   (let ((target (esketch--live-element doc tid)))
                     (cond ((null target)
                            (push (format "%s %s bound to missing %s" id end tid)
                                  errs))
                           ((not (esketch--bound-has target id))
                            (push (format "%s does not list arrow %s" tid id)
                                  errs))))))))
           (let ((cid (esketch-get el "containerId")))
             (when (stringp cid)
               (let ((c (esketch--live-element doc cid)))
                 (unless (and c (esketch--bound-has c id))
                   (push (format "text %s claims container %s" id cid) errs)))))
           (dolist (b (esketch--bound-list el))
             (let* ((bid (esketch-get b "id"))
                    (other (esketch--live-element doc bid)))
               (cond
                ((null other)
                 (push (format "%s lists missing %s" id bid) stale))
                ((equal (esketch-get b "type") "text")
                 (unless (equal (esketch-get other "containerId") id)
                   (push (format "%s lists text %s that is not inside it" id bid)
                         stale)))
                ((not (or (equal (esketch--bound-to other 'start) id)
                          (equal (esketch--bound-to other 'end) id)))
                 (push (format "%s lists arrow %s that is not bound to it" id bid)
                       stale))))))))
     (esketch-elements doc))
    (cons (nreverse errs) (nreverse stale))))

(defun esketch-binding-errors (doc)
  "Forward links in DOC that Excalidraw would not find listed back."
  (car (esketch--link-problems doc)))

(defun esketch-binding-stale (doc)
  "Back-side entries in DOC whose forward link is gone."
  (cdr (esketch--link-problems doc)))

(provide 'esketch-model)
;;; esketch-model.el ends here
