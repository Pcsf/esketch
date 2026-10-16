;;; esketch-keys-test.el --- editor keys reach their commands  -*- lexical-binding: t; -*-

;;; Commentary:

;; Keys must work wherever point is while a drawing is being edited, and
;; `b' must open the browser editor from a drawing shown in Org.

;;; Code:

(require 'ert)
(require 'org)
(require 'esketch)
(require 'esketch-org)
(require 'esketch-editor-test)

(ert-deftest esketch-keys-test-org-preview-b-browses ()
  "b on a drawing shown in Org opens it in the browser editor."
  (esketch-editor-test--with-org file
    (let* ((dir (make-temp-file "esketch-pages" t))
           (esketch-page-directory dir)
           (esketch-download-directory dir)
           (browse-url-browser-function #'ignore))
      (unwind-protect
          (progn
            (goto-char (point-min))
            (search-forward "esketch:")
            (should (eq (key-binding "b") 'esketch-org-browse))
            (call-interactively (key-binding "b"))
            (should esketch--ed)
            (should (file-exists-p (expand-file-name
                                    (format "esketch-%s.html" (file-name-base file)) dir)))
            (esketch--unwatch esketch--ed)
            (esketch-org-discard))
        (delete-directory dir t)))))

(ert-deftest esketch-keys-test-org-editing-keys-anywhere ()
  "While editing, the editor keys work with point anywhere in the buffer."
  (esketch-editor-test--with-org file
    (goto-char (point-min))
    (search-forward "esketch:")
    (esketch-org-edit)
    (dolist (pos (list (point-min) (point-max)))
      (goto-char pos)
      (should (eq (key-binding "b") 'esketch-browse))
      (should (eq (key-binding "r") 'esketch-add-rectangle))
      (should (eq (key-binding (kbd "C-c C-c")) 'esketch-org-commit))
      (should (eq (key-binding (kbd "C-c C-k")) 'esketch-org-discard)))
    (esketch-org-discard)
    (goto-char (point-max))
    (should (eq (key-binding "b") 'org-self-insert-command))))

(ert-deftest esketch-keys-test-file-buffer-keys-anywhere ()
  "In a drawing's own buffer the keys work at the end of the buffer too."
  (esketch-editor-test--with-editor ed
    (goto-char (point-max))
    (should (eq (key-binding "b") 'esketch-browse))
    (should (eq (key-binding "r") 'esketch-add-rectangle))))

(provide 'esketch-keys-test)
;;; esketch-keys-test.el ends here
