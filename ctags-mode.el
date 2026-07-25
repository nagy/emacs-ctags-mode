;;; ctags-mode.el --- Browse ctags JSON output in a collapsible tree -*- lexical-binding: t -*-

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, ctags
;; Package-Requires: ((emacs "30.1") (magit-section "3.0"))
;; URL: https://github.com/nagy/emacs-ctags-mode

;;; Commentary:

;; ctags-mode is a major mode for browsing the JSON output of
;; Universal Ctags.  Generate a tags file with:
;;
;;   ctags -R --output-format=json -f - > ./TAGS.json
;;
;; Then open the file with `find-file' (it is automatically associated
;; with `ctags-mode' when named "TAGS.json") or use `ctags-open' to
;; pick any file.
;;
;; Tags are grouped by kind (func, struct, variable, …) in collapsible
;; sections, much like `magit-status'.  Use TAB to expand/collapse,
;; `n' / `p' to navigate, and RET to visit the source location.

;;; Code:

(require 'magit-section)
(require 'json)
(require 'bookmark)
(require 'cl-lib)
(require 'seq)


;;; Customization

(defgroup ctags nil
  "Browse ctags JSON output in a collapsible tree."
  :group 'tools)

(defcustom ctags-show-child-count t
  "Whether to show the number of children in section headings."
  :type 'boolean
  :group 'ctags)

(defcustom ctags-default-kind-sort 'count
  "How to sort the top-level kind sections.
`count'  -- by number of entries (descending).
`name'   -- alphabetically by kind name."
  :type '(choice (const :tag "By count (descending)" count)
                 (const :tag "By name (alphabetical)" name))
  :group 'ctags)

(defcustom ctags-entry-sort 'name
  "How to sort entries within a kind section.
`name'   -- by tag name, then path.
`path'   -- by file path, then name."
  :type '(choice (const :tag "By name then path" name)
                 (const :tag "By path then name" path))
  :group 'ctags)

(defcustom ctags-program "ctags"
  "Path to the Universal Ctags executable.
See URL `https://github.com/universal-ctags'.
Note: Emacs' own `etags' (sometimes installed as `ctags') does NOT
support JSON output.  You need Universal Ctags for this mode."
  :type 'file
  :group 'ctags)


;;; Faces

(defface ctags-kind-heading
  '((t :inherit magit-section-heading :weight bold))
  "Face for kind section headings."
  :group 'ctags)

(defface ctags-entry-name
  '((t :inherit font-lock-function-name-face))
  "Face for the tag name in an entry line."
  :group 'ctags)

(defface ctags-entry-path
  '((t :inherit font-lock-string-face))
  "Face for the file path in an entry line."
  :group 'ctags)

(defface ctags-entry-scope
  '((t :inherit font-lock-comment-face))
  "Face for the scope in an entry line."
  :group 'ctags)


;;; Keymap

(defvar-keymap ctags-mode-map
  :parent magit-section-mode-map
  "RET" #'ctags-visit-entry
  "SPC" #'ctags-visit-entry
  "g"   #'ctags-refresh
  "G"   #'ctags-refresh)


;;; Internals

(defvar-local ctags--source-dir nil
  "Directory used for resolving relative paths in tags.
For file-backed buffers this is the directory of the JSON file.
For directory-backed buffers this is the directory ctags ran on.")

(defvar-local ctags--tags-dir nil
  "Directory that ctags was run on, or nil if reading from a JSON file.
Non-nil for buffers created by `ctags-run'.")

(defun ctags--parse-buffer ()
  "Parse the current buffer as newline-delimited JSON (NDJSON).
Return a list of tag plists."
  (let ((tags nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position)
                     (line-end-position))))
          (unless (string-blank-p line)
            (condition-case nil
                (push (ctags--normalize-entry (json-parse-string line))
                      tags)
              (error nil))))
        (forward-line 1)))
    (nreverse tags)))

(defun ctags--normalize-entry (alist)
  "Convert ALIST (from `json-parse-string') into a plist with standard keys.
Keys: :name, :path, :kind, :scope, :scope-kind, :pattern, :typeref."
  (list :name       (gethash "name" alist)
        :path       (gethash "path" alist)
        :kind       (gethash "kind" alist)
        :scope      (gethash "scope" alist)
        :scope-kind (gethash "scopeKind" alist)
        :pattern    (gethash "pattern" alist)
        :typeref    (gethash "typeref" alist)))

(defun ctags--group-by-kind (entries)
  "Group ENTRIES by :kind into an alist of (KIND . ENTRIES)."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (let* ((kind (or (plist-get entry :kind) "unknown"))
             (lst  (gethash kind groups)))
        (puthash kind (cons entry lst) groups)))
    (cl-loop for kind being the hash-keys of groups
             collect (cons kind (nreverse (gethash kind groups))))))

(defun ctags--sort-groups (groups)
  "Sort GROUPS according to `ctags-default-kind-sort'.
GROUPS is an alist of (KIND . ENTRIES)."
  (pcase ctags-default-kind-sort
    ('count (sort groups (lambda (a b) (> (length (cdr a)) (length (cdr b))))))
    ('name  (sort groups (lambda (a b) (string< (car a) (car b)))))))

(defun ctags--sort-entries (entries)
  "Sort ENTRIES according to `ctags-entry-sort'.
ENTRIES is a list of plists."
  (pcase ctags-entry-sort
    ('name
     (sort entries
           (lambda (a b)
             (let ((na (plist-get a :name))
                   (nb (plist-get b :name)))
               (if (string= na nb)
                   (string< (or (plist-get a :path) "")
                            (or (plist-get b :path) ""))
                 (string< na nb))))))
    ('path
     (sort entries
           (lambda (a b)
             (let ((pa (or (plist-get a :path) ""))
                   (pb (or (plist-get b :path) "")))
               (if (string= pa pb)
                   (string< (or (plist-get a :name) "")
                            (or (plist-get b :name) ""))
                 (string< pa pb))))))))


;;; Section insertion

(defun ctags--insert-kind-section (kind entries)
  "Insert a collapsible section for KIND containing ENTRIES."
  (magit-insert-section (ctags-kind kind)
    (magit-insert-heading
      (propertize (capitalize kind)
                  'font-lock-face 'ctags-kind-heading)
      (when ctags-show-child-count
        (propertize (format " (%d)" (length entries))
                    'font-lock-face 'magit-section-child-count)))
    (dolist (group (ctags--group-by-file entries))
      (ctags--insert-file-section (car group) (cdr group)))))

(defun ctags--group-by-file (entries)
  "Group ENTRIES by :path into an alist of (PATH . ENTRIES),
sorted by path."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (let* ((path (or (plist-get entry :path) "(unknown)"))
             (lst  (gethash path groups)))
        (puthash path (cons entry lst) groups)))
    (sort (cl-loop for path being the hash-keys of groups
                   collect (cons path (nreverse (gethash path groups))))
          (lambda (a b) (string< (car a) (car b))))))

(defun ctags--insert-file-section (path entries)
  "Insert a collapsible section for a file PATH containing ENTRIES."
  (magit-insert-section (ctags-file path)
    (magit-insert-heading
      (propertize (concat "  " path)
                  'font-lock-face 'ctags-entry-path)
      (when ctags-show-child-count
        (propertize (format " (%d)" (length entries))
                    'font-lock-face 'magit-section-child-count)))
    (dolist (entry entries)
      (ctags--insert-entry entry))))

(defun ctags--insert-entry (entry)
  "Insert a single tag ENTRY as a heading-only section."
  (let ((name  (plist-get entry :name))
        (scope (plist-get entry :scope)))
    (magit-insert-section (ctags-entry entry)
      (magit-insert-heading
        (propertize (format "    %s" name)
                    'font-lock-face 'ctags-entry-name)
        (when scope
          (concat
           " "
           (propertize (format "(%s)" scope)
                       'font-lock-face 'ctags-entry-scope)))))))

(defun ctags--insert-summary (total-tags total-kinds)
  "Insert a summary line showing totals."
  (insert (propertize
           (format "%d tags across %d kinds\n\n"
                   total-tags total-kinds)
           'font-lock-face 'magit-section-heading)))

(defun ctags--refresh-buffer (&optional old-ident)
  "Refresh the contents of the current ctags-mode buffer.
If OLD-IDENT is given (from `magit-section-ident'), try to restore
point to the matching section in the new tree."
  (let ((inhibit-read-only t)
        (entries (ctags--parse-buffer)))
    (erase-buffer)
    (magit-insert-section (ctags-root)
      (if (null entries)
          (insert "(no tags found)\n")
        (let* ((groups      (ctags--group-by-kind entries))
               (sorted      (ctags--sort-groups groups))
               (total-kinds (length sorted)))
          (ctags--insert-summary (length entries) total-kinds)
          (dolist (group sorted)
            (let ((kind    (car group))
                  (entries (ctags--sort-entries (cdr group))))
              (ctags--insert-kind-section kind entries))))))
    (if-let* ((new-section (and old-ident (magit-get-section old-ident))))
        (goto-char (oref new-section start))
      (goto-char (point-min)))))


;;; Commands

(defun ctags-visit-entry ()
  "Visit the tag at point in its source file."
  (interactive)
  (let ((section (magit-current-section)))
    (when section
      (pcase (oref section type)
        ('ctags-entry
         (let* ((entry (oref section value))
                (path  (plist-get entry :path))
                (name  (plist-get entry :name)))
           (if (not path)
               (message "No file path for this tag")
             (let ((full-path (expand-file-name path ctags--source-dir)))
               (if (file-exists-p full-path)
                   (progn
                     (find-file-other-window full-path)
                     (goto-char (point-min))
                     ;; Try to find the definition by searching for the
                     ;; pattern.  If that fails, fall back to name.
                     (or (ctags--goto-pattern (plist-get entry :pattern))
                         (search-forward name nil t)
                         (goto-char (point-min))))
                 (message "File not found: %s" full-path))))))
        (_ (message "No tag at point"))))))

(defun ctags--goto-pattern (pattern)
  "Go to PATTERN in the current buffer.
PATTERN is a ctags pattern like /^func ...$/ or /^  set ARGS...$/.
Returns non-nil if a match was found."
  (when (and pattern (stringp pattern))
    (let ((regexp (ctags--pattern-to-regexp pattern)))
      (when regexp
        (goto-char (point-min))
        (re-search-forward regexp nil t)))))

(defun ctags--pattern-to-regexp (pattern)
  "Convert a ctags PATTERN to an Emacs regexp.
Patterns have the form /^...$/ or /...$/."
  (when (stringp pattern)
    (save-match-data
      (if (string-match "\\`/\\(\\^.*\\$\\)/\\'" pattern)
          (match-string 1 pattern)
        (when (string-match "\\`/\\(.*\\)/\\'" pattern)
          (regexp-quote (match-string 1 pattern)))))))

(defun ctags--ctags-supports-json ()
  "Return non-nil if `ctags-program' supports --output-format=json."
  (with-temp-buffer
    (and (zerop (call-process ctags-program nil t nil
                              "--output-format=json" "--version"))
         t)))

(defun ctags-refresh ()
  "Refresh the ctags buffer.
For directory-backed buffers (created by `ctags-run'), re-runs ctags.
For file-backed buffers, re-reads the JSON file."
  (interactive)
  (let ((old-ident (and (magit-current-section)
                        (magit-section-ident (magit-current-section)))))
    (cond
     (ctags--tags-dir
      (let ((inhibit-read-only t)
            (dir ctags--tags-dir))
        (erase-buffer)
        (let ((default-directory dir)
              (exit-code (call-process ctags-program nil t nil
                                       "-R" "--output-format=json" "-f" "-")))
          (unless (zerop exit-code)
            (message "ctags exited with code %d" exit-code)))
        (ctags--refresh-buffer old-ident)
        (message "Refreshed ctags in %s" (abbreviate-file-name dir))))
     (buffer-file-name
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents buffer-file-name)
        (ctags--refresh-buffer old-ident)
        (message "Refreshed ctags buffer")))
     (t
      (message "ctags-mode: nothing to refresh")))))

;;;###autoload
(defun ctags-open (file)
  "Open a ctags JSON FILE in `ctags-mode'.
Use this if the file is not named \"TAGS.json\" and therefore
not automatically opened in `ctags-mode'."
  (interactive "fCtags JSON file: ")
  (find-file file)
  (unless (eq major-mode 'ctags-mode)
    (ctags-mode)))

;;;###autoload
(defun ctags--check-ctags ()
  "Check that `ctags-program' is Universal Ctags.  Signal an error if not."
  (unless (ctags--ctags-supports-json)
    (user-error
     (concat "%s does not support --output-format=json."
             "  You need Universal Ctags, not Emacs etags."
             "  Set `ctags-program' to the correct binary.")
     ctags-program)))

;;;###autoload
(defun ctags-run (dir)
  "Run `ctags -R --output-format=json' on DIR and browse the result.
Creates a buffer named `*ctags: <dir>*' in `ctags-mode'.  The
buffer is directory-backed: refreshing it re-runs ctags on the
directory.  You can bookmark this buffer with `\\[bookmark-set]'.

If a buffer for DIR already exists, it is refreshed and reused."
  (interactive
   (list (read-directory-name "Ctags directory: "
                              default-directory nil t)))
  (ctags--check-ctags)
  (let* ((dir (expand-file-name dir))
         (bufname (format "*ctags: %s*" (abbreviate-file-name dir)))
         (existing (get-buffer bufname))
         (buf (get-buffer-create bufname)))
    ;; Populate the buffer with ctags output FIRST, then enable the mode.
    (with-current-buffer buf
      (setq-local default-directory dir)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (let ((exit-code (call-process ctags-program nil t nil
                                       "-R" "--output-format=json" "-f" "-")))
          (unless (zerop exit-code)
            (message "Warning: ctags exited with code %d" exit-code))))
      (if (eq major-mode 'ctags-mode)
          ;; Buffer already had ctags-mode; just re-render from the new
          ;; content (which is already in the buffer).
          (ctags--refresh-buffer)
        ;; Fresh buffer: enable ctags-mode, which calls ctags--refresh-buffer.
        (ctags-mode))
      (setq-local ctags--tags-dir dir)
      (setq-local ctags--source-dir dir)
      (setq-local bookmark-make-record-function #'ctags--bookmark-make-record)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (if existing
        (message "Refreshed ctags in %s" (abbreviate-file-name dir))
      (message "Ctags in %s (%d kinds)"
               (abbreviate-file-name dir)
               (length (oref magit-root-section children))))))

;;;###autoload
(defun ctags-run-here ()
  "Run `ctags-run' on `default-directory' without prompting."
  (interactive)
  (ctags-run default-directory))

(defun ctags--revert-buffer (&rest _ignored)
  "`revert-buffer-function' for ctags-mode buffers.
Handles both file-backed and directory-backed buffers by delegating
 to `ctags-refresh'."
  (ctags-refresh))

(defun ctags--bookmark-make-record ()
  "Return a bookmark record for the current ctags buffer.
Only supported for directory-backed buffers (see `ctags--tags-dir')."
  (when ctags--tags-dir
    `(,(format "ctags: %s" (abbreviate-file-name ctags--tags-dir))
      (directory . ,ctags--tags-dir)
      (handler  . ctags--bookmark-handler)
      (defaults . ,(list (format "ctags: %s"
                                 (abbreviate-file-name ctags--tags-dir)))))))

(defun ctags--bookmark-handler (record)
  "Restore a ctags bookmark from RECORD by re-running ctags."
  (ctags-run (bookmark-prop-get record 'directory)))


;;; Major mode

;;;###autoload
(define-derived-mode ctags-mode magit-section-mode "Ctags"
  "Major mode for browsing ctags JSON output.

Tags are grouped by kind (func, struct, variable, …) in
collapsible sections.  Use the following keys:

\\{ctags-mode-map}

Two usage modes:
- File-backed: open a JSON file produced by ctags.
- Directory-backed: `\\[ctags-run]' runs ctags on a directory and
  shows the result.  The buffer is bookmarkable."
  :group 'ctags
  (setq-local ctags--source-dir
              (file-name-directory
               (or buffer-file-name default-directory)))
  (setq-local ctags--tags-dir nil)
  (setq-local revert-buffer-function #'ctags--revert-buffer)
  (ctags--refresh-buffer)
  (goto-char (point-min)))


;;; Auto-mode association

;;;###autoload
(add-to-list 'auto-mode-alist '("/TAGS\\.json\\'" . ctags-mode))

(provide 'ctags-mode)
;;; ctags-mode.el ends here
