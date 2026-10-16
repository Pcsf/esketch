;;; esketch-editor-test.el --- ERT suite for the esketch editor  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/esketch-editor-test.el -f ert-run-tests-batch-and-exit
;;
;; Mouse commands are driven with constructed events whose positions carry
;; the image coordinates Emacs reports for a click on an image.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'esketch)
(require 'esketch-org)

(defconst esketch-editor-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun esketch-editor-test--copy-fixture ()
  (let ((f (make-temp-file "esketch" nil ".excalidraw")))
    (copy-file (expand-file-name "data/basic.excalidraw" esketch-editor-test--dir) f t)
    f))

(defun esketch-editor-test--sha (file)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defmacro esketch-editor-test--with-editor (var &rest body)
  "Open a copy of the basic fixture in an editor bound to VAR, run BODY."
  (declare (indent 1))
  `(let* ((file (esketch-editor-test--copy-fixture))
          (buf (esketch-open file)))
     (unwind-protect
         (with-current-buffer buf
           (let ((,var esketch--ed))
             ,@body))
       (kill-buffer buf)
       (delete-file file))))

(defun esketch-editor-test--posn (ed x y)
  "A mouse position over ED's image at drawing point X, Y."
  (let* ((view (esketch-ed-view ed))
         (s (esketch-ed-scale ed))
         (px (round (* (- x (nth 0 view)) s)))
         (py (round (* (- y (nth 1 view)) s)))
         (ov (esketch-ed-overlay ed)))
    (list (selected-window) (overlay-start ov) (cons 0 0) 0 nil (overlay-start ov)
          (cons 0 0) (overlay-get ov 'display) (cons px py) (cons 10 10))))

(defun esketch-editor-test--click (ed x y)
  (esketch-mouse-down (list 'down-mouse-1 (esketch-editor-test--posn ed x y))))

(defun esketch-editor-test--drag (ed x1 y1 x2 y2)
  (esketch-editor-test--click ed x1 y1)
  (esketch-mouse-drag (list 'drag-mouse-1 (esketch-editor-test--posn ed x1 y1)
                            (esketch-editor-test--posn ed x2 y2))))

(defun esketch-editor-test--el (ed id)
  (esketch-element (esketch-ed-doc ed) id))

(ert-deftest esketch-editor-test-open-shows-image ()
  (esketch-editor-test--with-editor ed
    (should (eq (car (overlay-get (esketch-ed-overlay ed) 'display)) 'image))
    (should (eq (plist-get (cdr (overlay-get (esketch-ed-overlay ed) 'display)) :type)
                'svg))))

(ert-deftest esketch-editor-test-click-selects-topmost ()
  (esketch-editor-test--with-editor ed
    (esketch-editor-test--click ed 120 110)
    (should (equal (esketch-ed-selected ed) "rect1"))
    ;; text bound inside a shape selects the shape, as in Excalidraw
    (esketch-editor-test--click ed 200 140)
    (should (equal (esketch-ed-selected ed) "rect1"))
    (esketch-editor-test--click ed 580 140)
    (should (equal (esketch-ed-selected ed) "ell1"))
    (esketch-editor-test--click ed 400 140)
    (should (equal (esketch-ed-selected ed) "arrow1"))
    (esketch-editor-test--click ed 1000 1000)
    (should (null (esketch-ed-selected ed)))))

(ert-deftest esketch-editor-test-drag-moves-and-undoes ()
  (esketch-editor-test--with-editor ed
    (esketch-editor-test--drag ed 120 110 150 120)
    (let ((r (esketch-editor-test--el ed "rect1")))
      (should (= (esketch-get r "x") 130))
      (should (= (esketch-get r "y") 110)))
    (should (= (esketch-get (esketch-editor-test--el ed "arrow1") "x") 335))
    (should (equal (esketch-binding-errors (esketch-ed-doc ed)) nil))
    (esketch-undo)
    (should (= (esketch-get (esketch-editor-test--el ed "rect1") "x") 100))
    (esketch-redo)
    (should (= (esketch-get (esketch-editor-test--el ed "rect1") "x") 130))))

(ert-deftest esketch-editor-test-nudge ()
  (esketch-editor-test--with-editor ed
    (esketch-editor-test--click ed 120 110)
    (esketch-nudge-right)
    (esketch-nudge-right 10)
    (esketch-nudge-down)
    (let ((r (esketch-editor-test--el ed "rect1")))
      (should (= (esketch-get r "x") 111))
      (should (= (esketch-get r "y") 101)))))

(ert-deftest esketch-editor-test-delete-and-undo ()
  (esketch-editor-test--with-editor ed
    (esketch-editor-test--click ed 580 140)
    (esketch-delete-selected)
    (should (eq (esketch-get (esketch-editor-test--el ed "ell1") "isDeleted") t))
    (should (null (esketch-ed-selected ed)))
    (esketch-undo)
    (should (eq (esketch-get (esketch-editor-test--el ed "ell1") "isDeleted") :false))))

(ert-deftest esketch-editor-test-add-shapes ()
  (esketch-editor-test--with-editor ed
    (esketch-editor-test--click ed 900 500)
    (dolist (type '("rectangle" "ellipse" "diamond"))
      (let ((n (length (esketch-elements (esketch-ed-doc ed)))))
        (esketch-add-shape type)
        (should (= (length (esketch-elements (esketch-ed-doc ed))) (1+ n)))
        (let ((el (esketch-editor-test--el ed (esketch-ed-selected ed))))
          (should (equal (esketch-get el "type") type))
          (should (= (+ (esketch-get el "x") (/ (esketch-get el "width") 2.0)) 900)))))))

(ert-deftest esketch-editor-test-connect ()
  (esketch-editor-test--with-editor ed
    (esketch-editor-test--click ed 580 140)
    (esketch-editor-test--click ed 200 360)
    (esketch-connect)
    (let* ((doc (esketch-ed-doc ed))
           (arrow (esketch-editor-test--el ed (esketch-ed-selected ed))))
      (should (equal (esketch-get arrow "type") "arrow"))
      (should (equal (esketch-get (esketch-get arrow "startBinding") "elementId") "ell1"))
      (should (equal (esketch-get (esketch-get arrow "endBinding") "elementId") "dia1"))
      (should (equal (esketch-binding-errors doc) nil))
      (should (equal (esketch-binding-stale doc) nil)))))

(ert-deftest esketch-editor-test-connect-touches-outlines ()
  "Connector ends sit just off the shapes' outlines, not their boxes."
  (esketch-editor-test--with-editor ed
    (esketch-editor-test--click ed 580 140)
    (esketch-editor-test--click ed 200 360)
    (esketch-connect)
    (let* ((a (esketch-editor-test--el ed (esketch-ed-selected ed)))
           (pts (esketch-get a "points"))
           (sx (esketch-get a "x")) (sy (esketch-get a "y"))
           (ex (+ sx (aref (aref pts 1) 0))) (ey (+ sy (aref (aref pts 1) 1)))
           ;; ellipse ell1: centre 580,140, radii 80,50; diamond dia1: centre
           ;; 200,360, half sizes 80,60
           (e (sqrt (+ (expt (/ (- sx 580) 80.0) 2) (expt (/ (- sy 140) 50.0) 2))))
           (d (+ (/ (abs (- ex 200)) 80.0) (/ (abs (- ey 360)) 60.0))))
      (should (< 1.0 e 1.15))
      (should (< 1.0 d 1.15)))))

(ert-deftest esketch-editor-test-edit-text ()
  (esketch-editor-test--with-editor ed
    ;; a shape with a label: the label changes and stays centred
    (esketch-editor-test--click ed 120 110)
    (esketch-edit-text "Camera")
    (let* ((tx (esketch-editor-test--el ed "text1"))
           (w (esketch-get tx "width")))
      (should (equal (esketch-get tx "text") "Camera"))
      (should (equal (esketch-get tx "originalText") "Camera"))
      (should (= w (esketch-render--text-width 5 20 "Camera")))
      (should (< (abs (- (+ (esketch-get tx "x") (/ w 2.0)) 200)) 1e-9)))
    ;; a shape without one gets a new bound label
    (esketch-editor-test--click ed 200 360)
    (esketch-edit-text "Decide")
    (let* ((doc (esketch-ed-doc ed))
           (dia (esketch-editor-test--el ed "dia1"))
           (label (cl-find "text" (append (esketch-get dia "boundElements") nil)
                           :key (lambda (b) (esketch-get b "type")) :test #'equal)))
      (should label)
      (should (equal (esketch-get (esketch-element doc (esketch-get label "id")) "text")
                     "Decide"))
      (should (equal (esketch-binding-errors doc) nil)))))

(ert-deftest esketch-editor-test-save ()
  "Saving an untouched drawing rewrites nothing; an edit is written back."
  (let* ((file (esketch-editor-test--copy-fixture))
         (sha (esketch-editor-test--sha file))
         (buf (esketch-open file)))
    (unwind-protect
        (with-current-buffer buf
          (esketch-save)
          (should (equal (esketch-editor-test--sha file) sha))
          (esketch-editor-test--drag esketch--ed 120 110 150 120)
          (esketch-save)
          (should-not (equal (esketch-editor-test--sha file) sha))
          (should (= (esketch-get (esketch-element (esketch-file-doc (esketch-read-file file))
                                                   "rect1")
                                  "x")
                     130)))
      (kill-buffer buf)
      (delete-file file))))

;;;; Org

(defmacro esketch-editor-test--with-org (file-var &rest body)
  (declare (indent 1))
  `(let ((,file-var (esketch-editor-test--copy-fixture)))
     (unwind-protect
         (with-temp-buffer
           (org-mode)
           (insert "* Notes\nBefore\n[[esketch:" ,file-var "]]\nAfter\n")
           (esketch-org-mode 1)
           ,@body)
       (delete-file ,file-var))))

(defun esketch-editor-test--org-overlays ()
  (cl-remove-if-not (lambda (o) (overlay-get o 'esketch-org))
                    (overlays-in (point-min) (point-max))))

(ert-deftest esketch-editor-test-org-inline ()
  (esketch-editor-test--with-org file
    (let ((ovs (esketch-editor-test--org-overlays)))
      (should (= (length ovs) 1))
      (should (eq (car (overlay-get (car ovs) 'display)) 'image))
      (should (equal (buffer-substring (overlay-start (car ovs)) (overlay-end (car ovs)))
                     (concat "[[esketch:" file "]]"))))))

(ert-deftest esketch-editor-test-org-edit-commit ()
  (esketch-editor-test--with-org file
    (goto-char (point-min))
    (search-forward "esketch:")
    (esketch-org-edit)
    (let ((ed esketch--ed))
      (should ed)
      (should (string-match-p "Before" (buffer-string)))
      (esketch-editor-test--drag ed 120 110 150 120)
      (esketch-org-commit)
      (should (null esketch--ed))
      (should (= (esketch-get (esketch-element (esketch-file-doc (esketch-read-file file))
                                               "rect1")
                              "x")
                 130))
      (should (= (length (esketch-editor-test--org-overlays)) 1)))))

(ert-deftest esketch-editor-test-org-edit-discard ()
  (esketch-editor-test--with-org file
    (let ((sha (esketch-editor-test--sha file)))
      (goto-char (point-min))
      (search-forward "esketch:")
      (esketch-org-edit)
      (esketch-editor-test--drag esketch--ed 120 110 150 120)
      (esketch-org-discard)
      (should (null esketch--ed))
      (should (equal (esketch-editor-test--sha file) sha))
      (should (= (length (esketch-editor-test--org-overlays)) 1)))))

(ert-deftest esketch-editor-test-org-insert ()
  (let* ((dir (make-temp-file "esketch-dir" t))
         (esketch-directory dir))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (esketch-org-mode 1)
          (esketch-org-insert "block diagram")
          (let ((files (directory-files dir nil "\\.excalidraw\\'")))
            (should (equal files '("block-diagram.excalidraw")))
            (should (string-match-p "\\[\\[esketch:.*block-diagram\\.excalidraw\\]\\]"
                                    (buffer-string)))
            (should esketch--ed)
            (let ((doc (esketch-file-doc (esketch-read-file
                                          (expand-file-name (car files) dir)))))
              (should (equal (esketch-get doc "type") "excalidraw"))
              (should (equal (esketch-elements doc) [])))))
      (delete-directory dir t))))

(ert-deftest esketch-editor-test-export-svg ()
  (let* ((file (esketch-editor-test--copy-fixture))
         (out (concat file ".svg")))
    (unwind-protect
        (progn
          (esketch-export-svg file out)
          (should (string-prefix-p "<svg" (with-temp-buffer
                                             (insert-file-contents out)
                                             (buffer-string)))))
      (delete-file file)
      (when (file-exists-p out) (delete-file out)))))

(provide 'esketch-editor-test)
;;; esketch-editor-test.el ends here
