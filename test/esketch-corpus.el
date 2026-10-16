;;; esketch-corpus.el --- save every corpus file unmodified  -*- lexical-binding: t; -*-

;;; Commentary:

;; Called by `make test-corpus' with the corpus directory and the directory of
;; what JavaScript writes for each file.  Fails unless every file is
;; reproduced exactly, and reports how many were also byte-identical to
;; their source.  Then edits each file at random and fails if an edit adds a
;; broken or stale link that was not already there.

;;; Code:

(require 'esketch-json)
(require 'esketch-model)
(require 'esketch-test)

(defun esketch-corpus--slurp (file)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (buffer-string)))

(defun esketch-corpus-run ()
  (let* ((dir (pop command-line-args-left))
         (want-dir (pop command-line-args-left))
         (files (directory-files dir t "\\.excalidraw\\'"))
         (tmp (make-temp-file "esketch-corpus" nil ".excalidraw"))
         (bad 0) (identical 0) (elements 0) (t0 (float-time)))
    (unwind-protect
        (dolist (f files)
          (let ((ef (esketch-read-file f)))
            (setq elements (+ elements (length (esketch-elements (esketch-file-doc ef)))))
            (esketch-write-file ef tmp)
            (let ((got (esketch-corpus--slurp tmp)))
              (if (equal got (esketch-corpus--slurp
                              (expand-file-name (file-name-nondirectory f) want-dir)))
                  (when (equal got (esketch-corpus--slurp f))
                    (setq identical (1+ identical)))
                (setq bad (1+ bad))
                (message "MISMATCH %s" (file-name-nondirectory f))))))
      (delete-file tmp))
    (message "corpus: %d files, %d elements, %d match JSON.stringify, %d byte-identical to source, %.2f s"
             (length files) elements (- (length files) bad) identical
             (- (float-time) t0))
    (let ((worse (esketch-corpus--edit-check files)))
      (kill-emacs (if (and files (= bad 0) (= worse 0)) 0 1)))))

(defun esketch-corpus--edit-check (files)
  "Random edits on each of FILES; return how many added a link problem."
  (random "esketch-corpus")
  (let ((worse 0) (seqs 0) (errfiles 0))
    (dolist (f files)
      (when (esketch-binding-errors (esketch-file-doc (esketch-read-file f)))
        (setq errfiles (1+ errfiles))
        (message "ERRORS before any edit: %s" (file-name-nondirectory f)))
      (dotimes (_ 10)
        (let* ((doc (esketch-file-doc (esketch-read-file f)))
               (before (esketch-binding-stale doc)))
          (setq seqs (1+ seqs))
          (catch 'next
            (dotimes (_ 10)
              (esketch-test--random-op doc)
              (let ((new (append (esketch-binding-errors doc)
                                 (cl-set-difference (esketch-binding-stale doc)
                                                    before :test #'equal))))
                (when new
                  (setq worse (1+ worse))
                  (message "WORSE %s: %s" (file-name-nondirectory f) (car new))
                  (throw 'next nil))))))))
    (message "corpus edits: %d files with link errors as read, %d sequences, %d added a problem"
             errfiles seqs worse)
    (+ worse errfiles)))

(provide 'esketch-corpus)
;;; esketch-corpus.el ends here
