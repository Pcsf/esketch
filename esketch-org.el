;;; esketch-org.el --- Excalidraw drawings embedded in Org  -*- lexical-binding: t; -*-

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

;; A link [[esketch:FILE.excalidraw]] shows its drawing in place while
;; `esketch-org-mode' is on.  C-c C-o or a click on the drawing edits it
;; where it sits; C-c C-c writes the change back, C-c C-k throws it away.
;; HTML export embeds the drawing as inline SVG.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ol)

(declare-function org-export-derived-backend-p "ox" (backend &rest backends))
(require 'esketch)

(defconst esketch-org--link-re "\\[\\[esketch:\\([^]]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]")

(defcustom esketch-org-preview-scale 0.75
  "Display scale of drawings shown in Org buffers."
  :type 'number
  :group 'esketch)

(defun esketch-org--file (path)
  (expand-file-name path (if buffer-file-name (file-name-directory buffer-file-name)
                           default-directory)))

(defvar esketch-org-preview-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'esketch-org-edit-at-mouse)
    (define-key m (kbd "RET") #'esketch-org-edit)
    m)
  "Keys over a drawing shown in an Org buffer.")

(defun esketch-org--preview (beg end file)
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'esketch-org t)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'keymap esketch-org-preview-map)
    (overlay-put ov 'help-echo "mouse-1, C-c C-o: edit drawing")
    (overlay-put ov 'display
                 (if (file-readable-p file)
                     (esketch-image (esketch-render-svg (esketch-file-doc (esketch-read-file file)))
                                    esketch-org-preview-scale (file-name-nondirectory file))
                   (format "[missing drawing %s]" file)))
    ov))

(defun esketch-org-refresh ()
  "Show every esketch link of the buffer as its drawing."
  (interactive)
  (esketch-org--clear)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward esketch-org--link-re nil t)
      (esketch-org--preview (match-beginning 0) (match-end 0)
                            (esketch-org--file (match-string-no-properties 1))))))

(defun esketch-org--clear ()
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'esketch-org) (delete-overlay ov))))

(defun esketch-org--link-at-point ()
  "The (BEG END FILE) of the esketch link at point."
  (save-excursion
    (let ((pos (point)) found)
      (goto-char (line-beginning-position))
      (while (and (not found) (re-search-forward esketch-org--link-re (line-end-position) t))
        (when (<= (match-beginning 0) pos (match-end 0))
          (setq found (list (match-beginning 0) (match-end 0)
                            (esketch-org--file (match-string-no-properties 1))))))
      found)))

(defvar esketch-org-edit-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m esketch-edit-map)
    (define-key m (kbd "C-c C-c") #'esketch-org-commit)
    (define-key m (kbd "C-c C-k") #'esketch-org-discard)
    m)
  "Keys over a drawing being edited in an Org buffer.")

(defun esketch-org-edit ()
  "Edit the drawing of the esketch link at point, in place."
  (interactive)
  (when esketch--ed (user-error "Finish the drawing being edited first (C-c C-c)"))
  (let ((link (esketch-org--link-at-point)))
    (unless link (user-error "No esketch link here"))
    (dolist (ov (overlays-in (nth 0 link) (nth 1 link)))
      (when (overlay-get ov 'esketch-org) (delete-overlay ov)))
    (let ((ov (make-overlay (nth 0 link) (nth 1 link) nil t nil)))
      (esketch--start (nth 2 link) ov)
      (overlay-put ov 'keymap esketch-org-edit-map)
      (overlay-put ov 'help-echo "C-c C-c: save drawing, C-c C-k: discard")
      (goto-char (nth 0 link))
      (message "Editing drawing: C-c C-c saves, C-c C-k discards"))))

(defun esketch-org-edit-at-mouse (event)
  "Edit the drawing clicked on."
  (interactive "e")
  (goto-char (posn-point (event-start event)))
  (esketch-org-edit))

(defun esketch-org--finish (save)
  (let ((ed (or esketch--ed (user-error "No drawing is being edited"))))
    (when save
      (esketch-write-file (esketch-ed-efile ed) (esketch-ed-file ed)))
    (delete-overlay (esketch-ed-overlay ed))
    (setq esketch--ed nil)
    (esketch-org-refresh)))

(defun esketch-org-commit ()
  "Write the drawing being edited and show it again."
  (interactive)
  (esketch-org--finish t))

(defun esketch-org-discard ()
  "Drop the changes to the drawing being edited."
  (interactive)
  (esketch-org--finish nil))

(defun esketch-org--slug (name)
  (let ((s (downcase (replace-regexp-in-string "[^[:alnum:]]+" "-" name))))
    (replace-regexp-in-string "\\`-+\\|-+\\'" "" s)))

;;;###autoload
(defun esketch-org-insert (name)
  "Create a drawing called NAME in `esketch-directory', link it here, edit it."
  (interactive "sDrawing name: ")
  (make-directory esketch-directory t)
  (let ((file (expand-file-name (concat (esketch-org--slug name) ".excalidraw")
                                esketch-directory)))
    (when (file-exists-p file) (user-error "%s exists" file))
    (esketch-write-file
     (esketch-file--make
      :doc (list :obj (cons "type" "excalidraw") (cons "version" 2)
                 (cons "source" "esketch") (cons "elements" [])
                 (cons "appState" (list :obj (cons "gridSize" 20)
                                        (cons "viewBackgroundColor" "#ffffff")))
                 (cons "files" (list :obj)))
      :newline nil)
     file)
    (insert (format "[[esketch:%s]]" (abbreviate-file-name file)))
    (backward-char 2)
    (esketch-org-edit)))

(defun esketch-org--follow (_path _arg)
  (esketch-org-edit))

(defun esketch-org--export (path desc backend)
  (let ((file (esketch-org--file path)))
    (cond ((and (org-export-derived-backend-p backend 'html) (file-readable-p file))
           (esketch-render-svg (esketch-file-doc (esketch-read-file file))))
          (t (or desc path)))))

(defun esketch-org--refresh-all (_file)
  "Refresh the drawings of every Org buffer showing them."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (and (bound-and-true-p esketch-org-mode) (not esketch--ed))
        (esketch-org-refresh)))))

(add-hook 'esketch-after-external-save-hook #'esketch-org--refresh-all)

(org-link-set-parameters "esketch" :follow #'esketch-org--follow
                         :export #'esketch-org--export)

;;;###autoload
(define-minor-mode esketch-org-mode
  "Show esketch links of this Org buffer as drawings."
  :lighter " esketch"
  (if esketch-org-mode
      (progn (esketch-org-refresh)
             (add-hook 'after-save-hook #'esketch-org-refresh nil t))
    (esketch-org--clear)
    (remove-hook 'after-save-hook #'esketch-org-refresh t)))

(provide 'esketch-org)
;;; esketch-org.el ends here
