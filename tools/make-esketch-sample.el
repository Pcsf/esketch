;;; make-esketch-sample.el --- build test/data/esketch-made.excalidraw  -*- lexical-binding: t; -*-

;; A drawing made only with esketch's editor commands, so the Excalidraw
;; checks see exactly what esketch writes.  Run once; the result is committed.

(require 'esketch)
(require 'esketch-editor-test)

(let* ((file (expand-file-name "test/data/esketch-made.excalidraw"))
       (dir (file-name-directory file)))
  (esketch-write-file
   (esketch-file--make
    :doc (list :obj (cons "type" "excalidraw") (cons "version" 2)
               (cons "source" "esketch") (cons "elements" [])
               (cons "appState" (list :obj (cons "gridSize" 20)
                                      (cons "viewBackgroundColor" "#ffffff")))
               (cons "files" (list :obj)))
    :newline nil)
   file)
  (random "esketch-sample")
  (let ((buf (esketch-open file)))
    (with-current-buffer buf
      (let ((ed esketch--ed))
        (setf (esketch-ed-point ed) (list 100 100)) (esketch-add-shape "rectangle")
        (esketch-edit-text "Sensor")
        (setf (esketch-ed-point ed) (list 400 100)) (esketch-add-shape "ellipse")
        (esketch-edit-text "ADC")
        (setf (esketch-ed-point ed) (list 250 300)) (esketch-add-shape "diamond")
        (esketch-edit-text "Valid?")
        (esketch-editor-test--click ed 100 100) (esketch-editor-test--click ed 400 100)
        (esketch-connect)
        (esketch-editor-test--click ed 400 100) (esketch-editor-test--click ed 250 300)
        (esketch-connect)
        (esketch-editor-test--click ed 600 300) (esketch-edit-text "Notes:\nfirst draft")
        (esketch-editor-test--drag ed 400 100 420 120)
        (esketch-save)))
    (kill-buffer buf))
  (message "wrote %s" file))
