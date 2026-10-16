;;; esketch-integrity-test.el --- nothing but a save writes the drawing  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/esketch-integrity-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'esketch)
(require 'esketch-org)
(require 'esketch-editor-test)

(defmacro esketch-integrity-test--unchanged (file &rest body)
  "Run BODY and require FILE to be neither changed nor rewritten.
An unmodified drawing saves byte for byte, so a stray write shows only
in the modification time; the file is first dated an hour back."
  (declare (indent 1))
  `(progn
     (set-file-times ,file (time-subtract nil 3600))
     (let ((before (esketch-editor-test--sha ,file))
           (mtime (file-attribute-modification-time (file-attributes ,file))))
       ,@body
       (should (equal (esketch-editor-test--sha ,file) before))
       (should (equal (file-attribute-modification-time (file-attributes ,file)) mtime)))))

(ert-deftest esketch-integrity-test-read-only-commands ()
  "Opening, viewing, rendering, exporting and browsing never write the drawing."
  (let* ((file (esketch-editor-test--copy-fixture))
         (svg (concat file ".svg"))
         (pages (make-temp-file "esketch-pages" t))
         (page (expand-file-name "x.html" pages))
         (esketch-page-directory pages))
    (unwind-protect
        (esketch-integrity-test--unchanged file
          (let ((buf (esketch-open file)))
            (with-current-buffer buf
              (esketch-editor-test--click esketch--ed 120 110)
              (let ((browse-url-browser-function #'ignore)
                    (esketch-download-directory (file-name-directory page)))
                (esketch-browse)
                (esketch--unwatch esketch--ed)))
            (kill-buffer buf))
          (esketch-render-svg (esketch-file-doc (esketch-read-file file)))
          (esketch-export-svg file svg)
          (esketch-page-write (esketch-file-doc (esketch-read-file file)) "x" page))
      (dolist (f (list file svg)) (when (file-exists-p f) (delete-file f)))
      (delete-directory pages t))))

(ert-deftest esketch-integrity-test-org ()
  "Showing a drawing in Org, editing it and discarding, leave the file alone."
  (esketch-editor-test--with-org file
    (esketch-integrity-test--unchanged file
      (esketch-org-refresh)
      (goto-char (point-min))
      (search-forward "esketch:")
      (esketch-org-edit)
      (esketch-editor-test--drag esketch--ed 120 110 160 130)
      (esketch-org-discard)
      (esketch-org-mode -1)
      (esketch-org-mode 1))))

(provide 'esketch-integrity-test)
;;; esketch-integrity-test.el ends here
