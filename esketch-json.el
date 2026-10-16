;;; esketch-json.el --- Excalidraw-exact JSON for esketch  -*- lexical-binding: t; -*-

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

;; Reads JSON and writes it back exactly as JavaScript's
;; JSON.stringify(value, null, 2) would, which is how Excalidraw saves.  An
;; unmodified drawing therefore saves byte for byte, and an edited one diffs
;; only where it changed.
;;
;; Representation: an object is (:obj (KEY . VALUE) ...) with string keys in
;; file order, an array is a vector, null is :null, false is :false, true is
;; t.  Numbers parse as JavaScript would see them: integers beyond 2^53
;; become floats.

;;; Code:

(require 'cl-lib)

;;;; Objects

(defun esketch-obj-p (v)
  (and (consp v) (eq (car v) :obj)))

(defun esketch-get (obj key)
  "Value of KEY in OBJ, or nil when absent."
  (cdr (assoc key (cdr obj))))

(defun esketch-has (obj key)
  (and (assoc key (cdr obj)) t))

(defun esketch-del (obj key)
  "Remove KEY from OBJ in place."
  (setcdr obj (cl-remove key (cdr obj) :key #'car :test #'equal)))

(defun esketch-put (obj key value)
  "Set KEY to VALUE in OBJ in place; a new key goes last.  Return VALUE."
  (let ((cell (assoc key (cdr obj))))
    (if cell
        (setcdr cell value)
      (nconc obj (list (cons key value))))
    value))

;;;; Reader

(defun esketch-json--fail (what)
  (error "esketch-json: %s at offset %d" what (1- (point))))

(defsubst esketch-json--ws ()
  (skip-chars-forward " \t\n\r"))

(defconst esketch-json--number-re
  "-?\\(?:0\\|[1-9][0-9]*\\)\\(\\.[0-9]+\\)?\\([eE][-+]?[0-9]+\\)?")

(defun esketch-json--number ()
  (unless (looking-at esketch-json--number-re)
    (esketch-json--fail "bad value"))
  (goto-char (match-end 0))
  (let ((s (match-string 0)))
    (if (or (match-beginning 1) (match-beginning 2))
        (string-to-number (downcase s))
      (let ((n (string-to-number s)))
        ;; JavaScript holds every number as a double.
        (if (> (abs n) 9007199254740992) (float n) n)))))

(defun esketch-json--hex4 ()
  (unless (looking-at "[0-9a-fA-F]\\{4\\}")
    (esketch-json--fail "bad \\u escape"))
  (goto-char (match-end 0))
  (string-to-number (match-string 0) 16))

(defun esketch-json--string ()
  (forward-char 1)
  (let ((start (point)))
    (skip-chars-forward "^\"\\\\")
    (if (eq (char-after) ?\")
        (prog1 (buffer-substring-no-properties start (point))
          (forward-char 1))
      (let ((parts (list (buffer-substring-no-properties start (point)))))
        (while (not (eq (char-after) ?\"))
          (when (eobp) (esketch-json--fail "unterminated string"))
          (forward-char 1)
          (let ((c (char-after)))
            (forward-char 1)
            (push (pcase c
                    (?\" "\"") (?\\ "\\") (?/ "/") (?b "\b") (?f "\f")
                    (?n "\n") (?r "\r") (?t "\t")
                    (?u (let ((u (esketch-json--hex4)))
                          (when (and (<= #xd800 u #xdbff)
                                     (looking-at "\\\\u\\([dD][c-fC-F][0-9a-fA-F]\\{2\\}\\)"))
                            (goto-char (match-end 0))
                            (setq u (+ #x10000 (ash (- u #xd800) 10)
                                       (- (string-to-number (match-string 1) 16)
                                          #xdc00))))
                          (string u)))
                    (_ (esketch-json--fail "bad escape")))
                  parts))
          (let ((s (point)))
            (skip-chars-forward "^\"\\\\")
            (push (buffer-substring-no-properties s (point)) parts)))
        (forward-char 1)
        (apply #'concat (nreverse parts))))))

(defun esketch-json--value ()
  (esketch-json--ws)
  (pcase (char-after)
    (?{ (esketch-json--object))
    (?\[ (esketch-json--array))
    (?\" (esketch-json--string))
    (?t (esketch-json--literal "true" t))
    (?f (esketch-json--literal "false" :false))
    (?n (esketch-json--literal "null" :null))
    ('nil (esketch-json--fail "unexpected end"))
    (_ (esketch-json--number))))

(defun esketch-json--literal (word value)
  (unless (looking-at (regexp-quote word))
    (esketch-json--fail "bad literal"))
  (goto-char (match-end 0))
  value)

(defun esketch-json--expect (char)
  (esketch-json--ws)
  (unless (eq (char-after) char)
    (esketch-json--fail (format "expected `%c'" char)))
  (forward-char 1))

(defun esketch-json--object ()
  (forward-char 1)
  (let ((obj (list :obj)))
    (esketch-json--ws)
    (if (eq (char-after) ?})
        (forward-char 1)
      (let ((more t))
        (while more
          (esketch-json--ws)
          (unless (eq (char-after) ?\") (esketch-json--fail "expected key"))
          (let ((key (esketch-json--string)))
            (esketch-json--expect ?:)
            ;; A repeated key keeps its first position and its last value,
            ;; as in JavaScript.
            (esketch-put obj key (esketch-json--value)))
          (esketch-json--ws)
          (pcase (char-after)
            (?, (forward-char 1))
            (?} (forward-char 1) (setq more nil))
            (_ (esketch-json--fail "expected `,' or `}'"))))))
    obj))

(defun esketch-json--array ()
  (forward-char 1)
  (let ((items nil))
    (esketch-json--ws)
    (if (eq (char-after) ?\])
        (forward-char 1)
      (let ((more t))
        (while more
          (push (esketch-json--value) items)
          (esketch-json--ws)
          (pcase (char-after)
            (?, (forward-char 1))
            (?\] (forward-char 1) (setq more nil))
            (_ (esketch-json--fail "expected `,' or `]'"))))))
    (vconcat (nreverse items))))

(defun esketch-json-read ()
  "Read one JSON value from point to the end of the buffer."
  (let ((v (esketch-json--value)))
    (esketch-json--ws)
    (unless (eobp) (esketch-json--fail "trailing data"))
    v))

(defun esketch-json-read-from-string (string)
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (esketch-json-read)))

;;;; Writer

(defun esketch-json--float (f)
  "F as JavaScript's Number::toString writes it."
  (if (or (= f 0) (/= f f) (= f 1.0e+INF) (= f -1.0e+INF))
      (if (= f 0) "0" "null")
    (let ((float-output-format nil)
          (s (number-to-string f)))
      (unless (string-match
               "\\`\\(-?\\)\\([0-9]+\\)\\(?:\\.\\([0-9]+\\)\\)?\\(?:e\\([-+]?[0-9]+\\)\\)?\\'"
               s)
        (error "esketch-json: cannot format %s" s))
      (let* ((sign (match-string 1 s))
             (int (match-string 2 s))
             (digits (concat int (or (match-string 3 s) "")))
             (n (+ (length int) (string-to-number (or (match-string 4 s) "0")))))
        ;; value = 0.DIGITS x 10^n, with DIGITS stripped to its significant run
        (while (eq (aref digits 0) ?0)
          (setq digits (substring digits 1) n (1- n)))
        (setq digits (replace-regexp-in-string "0+\\'" "" digits))
        (let ((k (length digits)))
          (concat
           sign
           (cond
            ((<= k n 21) (concat digits (make-string (- n k) ?0)))
            ((< 0 n 22) (concat (substring digits 0 n) "." (substring digits n)))
            ((< -6 n 1) (concat "0." (make-string (- n) ?0) digits))
            (t (let ((e (1- n)))
                 (concat (substring digits 0 1)
                         (if (> k 1) (concat "." (substring digits 1)) "")
                         "e" (if (< e 0) "-" "+")
                         (number-to-string (abs e))))))))))))

(defun esketch-json-number-string (n)
  "N as JavaScript prints it, e.g. in a template string."
  (if (floatp n) (esketch-json--float n) (number-to-string n)))

(defun esketch-json--string-out (s)
  (insert ?\")
  (if (not (string-match-p "[\"\\\\\000-\037]" s))
      (insert s)
    (dotimes (i (length s))
      (let ((c (aref s i)))
        (insert (pcase c
                  (?\" "\\\"") (?\\ "\\\\") (?\b "\\b") (?\f "\\f")
                  (?\n "\\n") (?\r "\\r") (?\t "\\t")
                  (_ (if (< c 32) (format "\\u%04x" c) (string c))))))))
  (insert ?\"))

(defun esketch-json--write (v indent)
  (cond
   ((eq v :null) (insert "null"))
   ((eq v :false) (insert "false"))
   ((eq v t) (insert "true"))
   ((integerp v) (insert (number-to-string v)))
   ((floatp v) (insert (esketch-json--float v)))
   ((stringp v) (esketch-json--string-out v))
   ((vectorp v)
    (if (= (length v) 0)
        (insert "[]")
      (let ((pad (make-string (+ indent 2) ?\s)))
        (insert "[\n")
        (dotimes (i (length v))
          (unless (= i 0) (insert ",\n"))
          (insert pad)
          (esketch-json--write (aref v i) (+ indent 2)))
        (insert "\n" (make-string indent ?\s) "]"))))
   ((esketch-obj-p v)
    (if (null (cdr v))
        (insert "{}")
      (let ((pad (make-string (+ indent 2) ?\s))
            (first t))
        (insert "{\n")
        (dolist (cell (cdr v))
          (unless first (insert ",\n"))
          (setq first nil)
          (insert pad)
          (esketch-json--string-out (car cell))
          (insert ": ")
          (esketch-json--write (cdr cell) (+ indent 2)))
        (insert "\n" (make-string indent ?\s) "}"))))
   (t (error "esketch-json: cannot write %S" v))))

(defun esketch-json-write-to-string (value)
  (with-temp-buffer
    (esketch-json--write value 0)
    (buffer-string)))

;;;; Files

(cl-defstruct (esketch-file (:constructor esketch-file--make))
  doc
  ;; whether the source ended with a newline, which Excalidraw never writes
  ;; but editors and git tools often add
  newline)

(defun esketch-read-file (file)
  "Read the drawing FILE into an `esketch-file'."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (goto-char (point-min))
    (esketch-file--make :doc (esketch-json-read)
                        :newline (eq (char-before (point-max)) ?\n))))

(defun esketch-write-file (efile file)
  "Write EFILE to FILE as Excalidraw would."
  (with-temp-buffer
    (esketch-json--write (esketch-file-doc efile) 0)
    (when (esketch-file-newline efile) (insert "\n"))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region nil nil file nil 'silent))))

(provide 'esketch-json)
;;; esketch-json.el ends here
