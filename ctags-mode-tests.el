;;; ctags-mode-tests.el --- Tests for ctags-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; ERT tests for ctags-mode.  The pure parsing and sorting helpers get
;; direct unit tests; the rendering, visiting, refresh and bookmark code
;; runs against a real buffer.  The directory-backed tests drive the
;; actual Universal Ctags binary inside a throwaway source tree.
;;
;; Run the suite with:
;;
;;   Emacs -Q --batch -L . -l ctags-mode-tests.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'ctags-mode)

;;; Fixtures

(defconst ctags-mode-tests--entries
  '((:name "main"
     :path "src/main.c"
     :kind "function"
     :pattern "/^int main(void) {$/")
    (:name "add"
     :path "src/math.c"
     :kind "function"
     :pattern "/^int add(int a, int b) {$/")
    (:name "point"
     :path "src/math.c"
     :kind "struct"
     :pattern "/^struct point {$/"))
  "Three tag entries used by most rendering tests.")

(defun ctags-mode-tests--json (plist)
  "Return PLIST as one JSON object string."
  (let ((table (make-hash-table :test 'equal)))
    (cl-loop for (key value) on plist by #'cddr
             do (puthash (substring (symbol-name key) 1) value table))
    (json-serialize table)))

(defun ctags-mode-tests--ndjson (entries)
  "Return ENTRIES as newline-delimited JSON."
  (mapconcat #'ctags-mode-tests--json entries "\n"))

(defmacro ctags-mode-tests--with-tags-buffer (entries &rest body)
  "Insert tag ENTRIES into a fresh `ctags-mode' buffer, then run BODY."
  (declare (indent 1) (debug (form body)))
  `(let ((buf (generate-new-buffer " *ctags-mode-tests*")))
     (unwind-protect
         (with-current-buffer buf
           (insert (ctags-mode-tests--ndjson ,entries))
           (insert "\n")
           (ctags-mode)
           ,@body)
       (kill-buffer buf))))

(defun ctags-mode-tests--walk (fun)
  "Call FUN on every section of the current buffer, depth first."
  (when magit-root-section
    (ctags-mode-tests--walk-section magit-root-section fun)))

(defun ctags-mode-tests--walk-section (section fun)
  "Call FUN on SECTION and all of its children, depth first."
  (funcall fun section)
  (dolist (child (oref section children))
    (ctags-mode-tests--walk-section child fun)))

(defun ctags-mode-tests--sections (&optional type)
  "Return all sections of the current buffer, or those with TYPE."
  (let (result)
    (ctags-mode-tests--walk
     (lambda (section)
       (when (or (null type) (eq (oref section type) type))
         (push section result))))
    (nreverse result)))

(defun ctags-mode-tests--heading (section)
  "Return the heading text of SECTION."
  (string-trim-right
   (buffer-substring-no-properties (oref section start)
                                   (oref section content))))

(defmacro ctags-mode-tests--capture-messages (&rest body)
  "Run BODY and return the messages it emits, oldest first."
  (declare (indent 0) (debug (body)))
  `(let (messages)
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args) messages))))
       ,@body)
     (nreverse messages)))

(defun ctags-mode-tests--write-file (dir name content)
  "Write CONTENT to NAME inside DIR and return its absolute file name."
  (let ((file (expand-file-name name dir)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert content))
    file))

(defmacro ctags-mode-tests--with-source-tree (files &rest body)
  "Create a temporary directory holding FILES, then run BODY.
FILES is an alist of relative name to content.  The directory is bound
to `dir'."
  (declare (indent 1) (debug (form body)))
  `(let ((dir (file-name-as-directory
               (make-temp-file "ctags-mode-tests" t))))
     (unwind-protect
         (progn
           (dolist (file ,files)
             (ctags-mode-tests--write-file dir (car file) (cdr file)))
           ,@body)
       (dolist (buf (buffer-list))
         (when (string-prefix-p "*ctags" (buffer-name buf))
           (kill-buffer buf)))
       (delete-directory dir t))))

;;; Parsing

(ert-deftest ctags-mode-parse-buffer-reads-ndjson ()
  "Parse one object per line and keep the input order."
  (with-temp-buffer
    (insert (ctags-mode-tests--ndjson ctags-mode-tests--entries))
    (let ((tags (ctags--parse-buffer)))
      (should (= (length tags) 3))
      (should (equal (mapcar (lambda (tag) (plist-get tag :name)) tags)
                     '("main" "add" "point"))))))

(ert-deftest ctags-mode-parse-buffer-skips-blank-and-invalid-lines ()
  "Skip blank lines and lines that are not JSON objects."
  (with-temp-buffer
    (insert (ctags-mode-tests--json (car ctags-mode-tests--entries)))
    (insert "\n\n")
    (insert "this is not json\n")
    (insert "{}\n")
    (should (= (length (ctags--parse-buffer)) 2))))

(ert-deftest ctags-mode-parse-buffer-normalizes-keys ()
  "Map the JSON keys onto the documented plist keys."
  (with-temp-buffer
    (insert (ctags-mode-tests--json
             '(:name "peer" :path "peer.go" :kind "struct"
               :scope "core.link"
               :scopeKind "struct"
               :pattern "/^type peer struct {$/"
               :typeref "typename:core.peer")))
    (let ((tag (car (ctags--parse-buffer))))
      (should (equal (plist-get tag :name) "peer"))
      (should (equal (plist-get tag :path) "peer.go"))
      (should (equal (plist-get tag :kind) "struct"))
      (should (equal (plist-get tag :scope) "core.link"))
      (should (equal (plist-get tag :scope-kind) "struct"))
      (should (equal (plist-get tag :pattern) "/^type peer struct {$/"))
      (should (equal (plist-get tag :typeref) "typename:core.peer")))))

;;; Grouping and sorting

(ert-deftest ctags-mode-group-by-kind ()
  "Group entries by kind and keep the input order inside a group."
  (let* ((groups (ctags--group-by-kind ctags-mode-tests--entries))
         (kinds (sort (mapcar #'car groups) #'string<)))
    (should (equal kinds '("function" "struct")))
    (should (equal (mapcar (lambda (tag) (plist-get tag :name))
                           (cdr (assoc "function" groups)))
                   '("main" "add")))
    (should (= (length (cdr (assoc "struct" groups))) 1))))

(ert-deftest ctags-mode-group-by-kind-unknown ()
  "An entry without a kind goes into the \"unknown\" group."
  (let* ((groups (ctags--group-by-kind '((:name "x" :path "x.c")))))
    (should (equal (caar groups) "unknown"))))

(ert-deftest ctags-mode-sort-groups-by-count ()
  "Sort kind groups by descending entry count."
  (let ((ctags-default-kind-sort 'count)
        (groups '(("struct" . (a))
                  ("function" . (b c d))
                  ("macro" . (e f)))))
    (should (equal (mapcar #'car (ctags--sort-groups groups))
                   '("function" "macro" "struct")))))

(ert-deftest ctags-mode-sort-groups-by-name ()
  "Sort kind groups alphabetically."
  (let ((ctags-default-kind-sort 'name)
        (groups '(("struct" . (a))
                  ("function" . (b c d))
                  ("macro" . (e f)))))
    (should (equal (mapcar #'car (ctags--sort-groups groups))
                   '("function" "macro" "struct")))))

(ert-deftest ctags-mode-sort-entries-by-name ()
  "Sort entries by name and break ties by path."
  (let ((ctags-entry-sort 'name)
        (entries '((:name "beta" :path "b.c")
                   (:name "alpha" :path "z.c")
                   (:name "alpha" :path "a.c"))))
    (should (equal (mapcar (lambda (tag)
                             (concat (plist-get tag :name)
                                     "@"
                                     (plist-get tag :path)))
                           (ctags--sort-entries entries))
                   '("alpha@a.c" "alpha@z.c" "beta@b.c")))))

(ert-deftest ctags-mode-sort-entries-by-path ()
  "Sort entries by path and break ties by name."
  (let ((ctags-entry-sort 'path)
        (entries '((:name "beta" :path "a.c")
                   (:name "alpha" :path "z.c")
                   (:name "alpha" :path "a.c"))))
    (should (equal (mapcar (lambda (tag)
                             (concat (plist-get tag :path)
                                     "@"
                                     (plist-get tag :name)))
                           (ctags--sort-entries entries))
                   '("a.c@alpha" "a.c@beta" "z.c@alpha")))))

(ert-deftest ctags-mode-group-by-file-sorted ()
  "Group entries by path and sort the groups by path."
  (let ((groups (ctags--group-by-file ctags-mode-tests--entries)))
    (should (equal (mapcar #'car groups) '("src/main.c" "src/math.c")))
    (should (= (length (cdr (assoc "src/math.c" groups))) 2))))

(ert-deftest ctags-mode-group-by-file-unknown ()
  "An entry without a path goes into the \"(unknown)\" group."
  (let ((groups (ctags--group-by-file '((:name "x")))))
    (should (equal (caar groups) "(unknown)"))))

;;; Patterns

(ert-deftest ctags-mode-pattern-to-regexp-anchored ()
  "An anchored pattern is used as an Emacs regexp unchanged."
  (should (equal (ctags--pattern-to-regexp "/^int main(void) {$/")
                 "^int main(void) {$")))

(ert-deftest ctags-mode-pattern-to-regexp-unanchored ()
  "An unanchored pattern is quoted, so regexp syntax stays literal."
  (should (equal (ctags--pattern-to-regexp "/a*b/") "a\\*b")))

(ert-deftest ctags-mode-pattern-to-regexp-invalid ()
  "Return nil when the pattern is missing or has no slashes."
  (should-not (ctags--pattern-to-regexp nil))
  (should-not (ctags--pattern-to-regexp "no slashes"))
  (should-not (ctags--pattern-to-regexp 42)))

(ert-deftest ctags-mode-goto-pattern ()
  "Move point to the line that matches the pattern."
  (with-temp-buffer
    (insert "int sub(int a, int b) {\n")
    (insert "int add(int a, int b) {\n")
    (goto-char (point-min))
    (should (ctags--goto-pattern "/^int add(int a, int b) {$/"))
    (should (string-prefix-p "int add"
                             (buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position))))))

;;; Rendering

(ert-deftest ctags-mode-render-tree ()
  "Render the summary, kind, file and entry sections in order."
  (ctags-mode-tests--with-tags-buffer ctags-mode-tests--entries
    (should (equal (buffer-substring-no-properties
                    (point-min)
                    (save-excursion
                      (goto-char (point-min))
                      (line-end-position)))
                   "3 tags across 2 kinds"))
    (should (equal (mapcar (lambda (section) (oref section type))
                           (ctags-mode-tests--sections))
                   '(ctags-root
                     ctags-kind ctags-file ctags-entry
                     ctags-file ctags-entry
                     ctags-kind ctags-file ctags-entry)))
    (should (equal (mapcar (lambda (section) (oref section value))
                           (ctags-mode-tests--sections 'ctags-kind))
                   '("function" "struct")))
    (should (equal (mapcar (lambda (section) (oref section value))
                           (ctags-mode-tests--sections 'ctags-file))
                   '("src/main.c" "src/math.c" "src/math.c")))
    (should (= (length (ctags-mode-tests--sections 'ctags-entry)) 3))))

(ert-deftest ctags-mode-render-headings ()
  "Kind and file headings carry the child count and the path."
  (ctags-mode-tests--with-tags-buffer ctags-mode-tests--entries
    (let* ((kind (car (ctags-mode-tests--sections 'ctags-kind)))
           (file (car (ctags-mode-tests--sections 'ctags-file))))
      (should (equal (ctags-mode-tests--heading kind) "Function (2)"))
      (should (string-match-p "src/main.c (1)"
                              (ctags-mode-tests--heading file)))
      (should (equal (ctags-mode-tests--heading
                      (car (ctags-mode-tests--sections 'ctags-entry)))
                     "    main")))))

(ert-deftest ctags-mode-render-hides-child-count ()
  "Honor `ctags-show-child-count' set to nil."
  (let ((ctags-show-child-count nil))
    (ctags-mode-tests--with-tags-buffer ctags-mode-tests--entries
      (should (equal (ctags-mode-tests--heading
                      (car (ctags-mode-tests--sections 'ctags-kind)))
                     "Function")))))

(ert-deftest ctags-mode-render-empty-buffer ()
  "Render a placeholder when the buffer holds no tags."
  (ctags-mode-tests--with-tags-buffer nil
    (should (string-match-p "(no tags found)"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))
    (should (null (ctags-mode-tests--sections 'ctags-kind)))))

(ert-deftest ctags-mode-render-keeps-root-section ()
  "Always create a root section, so `magit-root-section' stays non-nil."
  (ctags-mode-tests--with-tags-buffer nil
    (should (oref magit-root-section type))
    (should (eq (oref magit-root-section type) 'ctags-root))))

(ert-deftest ctags-mode-render-order-follows-customization ()
  "Sort kinds and entries as the customization says."
  (let ((ctags-default-kind-sort 'name)
        (ctags-entry-sort 'path))
    (ctags-mode-tests--with-tags-buffer ctags-mode-tests--entries
      (should (equal (mapcar (lambda (section) (oref section value))
                             (ctags-mode-tests--sections 'ctags-kind))
                     '("function" "struct")))
      ;; Both functions share the kind section; path order is used.
      (should (equal (mapcar (lambda (section)
                               (plist-get (oref section value) :name))
                             (ctags-mode-tests--sections 'ctags-entry))
                     '("main" "add" "point"))))))

(ert-deftest ctags-mode-render-properties ()
  "Inhibit section markers, so large trees stay linear to render."
  (ctags-mode-tests--with-tags-buffer ctags-mode-tests--entries
    (should magit-section-inhibit-markers)
    (should (eq major-mode 'ctags-mode))
    (should buffer-read-only)))

;;; Visiting entries

(ert-deftest ctags-mode-visit-entry ()
  "Visit the source location of the entry at point."
  (ctags-mode-tests--with-source-tree
      '(("math.c" . "int sub(int a, int b) { return a - b; }\n\
int add(int a, int b) { return a + b; }\n"))
    (let ((buf (generate-new-buffer " *ctags-mode-visit*")))
      (unwind-protect
          (with-current-buffer buf
            (insert (ctags-mode-tests--ndjson
                     (list '(:name "add" :path "math.c" :kind "function"
                             :pattern "/^int add(int a, int b) {$/"))))
            (setq default-directory dir)
            (ctags-mode)
            (goto-char (oref (car (ctags-mode-tests--sections 'ctags-entry))
                             start))
            (ctags-visit-entry)
            (with-current-buffer (window-buffer)
              (should (equal (buffer-file-name)
                             (expand-file-name "math.c" dir)))
              (should (string-prefix-p
                       "int add"
                       (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position))))))
        (dolist (live (buffer-list))
          (when (string-match-p "math\\.c" (buffer-name live))
            (kill-buffer live)))
        (kill-buffer buf)))))

(ert-deftest ctags-mode-visit-entry-missing-file ()
  "Report a missing file instead of opening a wrong buffer."
  (ctags-mode-tests--with-tags-buffer
      (list '(:name "gone" :path "gone.c" :kind "function"))
    (goto-char (oref (car (ctags-mode-tests--sections 'ctags-entry)) start))
    (should (string-match-p "File not found"
                            (car (ctags-mode-tests--capture-messages
                                     (ctags-visit-entry)))))))

(ert-deftest ctags-mode-visit-entry-outside-entry ()
  "Report when point is not on a tag entry."
  (ctags-mode-tests--with-tags-buffer ctags-mode-tests--entries
    (goto-char (point-min))
    (should (string-match-p "No tag at point"
                            (car (ctags-mode-tests--capture-messages
                                     (ctags-visit-entry)))))))

;;; File-backed buffers

(ert-deftest ctags-mode-activates-for-tags-json ()
  "Open a file named TAGS.json in `ctags-mode'."
  (ctags-mode-tests--with-source-tree
      '(("TAGS.json" . ""))
    (let ((file (expand-file-name "TAGS.json" dir)))
      (with-temp-file file
        (insert (ctags-mode-tests--ndjson ctags-mode-tests--entries)))
      (let ((buf (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buf
              (should (eq major-mode 'ctags-mode))
              (should (equal ctags--source-dir dir))
              (should-not ctags--tags-dir)
              (should (= (length (ctags-mode-tests--sections 'ctags-entry))
                         3)))
          (kill-buffer buf))))))

(ert-deftest ctags-mode-open-any-file ()
  "Open a JSON file with another name through `ctags-open'."
  (ctags-mode-tests--with-source-tree
      '(("tags.json" . ""))
    (let ((file (expand-file-name "tags.json" dir)))
      (with-temp-file file
        (insert (ctags-mode-tests--json (car ctags-mode-tests--entries))))
      (let ((buf (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buf
              (should-not (eq major-mode 'ctags-mode))
              (ctags-open file)
              (should (eq major-mode 'ctags-mode))
              (should (= (length (ctags-mode-tests--sections
                                  'ctags-entry))
                         1)))
          (kill-buffer buf))))))

(ert-deftest ctags-mode-refresh-file-backed ()
  "Re-read the JSON file and re-render the tree on refresh."
  (ctags-mode-tests--with-source-tree
      '(("TAGS.json" . ""))
    (let ((file (expand-file-name "TAGS.json" dir)))
      (with-temp-file file
        (insert (ctags-mode-tests--json (car ctags-mode-tests--entries))))
      (let ((buf (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buf
              (should (= (length (ctags-mode-tests--sections 'ctags-entry))
                         1))
              (with-temp-file file
                (insert (ctags-mode-tests--ndjson ctags-mode-tests--entries)))
              (ctags-refresh)
              (should (= (length (ctags-mode-tests--sections 'ctags-entry))
                         3))
              (should (string-match-p "3 tags across 2 kinds"
                                      (buffer-string))))
          (kill-buffer buf))))))

(ert-deftest ctags-mode-revert-buffer ()
  "Revert a file-backed buffer without parsing the rendered tree."
  (ctags-mode-tests--with-source-tree
      '(("TAGS.json" . ""))
    (let ((file (expand-file-name "TAGS.json" dir)))
      (with-temp-file file
        (insert (ctags-mode-tests--json (car ctags-mode-tests--entries))))
      (let ((buf (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buf
              (revert-buffer nil t t)
              (should (= (length (ctags-mode-tests--sections 'ctags-entry))
                         1))
              (should (eq revert-buffer-function #'ctags--revert-buffer)))
          (kill-buffer buf))))))

(ert-deftest ctags-mode-refresh-without-source ()
  "Report that there is nothing to refresh in other buffers."
  (with-temp-buffer
    (should (string-match-p "nothing to refresh"
                            (car (ctags-mode-tests--capture-messages
                                     (ctags-refresh)))))))

;;; Ctags binary validation

(ert-deftest ctags-mode-check-ctags-rejects-etags ()
  "Signal a user error when the binary lacks JSON support."
  (let* ((dir (file-name-as-directory (make-temp-file "ctags-fake" t)))
         (fake (expand-file-name "ctags" dir)))
    (unwind-protect
        (progn
          (with-temp-file fake
            (insert "#!/bin/sh\nexit 1\n"))
          (set-file-modes fake #o755)
          (let ((ctags-program fake))
            (should-error (ctags--check-ctags) :type 'user-error)))
      (delete-directory dir t))))

(ert-deftest ctags-mode-check-ctags-accepts-universal-ctags ()
  "Accept Universal Ctags, which answers the JSON version probe."
  (skip-unless (executable-find ctags-program))
  (should (ctags--ctags-supports-json))
  (should-not (ctags--check-ctags)))

;;; Directory-backed buffers

(ert-deftest ctags-mode-run-renders-directory ()
  "Run ctags on a directory and render the tags it reports."
  (skip-unless (executable-find ctags-program))
  (ctags-mode-tests--with-source-tree
      '(("math.c" . "int add(int a, int b) { return a + b; }\n\
struct point { int x; int y; };\n"))
    (ctags-run dir)
    (let ((buf (current-buffer)))
      (unwind-protect
          (with-current-buffer buf
            (should (eq major-mode 'ctags-mode))
            (should (equal ctags--tags-dir dir))
            (should (equal ctags--source-dir dir))
            (should (string-prefix-p "*ctags: " (buffer-name)))
            (should (>= (length (ctags-mode-tests--sections 'ctags-kind)) 2))
            (should (string-match-p "add" (buffer-string)))
            (should (functionp bookmark-make-record-function)))
        (kill-buffer buf)))))

(ert-deftest ctags-mode-run-reuses-buffer ()
  "Repeated `ctags-run' calls reuse the existing buffer."
  (skip-unless (executable-find ctags-program))
  (ctags-mode-tests--with-source-tree
      '(("math.c" . "int add(int a, int b) { return a + b; }\n"))
    (let ((first (progn (ctags-run dir) (current-buffer))))
      (unwind-protect
          (let ((second (progn (ctags-run dir) (current-buffer))))
            (should (eq first second))
            (with-current-buffer second
              (should (= (length (ctags-mode-tests--sections 'ctags-entry))
                         1))))
        (kill-buffer first)))))

(ert-deftest ctags-mode-refresh-directory-backed ()
  "Refresh a directory-backed buffer by re-running ctags."
  (skip-unless (executable-find ctags-program))
  (ctags-mode-tests--with-source-tree
      '(("math.c" . "int add(int a, int b) { return a + b; }\n"))
    (ctags-run dir)
    (let ((buf (current-buffer)))
      (unwind-protect
          (with-current-buffer buf
            (should (= (length (ctags-mode-tests--sections 'ctags-entry)) 1))
            (ctags-mode-tests--write-file
             dir "more.c" "int sub(int a, int b) { return a - b; }\n")
            (ctags-refresh)
            (should (= (length (ctags-mode-tests--sections 'ctags-entry)) 2)))
        (kill-buffer buf)))))

(ert-deftest ctags-mode-bookmark-record ()
  "Build a bookmark record that carries the directory."
  (skip-unless (executable-find ctags-program))
  (ctags-mode-tests--with-source-tree
      '(("math.c" . "int add(int a, int b) { return a + b; }\n"))
    (ctags-run dir)
    (let ((buf (current-buffer)))
      (unwind-protect
          (with-current-buffer buf
            (let ((record (ctags--bookmark-make-record)))
              (should (equal (bookmark-prop-get record 'directory) dir))
              (should (eq (bookmark-prop-get record 'handler)
                          #'ctags--bookmark-handler))
              (should (string-prefix-p "ctags: " (car record)))))
        (kill-buffer buf)))))

(ert-deftest ctags-mode-bookmark-handler ()
  "Restore a directory-backed buffer from a bookmark record."
  (skip-unless (executable-find ctags-program))
  (ctags-mode-tests--with-source-tree
      '(("math.c" . "int add(int a, int b) { return a + b; }\n"))
    (ctags-run dir)
    (let ((record (ctags--bookmark-make-record))
          (name (buffer-name (current-buffer))))
      ;; Drop the buffer, so the handler has to recreate it.
      (kill-buffer (current-buffer))
      (unwind-protect
          (progn
            (ctags--bookmark-handler record)
            (should (equal (buffer-name (current-buffer)) name))
            (with-current-buffer (current-buffer)
              (should (equal ctags--tags-dir dir))
              (should (= (length (ctags-mode-tests--sections 'ctags-entry))
                         1))))
        (kill-buffer name)))))

(provide 'ctags-mode-tests)
;;; ctags-mode-tests.el ends here
