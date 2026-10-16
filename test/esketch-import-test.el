;;; esketch-import-test.el --- ERT suite for the browser round trip  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/esketch-import-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'filenotify)
(require 'esketch)
(require 'esketch-editor-test)

(defun esketch-import-test--edited-json (ed)
  "What the page would send back: the drawing with rect1 moved."
  (let ((doc (copy-tree (esketch-ed-doc ed) t)))
    (esketch-move doc "rect1" 50 0)
    (esketch-json-write-to-string doc)))

(ert-deftest esketch-import-test-json ()
  (esketch-editor-test--with-editor ed
    (let ((summary (esketch-import-json (esketch-import-test--edited-json ed))))
      (should (= (esketch-get (esketch-editor-test--el ed "rect1") "x") 150))
      (should (string-match-p "changed" summary))
      (esketch-undo)
      (should (= (esketch-get (esketch-editor-test--el ed "rect1") "x") 100)))))

(ert-deftest esketch-import-test-rejects-other-json ()
  (esketch-editor-test--with-editor ed
    (should-error (esketch-import-json "{\"type\":\"something\"}") :type 'user-error)
    (should-error (esketch-import-json "not json") :type 'user-error)
    (should (= (esketch-get (esketch-editor-test--el ed "rect1") "x") 100))))

(ert-deftest esketch-import-test-picks-newest-download ()
  (esketch-editor-test--with-editor ed
    (let* ((dir (make-temp-file "esketch-dl" t))
           (esketch-download-directory dir)
           (name (file-name-base (esketch-ed-file ed))))
      (unwind-protect
          (progn
            (setf (esketch-ed-browsed ed) (- (float-time) 100))
            (with-temp-file (expand-file-name "other.excalidraw" dir) (insert "{}"))
            (with-temp-file (expand-file-name (concat name ".excalidraw") dir) (insert "{}"))
            (set-file-times (expand-file-name (concat name ".excalidraw") dir)
                            (time-subtract nil 50))
            (with-temp-file (expand-file-name (concat name " (1).excalidraw") dir) (insert "{}"))
            (should (equal (file-name-nondirectory (esketch--download-candidate ed))
                           (concat name " (1).excalidraw")))
            ;; files older than the page are never picked
            (setf (esketch-ed-browsed ed) (+ (float-time) 100))
            (should (null (esketch--download-candidate ed))))
        (delete-directory dir t)))))

(ert-deftest esketch-import-test-watch ()
  "A save landing in the download directory reaches the editor within 2 s."
  (esketch-editor-test--with-editor ed
    (let* ((dir (make-temp-file "esketch-dl" t))
           (esketch-download-directory dir)
           (name (file-name-base (esketch-ed-file ed)))
           (json (esketch-import-test--edited-json ed)))
      (unwind-protect
          (progn
            (setf (esketch-ed-browsed ed) (- (float-time) 1))
            (esketch--watch ed)
            (let ((t0 (float-time)))
              (with-temp-file (expand-file-name (concat name ".excalidraw") dir) (insert json))
              (while (and (< (- (float-time) t0) 3)
                          (= (esketch-get (esketch-editor-test--el ed "rect1") "x") 100))
                ;; batch Emacs dispatches file-notify events only while reading input
                (read-event nil nil 0.05))
              (should (= (esketch-get (esketch-editor-test--el ed "rect1") "x") 150))
              (should (< (- (float-time) t0) 2))))
        (esketch--unwatch ed)
        (delete-directory dir t)))))

(ert-deftest esketch-import-test-page ()
  "The page carries the drawing and the name, and nothing from the network."
  (esketch-editor-test--with-editor ed
    (let ((page (make-temp-file "esketch-page" nil ".html")))
      (unwind-protect
          (let ((html (progn (esketch-page-write (esketch-ed-doc ed) "basic" page)
                             (with-temp-buffer (insert-file-contents page) (buffer-string)))))
            (should-not (string-match-p "__ESKETCH_DATA__\\|__ESKETCH_NAME__" html))
            (should (string-match-p "<script type=\"text/plain\" id=\"esketch-name\">basic</script>" html))
            (should (string-match-p "\"id\": \"rect1\"" html))
            (let* ((a (string-match "<script type=\"module\">" html))
                   (b (string-match "</script>" html a))
                   (markup (concat (substring html 0 a) (substring html b))))
              (should (< (length markup) 2000000))
              (should-not (string-match-p "<script[^>]+src=\\|<link[^>]+href=\\|@import" markup))))
        (delete-file page)))))

(ert-deftest esketch-import-test-org-after-commit ()
  "A browser save after the Org editor closed updates the file and the preview."
  (esketch-editor-test--with-org file
    (let* ((dir (make-temp-file "esketch-dl" t))
           (esketch-download-directory dir))
      (unwind-protect
          (progn
            (goto-char (point-min))
            (search-forward "esketch:")
            (esketch-org-edit)
            (let ((ed esketch--ed) (json nil))
              (setq json (esketch-import-test--edited-json ed))
              (setf (esketch-ed-browsed ed) (- (float-time) 1))
              (esketch--watch ed)
              (esketch-org-commit)
              (let ((before (overlay-get (car (esketch-editor-test--org-overlays)) 'display))
                    (t0 (float-time)))
                (with-temp-file (expand-file-name
                                 (concat (file-name-base file) ".excalidraw") dir)
                  (insert json))
                (while (and (< (- (float-time) t0) 3)
                            (= 100 (esketch-get (esketch-element
                                                 (esketch-file-doc (esketch-read-file file))
                                                 "rect1")
                                                "x")))
                  (read-event nil nil 0.05))
                (should (< (- (float-time) t0) 2))
                (should (= 150 (esketch-get (esketch-element
                                             (esketch-file-doc (esketch-read-file file))
                                             "rect1")
                                            "x")))
                (should-not (eq before (overlay-get (car (esketch-editor-test--org-overlays))
                                                    'display))))))
        (delete-directory dir t)))))

(provide 'esketch-import-test)
;;; esketch-import-test.el ends here
