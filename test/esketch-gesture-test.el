;;; esketch-gesture-test.el --- ERT suite for the esketch editor's gestures  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/esketch-editor-test.el \
;;     -l test/esketch-gesture-test.el -f ert-run-tests-batch-and-exit
;;
;; Events are dispatched through `esketch-edit-map', so a test also proves
;; the key or mouse binding.  The last test reads README.org's gesture table.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'esketch)
(require 'esketch-editor-test)

(defconst esketch-gesture-test--readme
  (expand-file-name "../README.org" esketch-editor-test--dir))

(defmacro esketch-gesture-test--with-editor (var &rest body)
  (declare (indent 1))
  `(esketch-editor-test--with-editor ,var ,@body))

(defun esketch-gesture-test--run (ed event)
  "Run the command `esketch-edit-map' binds to EVENT's type, as Emacs would."
  (let ((cmd (lookup-key esketch-edit-map (vector (car event)))))
    (should (commandp cmd))
    (with-current-buffer (overlay-buffer (esketch-ed-overlay ed))
      (if (cdr event) (funcall cmd event) (call-interactively cmd)))))

(defun esketch-gesture-test--down (ed sym x y)
  (esketch-gesture-test--run ed (list sym (esketch-editor-test--posn ed x y))))

(defun esketch-gesture-test--gesture (ed down drag x1 y1 x2 y2)
  "Press with event type DOWN at X1, Y1 and release with DRAG at X2, Y2."
  (esketch-gesture-test--down ed down x1 y1)
  (esketch-gesture-test--run ed (list drag (esketch-editor-test--posn ed x1 y1)
                                      (esketch-editor-test--posn ed x2 y2))))

(defun esketch-gesture-test--drag (ed x1 y1 x2 y2)
  (esketch-gesture-test--gesture ed 'down-mouse-1 'drag-mouse-1 x1 y1 x2 y2))

(defun esketch-gesture-test--el (ed id) (esketch-editor-test--el ed id))
(defun esketch-gesture-test--prop (ed id key) (esketch-get (esketch-gesture-test--el ed id) key))

(defun esketch-gesture-test--ids (ed)
  (mapcar (lambda (e) (esketch-get e "id")) (esketch-elements (esketch-ed-doc ed))))

(defun esketch-gesture-test--new-ids (ed before)
  (cl-remove-if (lambda (id) (member id before)) (esketch-gesture-test--ids ed)))

(defun esketch-gesture-test--consistent (ed)
  (should (equal (esketch-binding-errors (esketch-ed-doc ed)) nil))
  (should (equal (esketch-binding-stale (esketch-ed-doc ed)) nil)))

(defun esketch-gesture-test--near (a b &optional tol)
  (< (abs (- a b)) (or tol 1e-6)))

(defun esketch-gesture-test--arrow-end (ed id end)
  "Absolute (X . Y) of END, `start' or `end', of the arrow ID."
  (let ((pts (esketch--abs-points (esketch-gesture-test--el ed id))))
    (if (eq end 'start) (car pts) (car (last pts)))))

;;;; Multi-selection

(ert-deftest esketch-gesture-test-ctrl-click-toggles ()
  (esketch-gesture-test--with-editor ed
    (esketch-gesture-test--down ed 'down-mouse-1 120 110)
    (esketch-gesture-test--down ed 'C-down-mouse-1 580 140)
    (should (equal (esketch-ed-selection ed) '("rect1" "ell1")))
    (should (equal (esketch-ed-selected ed) "ell1"))
    (esketch-gesture-test--down ed 'C-down-mouse-1 200 360)
    (should (equal (esketch-ed-selection ed) '("rect1" "ell1" "dia1")))
    (esketch-gesture-test--down ed 'C-down-mouse-1 580 140)
    (should (equal (esketch-ed-selection ed) '("rect1" "dia1")))
    (should (equal (esketch-ed-selected ed) "dia1"))
    (esketch-gesture-test--down ed 'C-down-mouse-1 1000 1000)
    (should (equal (esketch-ed-selection ed) '("rect1" "dia1")))
    (esketch-gesture-test--run ed (list 'C-mouse-1 (esketch-editor-test--posn ed 120 110)))
    (should (equal (esketch-ed-selection ed) '("rect1" "dia1")))))

(ert-deftest esketch-gesture-test-click-selects-one ()
  (esketch-gesture-test--with-editor ed
    (esketch-gesture-test--down ed 'down-mouse-1 120 110)
    (esketch-gesture-test--down ed 'C-down-mouse-1 580 140)
    (esketch-gesture-test--down ed 'down-mouse-1 200 360)
    (should (equal (esketch-ed-selection ed) '("dia1")))
    (esketch-gesture-test--down ed 'down-mouse-1 1000 1000)
    (should (null (esketch-ed-selection ed)))
    (should (null (esketch-ed-selected ed)))
    ;; a click without a drag on a member of a selection keeps only that one
    (esketch-gesture-test--down ed 'down-mouse-1 120 110)
    (esketch-gesture-test--down ed 'C-down-mouse-1 580 140)
    (esketch-gesture-test--down ed 'down-mouse-1 120 110)
    (should (equal (esketch-ed-selection ed) '("rect1" "ell1")))
    (esketch-gesture-test--run ed (list 'mouse-1 (esketch-editor-test--posn ed 120 110)))
    (should (equal (esketch-ed-selection ed) '("rect1")))))

(ert-deftest esketch-gesture-test-drag-moves-every-selected ()
  (esketch-gesture-test--with-editor ed
    (esketch-gesture-test--down ed 'down-mouse-1 120 110)
    (esketch-gesture-test--down ed 'C-down-mouse-1 200 360)
    (esketch-gesture-test--drag ed 120 110 150 130)
    (should (= (esketch-gesture-test--prop ed "rect1" "x") 130))
    (should (= (esketch-gesture-test--prop ed "rect1" "y") 120))
    (should (= (esketch-gesture-test--prop ed "dia1" "x") 150))
    (should (= (esketch-gesture-test--prop ed "dia1" "y") 320))
    (should (= (esketch-gesture-test--prop ed "text1" "x") 180.5))
    (should (= (esketch-gesture-test--prop ed "ell1" "x") 500))
    (esketch-gesture-test--consistent ed)
    (esketch-undo)
    (should (= (esketch-gesture-test--prop ed "rect1" "x") 100))
    (should (= (esketch-gesture-test--prop ed "dia1" "x") 120))))

(ert-deftest esketch-gesture-test-arrow-moves-once ()
  "An arrow selected with both its shapes is carried by them, not moved twice."
  (esketch-gesture-test--with-editor ed
    (esketch-gesture-test--down ed 'down-mouse-1 120 110)
    (esketch-gesture-test--down ed 'C-down-mouse-1 580 140)
    (esketch-gesture-test--down ed 'C-down-mouse-1 400 140)
    (should (equal (esketch-ed-selection ed) '("rect1" "ell1" "arrow1")))
    (esketch-gesture-test--drag ed 120 110 140 130)
    (let ((a (esketch-gesture-test--el ed "arrow1")))
      (should (= (esketch-get a "x") 325))
      (should (= (esketch-get a "y") 160))
      (should (= (esketch-get a "width") 190))
      (should (equal (esketch--bound-to a 'start) "rect1"))
      (should (equal (esketch--bound-to a 'end) "ell1")))
    (esketch-gesture-test--consistent ed)))

(ert-deftest esketch-gesture-test-follower-arrow-moves-free-end ()
  "An arrow bound at one end to a moved shape moves whole, staying bound."
  (esketch-gesture-test--with-editor ed
    (let* ((doc (esketch-ed-doc ed)))
      (esketch-unbind doc "arrow1" 'end)
      (esketch-move-many doc '("rect1" "arrow1") 10 20)
      (let ((a (esketch-element doc "arrow1")))
        (should (= (esketch-get a "x") 315))
        (should (= (esketch-get a "y") 160))
        (should (= (esketch-get a "width") 190))
        (should (equal (esketch--bound-to a 'start) "rect1")))
      (esketch-gesture-test--consistent ed))))

(ert-deftest esketch-gesture-test-arrow-leaves-shape-that-stays ()
  (esketch-gesture-test--with-editor ed
    (let ((doc (esketch-ed-doc ed)))
      (esketch-move-many doc '("rect1" "arrow1") 10 20)
      (let ((a (esketch-element doc "arrow1")))
        (should (= (esketch-get a "x") 315))
        (should (= (esketch-get a "width") 190))
        (should (null (esketch--bound-to a 'start)))
        (should (null (esketch--bound-to a 'end))))
      (should (= (esketch-get (esketch-element doc "ell1") "x") 500))
      (esketch-gesture-test--consistent ed))))

(ert-deftest esketch-gesture-test-nudge-delete-duplicate-act-on-all ()
  (esketch-gesture-test--with-editor ed
    (esketch-gesture-test--down ed 'down-mouse-1 120 110)
    (esketch-gesture-test--down ed 'C-down-mouse-1 200 360)
    (esketch-nudge-right 10)
    (should (= (esketch-gesture-test--prop ed "rect1" "x") 110))
    (should (= (esketch-gesture-test--prop ed "dia1" "x") 130))
    (let ((before (esketch-gesture-test--ids ed)))
      (esketch-gesture-test--run ed (list ?D))
      (let ((new (esketch-gesture-test--new-ids ed before)))
        (should (= (length new) 3))
        (should (= (length (esketch-ed-selection ed)) 2))
        (dolist (id (esketch-ed-selection ed)) (should (member id new)))))
    (esketch--set-selection ed '("rect1" "dia1"))
    (esketch-delete-selected)
    (should (eq (esketch-gesture-test--prop ed "rect1" "isDeleted") t))
    (should (eq (esketch-gesture-test--prop ed "text1" "isDeleted") t))
    (should (eq (esketch-gesture-test--prop ed "dia1" "isDeleted") t))
    (should (null (esketch-ed-selection ed)))
    (esketch-gesture-test--consistent ed)))

(ert-deftest esketch-gesture-test-selection-box-around-each ()
  (esketch-gesture-test--with-editor ed
    (esketch--set-selection ed '("rect1" "ell1" "dia1"))
    (should (= (with-temp-buffer
                 (insert (esketch--selection-svg ed))
                 (how-many "stroke-dasharray" (point-min)))
               3))
    (esketch--set-selection ed '("rect1"))
    (should (= (with-temp-buffer
                 (insert (esketch--selection-svg ed))
                 (how-many "stroke-dasharray" (point-min)))
               1))
    (esketch--set-selection ed nil)
    (should (equal (esketch--selection-svg ed) ""))))

;;;; Resize

(defun esketch-gesture-test--press-handle (ed dx dy &optional down drag)
  "Drag the resize handle of the selection by DX, DY."
  (let ((h (esketch--handle ed)))
    (should h)
    (esketch-gesture-test--gesture ed (or down 'down-mouse-1) (or drag 'drag-mouse-1)
                                   (car h) (cadr h) (+ (car h) dx) (+ (cadr h) dy))))

(ert-deftest esketch-gesture-test-handle-drawn ()
  (esketch-gesture-test--with-editor ed
    (esketch--select ed "rect1")
    (should (equal (esketch--handle ed) '(306 186)))
    (let ((svg (esketch--selection-svg ed)))
      (should (string-match-p "fill=\"#ffffff\"" svg))
      (should (string-match-p "x=\"302\" y=\"182\" width=\"8\" height=\"8\"" svg)))
    (dolist (id '("ell1" "dia1"))
      (esketch--select ed id)
      (should (esketch--handle ed)))
    (esketch--select ed "arrow1")
    (should (null (esketch--handle ed)))
    (esketch--set-selection ed '("rect1" "ell1"))
    (should (null (esketch--handle ed)))
    (should-not (string-match-p "fill=\"#ffffff\"" (esketch--selection-svg ed)))))

(ert-deftest esketch-gesture-test-resize-by-handle ()
  (esketch-gesture-test--with-editor ed
    (esketch--select ed "rect1")
    (esketch-gesture-test--press-handle ed 50 20)
    (should (= (esketch-gesture-test--prop ed "rect1" "x") 100))
    (should (= (esketch-gesture-test--prop ed "rect1" "width") 250))
    (should (= (esketch-gesture-test--prop ed "rect1" "height") 100))
    (should (equal (esketch-ed-selection ed) '("rect1")))
    (esketch-gesture-test--consistent ed)
    (esketch-undo)
    (should (= (esketch-gesture-test--prop ed "rect1" "width") 200))
    (should (= (esketch-gesture-test--prop ed "rect1" "height") 80))
    (should (= (esketch-gesture-test--prop ed "arrow1" "x") 305))))

(ert-deftest esketch-gesture-test-resize-minimum ()
  (esketch-gesture-test--with-editor ed
    (dolist (id '("rect1" "ell1" "dia1"))
      (esketch--select ed id)
      (esketch-gesture-test--press-handle ed -1000 -1000)
      (should (= (esketch-gesture-test--prop ed id "width") 10))
      (should (= (esketch-gesture-test--prop ed id "height") 10)))
    (esketch-gesture-test--consistent ed)))

(ert-deftest esketch-gesture-test-resize-recentres-label ()
  (esketch-gesture-test--with-editor ed
    (esketch--select ed "rect1")
    (esketch-gesture-test--press-handle ed 60 40)
    (let* ((tx (esketch-gesture-test--el ed "text1"))
           (w (esketch-get tx "width")) (h (esketch-get tx "height")))
      (should (esketch-gesture-test--near (+ (esketch-get tx "x") (/ w 2.0)) (+ 100 130)))
      (should (esketch-gesture-test--near (+ (esketch-get tx "y") (/ h 2.0)) (+ 100 60))))))

(defun esketch-gesture-test--gap-ok (q c hw hh type)
  "Whether Q lies 5 px off the outline of a TYPE shape centred C, half sizes HW, HH."
  (let* ((ax (/ (abs (- (car q) (car c))) hw)) (ay (/ (abs (- (cdr q) (cdr c))) hh))
         (k (pcase type
              ("ellipse" (sqrt (+ (* ax ax) (* ay ay))))
              ("diamond" (+ ax ay))
              (_ (max ax ay))))
         (dist (sqrt (+ (expt (- (car q) (car c)) 2) (expt (- (cdr q) (cdr c)) 2)))))
    (and (> k 1) (esketch-gesture-test--near (* dist (- 1 (/ 1.0 k))) 5 1e-6))))

(defun esketch-gesture-test--collinear (a b c)
  (< (abs (- (* (- (car b) (car a)) (- (cdr c) (cdr a)))
             (* (- (cdr b) (cdr a)) (- (car c) (car a)))))
     1e-6))

(ert-deftest esketch-gesture-test-resize-replaces-arrow-ends ()
  (esketch-gesture-test--with-editor ed
    (let ((other-end (esketch-gesture-test--arrow-end ed "arrow1" 'end)))
      (esketch--select ed "rect1")
      (esketch-gesture-test--press-handle ed 50 20)
      (let ((q (esketch-gesture-test--arrow-end ed "arrow1" 'start)))
        (should (equal (esketch-gesture-test--arrow-end ed "arrow1" 'end) (cons 495.0 140.5)))
        (should (esketch-gesture-test--gap-ok q '(225.0 . 150.0) 125 50 "rectangle"))
        (should (esketch-gesture-test--collinear '(225.0 . 150.0) q other-end)))
      (esketch-gesture-test--consistent ed))
    (let ((other-start (esketch-gesture-test--arrow-end ed "arrow1" 'start)))
      (esketch--select ed "ell1")
      (esketch-gesture-test--press-handle ed 40 -20)
      (let ((q (esketch-gesture-test--arrow-end ed "arrow1" 'end)))
        (should (= (car (esketch-gesture-test--arrow-end ed "arrow1" 'start)) (car other-start)))
        (should (= (cdr (esketch-gesture-test--arrow-end ed "arrow1" 'start)) (cdr other-start)))
        (should (esketch-gesture-test--gap-ok q '(600.0 . 130.0) 100 40 "ellipse"))
        (should (esketch-gesture-test--collinear '(600.0 . 130.0) q other-start)))
      (esketch-gesture-test--consistent ed)
      (should (equal (esketch--bound-to (esketch-gesture-test--el ed "arrow1") 'end) "ell1")))))

(ert-deftest esketch-gesture-test-resize-diamond-arrow ()
  (esketch-gesture-test--with-editor ed
    (esketch--set-selection ed '("ell1"))
    (esketch--select ed "rect1")
    (esketch--select ed "dia1")
    (esketch-connect)
    (let ((id (esketch-ed-selected ed)))
      (esketch--select ed "dia1")
      (esketch-gesture-test--press-handle ed 40 30)
      (let* ((a (esketch-gesture-test--el ed id))
             (kinds (list (esketch--bound-to a 'start) (esketch--bound-to a 'end))))
        (should (member "dia1" kinds))
        (let* ((end (if (equal (car kinds) "dia1") 'start 'end))
               (other (if (eq end 'start) 'end 'start))
               (q (esketch-gesture-test--arrow-end ed id end)))
          (should (esketch-gesture-test--gap-ok q '(220.0 . 375.0) 100 75 "diamond"))
          (should (esketch-gesture-test--collinear
                   '(220.0 . 375.0) q (esketch-gesture-test--arrow-end ed id other))))
        (esketch-gesture-test--consistent ed)))))

(ert-deftest esketch-gesture-test-resize-keeps-ratio ()
  (esketch-gesture-test--with-editor ed
    (esketch--select ed "rect1")
    (esketch-gesture-test--press-handle ed 100 0 'S-down-mouse-1 'S-drag-mouse-1)
    (should (= (esketch-gesture-test--prop ed "rect1" "width") 300))
    (should (= (esketch-gesture-test--prop ed "rect1" "height") 120))
    (let ((id (esketch-add (esketch-ed-doc ed)
                           (esketch-new-element "rectangle" 700 400 100 100))))
      (esketch--select ed id)
      (esketch-gesture-test--press-handle ed 50 10 'S-down-mouse-1 'S-drag-mouse-1)
      (should (= (esketch-gesture-test--prop ed id "width") 150))
      (should (= (esketch-gesture-test--prop ed id "height") 150))
      (esketch-gesture-test--press-handle ed -1000 -1000 'S-down-mouse-1 'S-drag-mouse-1)
      (should (= (esketch-gesture-test--prop ed id "width") 10))
      (should (= (esketch-gesture-test--prop ed id "height") 10)))
    (esketch-gesture-test--consistent ed)))

(ert-deftest esketch-gesture-test-resize-text ()
  (esketch-gesture-test--with-editor ed
    (esketch-add-text "Hi" '(900 500))
    (let* ((id (esketch-ed-selected ed))
           (h0 (esketch-gesture-test--prop ed id "height")))
      (should (esketch--handle ed))
      (esketch-gesture-test--press-handle ed 0 h0 'S-down-mouse-1 'S-drag-mouse-1)
      (should (= (esketch-gesture-test--prop ed id "fontSize") 40))
      (should (esketch-gesture-test--near (esketch-gesture-test--prop ed id "height") (* 2 h0)))
      (should (= (esketch-gesture-test--prop ed id "width")
                 (car (esketch--text-size 5 40 "Hi"))))
      (esketch-gesture-test--press-handle ed -1000 -1000)
      (should (>= (esketch-gesture-test--prop ed id "width") 10))
      (should (>= (esketch-gesture-test--prop ed id "height") 10)))))

;;;; Drawing with the mouse

(ert-deftest esketch-gesture-test-draw-arrow-between-shapes ()
  (esketch-gesture-test--with-editor ed
    (let ((before (esketch-gesture-test--ids ed)))
      (esketch-gesture-test--run ed (list ?a))
      (esketch-gesture-test--gesture ed 'down-mouse-1 'drag-mouse-1 580 140 200 360)
      (let* ((new (esketch-gesture-test--new-ids ed before))
             (a (esketch-gesture-test--el ed (car new))))
        (should (= (length new) 1))
        (should (equal (esketch-get a "type") "arrow"))
        (should (equal (esketch--bound-to a 'start) "ell1"))
        (should (equal (esketch--bound-to a 'end) "dia1"))
        (should (equal (esketch-ed-selected ed) (car new)))
        (let ((s (esketch-gesture-test--arrow-end ed (car new) 'start))
              (e (esketch-gesture-test--arrow-end ed (car new) 'end)))
          (should (esketch-gesture-test--gap-ok s '(580.0 . 140.0) 80 50 "ellipse"))
          (should (esketch-gesture-test--gap-ok e '(200.0 . 360.0) 80 60 "diamond")))
        (esketch-gesture-test--consistent ed)))))

(ert-deftest esketch-gesture-test-draw-arrow-free-ends ()
  (esketch-gesture-test--with-editor ed
    (let ((before (esketch-gesture-test--ids ed)))
      (esketch-arrow-tool)
      (esketch-gesture-test--gesture ed 'down-mouse-1 'drag-mouse-1 900 500 1000 560)
      (let* ((id (car (esketch-gesture-test--new-ids ed before)))
             (a (esketch-gesture-test--el ed id)))
        (should (null (esketch--bound-to a 'start)))
        (should (null (esketch--bound-to a 'end)))
        (should (equal (esketch-gesture-test--arrow-end ed id 'start) '(900.0 . 500.0)))
        (should (equal (esketch-gesture-test--arrow-end ed id 'end) '(1000.0 . 560.0))))
      ;; from a shape into the open: bound at the start only
      (setq before (esketch-gesture-test--ids ed))
      (esketch-arrow-tool)
      (esketch-gesture-test--gesture ed 'down-mouse-1 'drag-mouse-1 580 140 800 600)
      (let* ((id (car (esketch-gesture-test--new-ids ed before)))
             (a (esketch-gesture-test--el ed id)))
        (should (equal (esketch--bound-to a 'start) "ell1"))
        (should (null (esketch--bound-to a 'end)))
        (should (equal (esketch-gesture-test--arrow-end ed id 'end) '(800.0 . 600.0)))
        (should (esketch-gesture-test--gap-ok (esketch-gesture-test--arrow-end ed id 'start)
                                              '(580.0 . 140.0) 80 50 "ellipse")))
      (esketch-gesture-test--consistent ed))))

(ert-deftest esketch-gesture-test-arrow-tool-is-one-shot-and-undoable ()
  (esketch-gesture-test--with-editor ed
    (let ((n (length (esketch-elements (esketch-ed-doc ed)))))
      (esketch-arrow-tool)
      (esketch-gesture-test--gesture ed 'down-mouse-1 'drag-mouse-1 900 500 1000 560)
      (should (null (esketch-ed-tool ed)))
      (should (= (length (esketch-elements (esketch-ed-doc ed))) (1+ n)))
      (esketch-undo)
      (should (= (length (esketch-elements (esketch-ed-doc ed))) n))
      (esketch-redo)
      (esketch-gesture-test--drag ed 120 110 130 110)
      (should (= (length (esketch-elements (esketch-ed-doc ed))) (1+ n)))
      (should (= (esketch-gesture-test--prop ed "rect1" "x") 110)))))

(ert-deftest esketch-gesture-test-text-tool-places-text ()
  (esketch-gesture-test--with-editor ed
    (let ((before (esketch-gesture-test--ids ed)) (asked nil))
      (esketch-gesture-test--run ed (list ?t))
      (should (eq (esketch-ed-tool ed) 'text))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (setq asked t) "Hello")))
        (esketch-gesture-test--down ed 'down-mouse-1 900 500))
      (should asked)
      (should (null (esketch-ed-tool ed)))
      (let* ((id (car (esketch-gesture-test--new-ids ed before)))
             (tx (esketch-gesture-test--el ed id)))
        (should (equal (esketch-get tx "type") "text"))
        (should (equal (esketch-get tx "text") "Hello"))
        (should (= (esketch-get tx "x") 900))
        (should (= (esketch-get tx "y") 500))
        (should (equal (esketch-ed-selected ed) id))
        (should (= (esketch-get tx "width") (car (esketch--text-size 5 20 "Hello")))))
      (esketch-undo)
      (should (equal (esketch-gesture-test--ids ed) before))
      ;; empty text adds nothing
      (esketch-add-text "" '(10 10))
      (should (equal (esketch-gesture-test--ids ed) before)))))

;;;; Keyboard

(ert-deftest esketch-gesture-test-tab-cycles ()
  (esketch-gesture-test--with-editor ed
    (let ((order '("rect1" "ell1" "arrow1" "dia1" "line1" "free1" "arrow2")))
      (should (eq (lookup-key esketch-edit-map (kbd "TAB")) #'esketch-select-next))
      (should (eq (lookup-key esketch-edit-map (kbd "<backtab>")) #'esketch-select-previous))
      (dolist (id order)
        (esketch-select-next)
        (should (equal (esketch-ed-selected ed) id)))
      (esketch-select-next)
      (should (equal (esketch-ed-selected ed) "rect1"))
      (esketch-select-previous)
      (should (equal (esketch-ed-selected ed) "arrow2"))
      (esketch-select-previous)
      (should (equal (esketch-ed-selected ed) "free1"))
      (esketch--select ed nil)
      (esketch-select-previous)
      (should (equal (esketch-ed-selected ed) "arrow2"))
      (should (equal (esketch-ed-selection ed) '("arrow2")))
      ;; a deleted element is skipped
      (esketch--select ed "ell1")
      (esketch-select-next)
      (esketch-delete-selected)
      (esketch--select ed "ell1")
      (esketch-select-next)
      (should (equal (esketch-ed-selected ed) "dia1")))))

(ert-deftest esketch-gesture-test-tab-then-connect ()
  (esketch-gesture-test--with-editor ed
    (esketch-select-next)
    (esketch-select-next)
    (should (equal (esketch-ed-previous ed) "rect1"))
    (esketch-connect)
    (let ((a (esketch-gesture-test--el ed (esketch-ed-selected ed))))
      (should (equal (esketch--bound-to a 'start) "rect1"))
      (should (equal (esketch--bound-to a 'end) "ell1")))
    (esketch-gesture-test--consistent ed)))

;;;; Menus

(defun esketch-gesture-test--items (spec)
  "All (PANE-TITLE LABEL . VALUE) of the menu SPEC."
  (cl-loop for pane in (cdr spec)
           append (mapcar (lambda (itm) (cons (car pane) itm)) (cdr pane))))

(ert-deftest esketch-gesture-test-menu-shape ()
  (esketch-gesture-test--with-editor ed
    (esketch--select ed "ell1")
    (let* ((spec (esketch-menu-spec ed "ell1"))
           (items (esketch-gesture-test--items spec))
           (expect '(("strokeColor" "#1e1e1e" "#e03131" "#2f9e44" "#1971c2" "#f08c00")
                     ("backgroundColor" "transparent" "#ffc9c9" "#b2f2bb" "#a5d8ff" "#ffec99")
                     ("strokeWidth" 1 2 4)
                     ("roughness" 0 1 2))))
      (should (stringp (car spec)))
      (dolist (e expect)
        (should (equal (cl-loop for itm in items
                                when (equal (caddr itm) (car e)) collect (cdddr itm))
                       (cdr e))))
      ;; a shape without a label has no font size entry
      (should-not (cl-find "fontSize" items :key #'caddr :test #'equal)))))

(ert-deftest esketch-gesture-test-menu-sets-every-property ()
  (esketch-gesture-test--with-editor ed
    (esketch--select ed "ell1")
    (let ((items (esketch-gesture-test--items (esketch-menu-spec ed "ell1"))))
      (should (= (length items) 16))
      (dolist (itm items)
        (let* ((choice (cddr itm))
               (version (esketch-gesture-test--prop ed "ell1" "version"))
               (steps (length (esketch-ed-undo ed)))
               (old (esketch-gesture-test--prop ed "ell1" (car choice))))
          (esketch-menu-apply ed choice)
          (should (equal (esketch-gesture-test--prop ed "ell1" (car choice)) (cdr choice)))
          (should (= (esketch-gesture-test--prop ed "ell1" "version") (1+ version)))
          (should (= (length (esketch-ed-undo ed)) (1+ steps)))
          (esketch-undo)
          (should (equal (esketch-gesture-test--prop ed "ell1" (car choice)) old))
          (esketch-redo))))
    (esketch-gesture-test--consistent ed)))

(ert-deftest esketch-gesture-test-menu-font-size ()
  (esketch-gesture-test--with-editor ed
    ;; the label of a shape
    (esketch--select ed "rect1")
    (let ((items (cl-remove-if-not (lambda (itm) (equal (caddr itm) "fontSize"))
                                   (esketch-gesture-test--items (esketch-menu-spec ed "rect1")))))
      (should (equal (mapcar #'cdddr items) '(16 20 28 36)))
      (dolist (itm items)
        (let ((version (esketch-gesture-test--prop ed "text1" "version")))
          (esketch-menu-apply ed (cddr itm))
          (let ((tx (esketch-gesture-test--el ed "text1")))
            (should (= (esketch-get tx "fontSize") (cdddr itm)))
            (should (= (esketch-get tx "version") (1+ version)))
            (should (= (esketch-get tx "width")
                       (car (esketch--text-size 5 (cdddr itm) "Sensor"))))
            (should (esketch-gesture-test--near
                     (+ (esketch-get tx "x") (/ (esketch-get tx "width") 2.0)) 200))))))
    ;; a text
    (esketch-add-text "Hi" '(900 500))
    (let ((id (esketch-ed-selected ed)))
      (should (cl-find "fontSize" (esketch-gesture-test--items (esketch-menu-spec ed id))
                       :key #'caddr :test #'equal))
      (esketch-menu-apply ed '("fontSize" . 28))
      (should (= (esketch-gesture-test--prop ed id "fontSize") 28))
      (should (= (esketch-gesture-test--prop ed id "width") (car (esketch--text-size 5 28 "Hi")))))
    (esketch-gesture-test--consistent ed)))

(ert-deftest esketch-gesture-test-menu-applies-to-selection ()
  (esketch-gesture-test--with-editor ed
    (esketch--set-selection ed '("rect1" "ell1" "dia1"))
    (esketch-menu-apply ed '("strokeColor" . "#e03131"))
    (dolist (id '("rect1" "ell1" "dia1"))
      (should (equal (esketch-gesture-test--prop ed id "strokeColor") "#e03131")))
    (should (equal (esketch-gesture-test--prop ed "arrow1" "strokeColor") "#1e1e1e"))
    (esketch-undo)
    (dolist (id '("rect1" "ell1" "dia1"))
      (should (equal (esketch-gesture-test--prop ed id "strokeColor") "#1e1e1e")))))

(ert-deftest esketch-gesture-test-menu-on-shape ()
  "mouse-3 on a shape selects it, pops up its menu and applies the choice."
  (esketch-gesture-test--with-editor ed
    (let ((popped nil))
      (should (eq (lookup-key esketch-edit-map [down-mouse-3]) #'esketch-context-menu))
      (cl-letf (((symbol-function 'x-popup-menu)
                 (lambda (_event spec)
                   (setq popped spec)
                   '("backgroundColor" . "#a5d8ff"))))
        (esketch-gesture-test--down ed 'down-mouse-3 580 140))
      (should (equal (car popped) "Style"))
      (should (equal (esketch-ed-selection ed) '("ell1")))
      (should (equal (esketch-gesture-test--prop ed "ell1" "backgroundColor") "#a5d8ff"))
      (cl-letf (((symbol-function 'x-popup-menu) (lambda (&rest _) nil)))
        (let ((steps (length (esketch-ed-undo ed))))
          (esketch-gesture-test--down ed 'down-mouse-3 120 110)
          (should (= (length (esketch-ed-undo ed)) steps)))))))

(ert-deftest esketch-gesture-test-menu-on-canvas ()
  "mouse-3 on empty canvas offers to add a shape or text at that point."
  (esketch-gesture-test--with-editor ed
    (let* ((spec (esketch-menu-spec ed nil))
           (items (esketch-gesture-test--items spec)))
      (should (equal (mapcar #'cdddr items) '("rectangle" "ellipse" "diamond" "text")))
      (dolist (type '("rectangle" "ellipse" "diamond" "text"))
        (let ((before (esketch-gesture-test--ids ed))
              (x (+ 900 (* 250 (cl-position type '("rectangle" "ellipse" "diamond" "text") :test #'equal)))))
          (cl-letf (((symbol-function 'x-popup-menu)
                     (lambda (_e spec2)
                       (should (equal spec2 spec))
                       (cons "add" type)))
                    ((symbol-function 'read-string) (lambda (&rest _) "Note")))
            (esketch-gesture-test--down ed 'down-mouse-3 x 500))
          (let* ((new (esketch-gesture-test--new-ids ed before))
                 (el (esketch-gesture-test--el ed (car new))))
            (should (= (length new) 1))
            (should (equal (esketch-get el "type") type))
            (if (equal type "text")
                (should (and (= (esketch-get el "x") x) (= (esketch-get el "y") 500)))
              (should (esketch-gesture-test--near
                       (+ (esketch-get el "x") (/ (esketch-get el "width") 2.0)) x))))))
      (esketch-menu-apply ed '("add" . "text") "Direct")
      (should (equal (esketch-gesture-test--prop ed (esketch-ed-selected ed) "text") "Direct")))))

;;;; Gestures

(ert-deftest esketch-gesture-test-shift-drag-constrains-move ()
  (esketch-gesture-test--with-editor ed
    (esketch--select ed "dia1")
    (esketch-gesture-test--gesture ed 'S-down-mouse-1 'S-drag-mouse-1 200 360 230 365)
    (should (= (esketch-gesture-test--prop ed "dia1" "x") 150))
    (should (= (esketch-gesture-test--prop ed "dia1" "y") 300))
    (esketch-gesture-test--gesture ed 'S-down-mouse-1 'S-drag-mouse-1 255 400 260 440)
    (should (= (esketch-gesture-test--prop ed "dia1" "x") 150))
    (should (= (esketch-gesture-test--prop ed "dia1" "y") 340))
    (esketch-gesture-test--gesture ed 'S-down-mouse-1 'S-drag-mouse-1 255 425 285 445)
    (should (= (esketch-gesture-test--prop ed "dia1" "x") 175))
    (should (= (esketch-gesture-test--prop ed "dia1" "y") 365))
    (esketch-gesture-test--gesture ed 'S-down-mouse-1 'S-drag-mouse-1 255 425 225 445)
    (should (= (esketch-gesture-test--prop ed "dia1" "x") 150))
    (should (= (esketch-gesture-test--prop ed "dia1" "y") 390))
    (should (equal (esketch--constrain 30 -30) '(30.0 -30.0)))
    (should (equal (esketch--constrain -30 0) '(-30.0 0.0)))))

(ert-deftest esketch-gesture-test-meta-drag-duplicates ()
  (esketch-gesture-test--with-editor ed
    (esketch--set-selection ed '("rect1" "ell1" "arrow1"))
    (let ((before (esketch-gesture-test--ids ed))
          (seeds (mapcar (lambda (e) (esketch-get e "seed"))
                         (esketch-elements (esketch-ed-doc ed)))))
      (esketch-gesture-test--gesture ed 'M-down-mouse-1 'M-drag-mouse-1 120 110 150 150)
      (let ((new (esketch-gesture-test--new-ids ed before)))
        (should (= (length new) 4))
        (should (= (length (esketch-ed-selection ed)) 3))
        (dolist (id new)
          (should-not (member (esketch-gesture-test--prop ed id "seed") seeds)))
        ;; originals are where they were
        (should (= (esketch-gesture-test--prop ed "rect1" "x") 100))
        (should (= (esketch-gesture-test--prop ed "ell1" "x") 500))
        (should (= (esketch-gesture-test--prop ed "arrow1" "x") 305))
        (let* ((sel (esketch-ed-selection ed))
               (rect (cl-find "rectangle" sel :test #'equal
                              :key (lambda (id) (esketch-gesture-test--prop ed id "type"))))
               (ell (cl-find "ellipse" sel :test #'equal
                             :key (lambda (id) (esketch-gesture-test--prop ed id "type"))))
               (arr (cl-find "arrow" sel :test #'equal
                             :key (lambda (id) (esketch-gesture-test--prop ed id "type")))))
          (should (= (esketch-gesture-test--prop ed rect "x") 130))
          (should (= (esketch-gesture-test--prop ed rect "y") 140))
          (should (= (esketch-gesture-test--prop ed ell "x") 530))
          (should (= (esketch-gesture-test--prop ed arr "x") 335))
          (should (= (esketch-gesture-test--prop ed arr "width") 190))
          (should (equal (esketch--bound-to (esketch-gesture-test--el ed arr) 'start) rect))
          (should (equal (esketch--bound-to (esketch-gesture-test--el ed arr) 'end) ell))
          (let ((label (esketch--label (esketch-ed-doc ed) (esketch-gesture-test--el ed rect))))
            (should label)
            (should (= (esketch-get label "x") 180.5))
            (should (equal (esketch-get label "text") "Sensor"))))
        (esketch-gesture-test--consistent ed))
      (esketch-undo)
      (should (equal (esketch-gesture-test--ids ed) before)))))

(ert-deftest esketch-gesture-test-meta-drag-drops-outside-bindings ()
  (esketch-gesture-test--with-editor ed
    (esketch--set-selection ed '("rect1" "arrow1"))
    (let ((before (esketch-gesture-test--ids ed)))
      (esketch-gesture-test--gesture ed 'M-down-mouse-1 'M-drag-mouse-1 120 110 120 210)
      (let* ((new (esketch-gesture-test--new-ids ed before))
             (arr (cl-find "arrow" new :test #'equal
                           :key (lambda (id) (esketch-gesture-test--prop ed id "type"))))
             (rect (cl-find "rectangle" new :test #'equal
                            :key (lambda (id) (esketch-gesture-test--prop ed id "type")))))
        (should (equal (esketch--bound-to (esketch-gesture-test--el ed arr) 'start) rect))
        (should (null (esketch--bound-to (esketch-gesture-test--el ed arr) 'end)))
        (should (= (esketch-gesture-test--prop ed arr "x") 305))
        (should (= (esketch-gesture-test--prop ed arr "y") 240))
        ;; the shape that was not copied is untouched
        (should (equal (mapcar (lambda (b) (esketch-get b "id"))
                               (esketch-get (esketch-gesture-test--el ed "ell1") "boundElements"))
                       '("arrow1")))
        (should (equal (esketch--bound-to (esketch-gesture-test--el ed "arrow1") 'end) "ell1"))
        (esketch-gesture-test--consistent ed)))))

(ert-deftest esketch-gesture-test-middle-drag-pans ()
  (esketch-gesture-test--with-editor ed
    (let* ((v (copy-sequence (esketch-ed-view ed)))
           (a (esketch-editor-test--posn ed 300 200))
           (b (esketch-editor-test--posn ed 350 260))
           (pa (esketch--posn-point ed a))
           (steps (length (esketch-ed-undo ed))))
      (should (eq (lookup-key esketch-edit-map [drag-mouse-2]) #'esketch-mouse-pan))
      (esketch-gesture-test--run ed (list 'drag-mouse-2 a b))
      (should (esketch-gesture-test--near (nth 0 (esketch-ed-view ed)) (- (nth 0 v) 50) 1.01))
      (should (esketch-gesture-test--near (nth 1 (esketch-ed-view ed)) (- (nth 1 v) 60) 1.01))
      (should (= (nth 2 (esketch-ed-view ed)) (nth 2 v)))
      ;; the point that was grabbed is now under the pixel it was released on
      (let ((p (esketch--posn-point ed b)))
        (should (esketch-gesture-test--near (car p) (car pa) 1e-6))
        (should (esketch-gesture-test--near (cadr p) (cadr pa) 1e-6)))
      (should (= (length (esketch-ed-undo ed)) steps))
      (esketch-nudge-right)
      (should (esketch-gesture-test--near (nth 0 (esketch-ed-view ed)) (- (nth 0 v) 50) 1.01))
      (esketch-view-reset)
      (should (esketch-gesture-test--near (nth 0 (esketch-ed-view ed)) (nth 0 v) 1e-6)))))

(ert-deftest esketch-gesture-test-ctrl-wheel-zooms ()
  (esketch-gesture-test--with-editor ed
    (let* ((pos (esketch-editor-test--posn ed 300 200))
           (p (esketch--posn-point ed pos))
           (size (* (nth 2 (esketch-ed-view ed)) (esketch-ed-scale ed))))
      (dolist (k '([C-wheel-up] [C-mouse-4]))
        (should (eq (lookup-key esketch-edit-map k) #'esketch-zoom-in)))
      (dolist (k '([C-wheel-down] [C-mouse-5]))
        (should (eq (lookup-key esketch-edit-map k) #'esketch-zoom-out)))
      (esketch-gesture-test--run ed (list 'C-wheel-up pos))
      (should (esketch-gesture-test--near (esketch-ed-scale ed) 1.25))
      (let ((q (esketch--posn-point ed pos)))
        (should (esketch-gesture-test--near (car q) (car p)))
        (should (esketch-gesture-test--near (cadr q) (cadr p))))
      (esketch-gesture-test--run ed (list 'C-mouse-4 pos))
      (should (esketch-gesture-test--near (esketch-ed-scale ed) 1.5625))
      (esketch-gesture-test--run ed (list 'C-wheel-down pos))
      (esketch-gesture-test--run ed (list 'C-mouse-5 pos))
      (should (esketch-gesture-test--near (esketch-ed-scale ed) 1.0))
      (let ((q (esketch--posn-point ed pos)))
        (should (esketch-gesture-test--near (car q) (car p)))
        (should (esketch-gesture-test--near (cadr q) (cadr p))))
      ;; the image keeps its size on screen
      (should (esketch-gesture-test--near (* (nth 2 (esketch-ed-view ed)) (esketch-ed-scale ed))
                                          size 1e-6))
      (dotimes (_ 20) (esketch-gesture-test--run ed (list 'C-wheel-up pos)))
      (should (<= (esketch-ed-scale ed) 4))
      (should (> (esketch-ed-scale ed) 3.5))
      (dotimes (_ 40) (esketch-gesture-test--run ed (list 'C-wheel-down pos)))
      (should (>= (esketch-ed-scale ed) 0.25))
      (should (< (esketch-ed-scale ed) 0.32)))))

(ert-deftest esketch-gesture-test-zoomed-view-hit-testing ()
  "Clicks still land on the right element after zooming and panning."
  (esketch-gesture-test--with-editor ed
    (let ((pos (esketch-editor-test--posn ed 300 200)))
      (esketch-gesture-test--run ed (list 'C-wheel-up pos))
      (esketch-gesture-test--run ed (list 'drag-mouse-2 pos
                                          (esketch-editor-test--posn ed 320 210)))
      (esketch-gesture-test--down ed 'down-mouse-1 580 140)
      (should (equal (esketch-ed-selected ed) "ell1")))))

;;;; Gesture table in README.org

(defconst esketch-gesture-test--rows
  '(("C-mouse-1" . esketch-gesture-test-ctrl-click-toggles)
    ("mouse-1" . esketch-gesture-test-click-selects-one)
    ("drag" . esketch-gesture-test-drag-moves-every-selected)
    ("S-drag" . esketch-gesture-test-shift-drag-constrains-move)
    ("M-drag" . esketch-gesture-test-meta-drag-duplicates)
    ("drag handle" . esketch-gesture-test-resize-by-handle)
    ("S-drag handle" . esketch-gesture-test-resize-keeps-ratio)
    ("a, drag" . esketch-gesture-test-draw-arrow-between-shapes)
    ("t, click" . esketch-gesture-test-text-tool-places-text)
    ("mouse-3 on element" . esketch-gesture-test-menu-on-shape)
    ("mouse-3 on canvas" . esketch-gesture-test-menu-on-canvas)
    ("mouse-2 drag" . esketch-gesture-test-middle-drag-pans)
    ("C-wheel" . esketch-gesture-test-ctrl-wheel-zooms))
  "README gesture table row -> the ERT test that runs it.")

(defun esketch-gesture-test--table (text)
  "Rows ((GESTURE . TEST-CELL) ...) of the gesture table in the Org TEXT."
  (let ((rows nil) (in nil))
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match-p "\\`| *Gesture " line) (setq in t))
       ((and in (string-match-p "\\`|-" line)))
       ((and in (string-prefix-p "|" line))
        (let ((cells (mapcar (lambda (c) (replace-regexp-in-string "=" "" (string-trim c)))
                             (cdr (split-string line "|")))))
          (push (cons (nth 0 cells) (or (nth 2 cells) "")) rows)))
       (t (setq in nil))))
    (nreverse rows)))

(defun esketch-gesture-test--table-problems (rows)
  "Problems with ROWS: a row without a test, or whose test is not the mapped one."
  (let ((problems nil))
    (dolist (r rows)
      (let ((want (cdr (assoc (car r) esketch-gesture-test--rows))))
        (cond ((string-empty-p (cdr r)) (push (format "%s: no test named" (car r)) problems))
              ((null want) (push (format "%s: not in the test file's mapping" (car r)) problems))
              ((not (equal (cdr r) (symbol-name want)))
               (push (format "%s: lists %s, mapping says %s" (car r) (cdr r) want) problems))
              ((not (ert-test-boundp want))
               (push (format "%s: no test %s" (car r) want) problems)))))
    (dolist (m esketch-gesture-test--rows)
      (unless (assoc (car m) rows) (push (format "%s: missing from README" (car m)) problems)))
    (nreverse problems)))

(ert-deftest esketch-gesture-test-readme-table-has-a-test-per-row ()
  (let* ((text (with-temp-buffer (insert-file-contents esketch-gesture-test--readme)
                                 (buffer-string)))
         (rows (esketch-gesture-test--table text)))
    (should (>= (length rows) (length esketch-gesture-test--rows)))
    (should (equal (esketch-gesture-test--table-problems rows) nil))
    ;; the checker catches what it is for
    (let* ((planted (esketch-gesture-test--table
                     (concat "| Gesture | Does | Test |\n|---+---+---|\n"
                             "| mouse-1 | select | =esketch-gesture-test-click-selects-one= |\n"
                             "| drag | move |   |\n"
                             "| S-drag | constrain | =esketch-gesture-test-no-such-test= |\n"
                             "| spin | new | =esketch-gesture-test-ctrl-wheel-zooms= |\n")))
           (problems (esketch-gesture-test--table-problems planted)))
      (should (= (length planted) 4))
      (should (member "drag: no test named" problems))
      (should (cl-find "S-drag: lists" problems :test #'string-prefix-p))
      (should (member "spin: not in the test file's mapping" problems))
      (should (member "C-wheel: missing from README" problems))
      (should-not (cl-find "mouse-1: " problems :test #'string-prefix-p)))))

(provide 'esketch-gesture-test)
;;; esketch-gesture-test.el ends here
