;;; esketch-style-test.el --- sketchy and clean drawing styles  -*- lexical-binding: t; -*-

;;; Commentary:

;; Clean style must draw exactly what the same drawing draws with every
;; element's roughness set to 0 (Excalidraw's "architect"), and switching it
;; must redraw what is shown without touching the file.

;;; Code:

(require 'ert)
(require 'org)
(require 'esketch)
(require 'esketch-org)
(require 'esketch-editor-test)

(defun esketch-style-test--doc ()
  (esketch-file-doc (esketch-read-file (expand-file-name "data/basic.excalidraw"
                                                         esketch-editor-test--dir))))

(ert-deftest esketch-style-test-clean-is-roughness-zero ()
  (let* ((doc (esketch-style-test--doc))
         (zero (copy-tree doc t)))
    (mapc (lambda (el) (esketch-put el "roughness" 0)) (esketch-elements zero))
    (let ((clean (let ((esketch-render-style 'plain) (esketch-render-plain-font nil))
                   (esketch-render-svg doc)))
          (hand (let ((esketch-render-style 'hand)) (esketch-render-svg doc)))
          (want (let ((esketch-render-style 'hand)) (esketch-render-svg zero))))
      (should (equal clean want))
      (should-not (equal clean hand)))))

(ert-deftest esketch-style-test-is-a-user-option ()
  (should (custom-variable-p 'esketch-render-style)))

(ert-deftest esketch-style-test-clean-text-font ()
  "Clean style writes text in a plain sans-serif font unless told not to."
  (let ((el (esketch-new-element "text" 0 0 99 25)))
    (esketch-put el "text" "Sensor")
    (let ((esketch-render-style 'plain) (esketch-render-plain-font t))
      (should (string-match-p "<text[^>]*font-family=\"Helvetica" (esketch-render--text-svg el))))
    (let ((esketch-render-style 'plain) (esketch-render-plain-font nil))
      (should (string-match-p "esketch-text" (esketch-render--text-svg el))))
    (let ((esketch-render-style 'hand) (esketch-render-plain-font t))
      (should (string-match-p "esketch-text" (esketch-render--text-svg el))))))

(ert-deftest esketch-style-test-toggle-redraws-editor-not-file ()
  (esketch-editor-test--with-editor ed
    (let ((esketch-render-style 'hand)
          (before (overlay-get (esketch-ed-overlay ed) 'display))
          (sha (esketch-editor-test--sha (esketch-ed-file ed))))
      (should (eq (key-binding "s") 'esketch-toggle-style))
      (esketch-toggle-style)
      (should (eq esketch-render-style 'plain))
      (when (image-type-available-p 'svg)
        (should-not (equal (overlay-get (esketch-ed-overlay ed) 'display) before)))
      (esketch-toggle-style)
      (should (eq esketch-render-style 'hand))
      (should (equal (esketch-editor-test--sha (esketch-ed-file ed)) sha)))))

(ert-deftest esketch-style-test-toggle-redraws-org-previews ()
  (esketch-editor-test--with-org file
    (let* ((esketch-render-style 'hand)
           (ov (lambda () (car (esketch-editor-test--org-overlays))))
           (before (overlay-get (funcall ov) 'display)))
      (goto-char (point-min))
      (search-forward "esketch:")
      (should (eq (key-binding "s") 'esketch-toggle-style))
      (esketch-toggle-style)
      (should (eq esketch-render-style 'plain))
      (when (image-type-available-p 'svg)
        (should-not (equal (overlay-get (funcall ov) 'display) before))))))

(provide 'esketch-style-test)
;;; esketch-style-test.el ends here
