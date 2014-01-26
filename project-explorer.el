;;; project-explorer.el --- A project explorer sidebar -*- lexical-binding: t -*-

;; Hi-lock: (("^;;; \\*.+" (0 '(:inherit (bold org-level-1)) t)))
;; Hi-lock: end

;;; Version: 0.11.3
;;; Author: sabof
;;; URL: https://github.com/sabof/project-explorer
;;; Package-Requires: ((cl-lib "0.3") (es-lib "0.3"))

;;; Commentary:

;; The project is hosted at https://github.com/sabof/project-explorer
;; The latest version, and all the relevant information can be found there.

;;; License:

;; This file is NOT part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program ; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Code:

(require 'cl-lib)
(require 'es-lib)
(require 'dired)

(require 'helm-utils nil t)
(require 'helm-mode nil t)
(require 'helm-locate nil t)
(require 'helm-files nil t)
(require 'projectile nil t)

;;; * User variables

(defgroup project-explorer nil
  "A project explorer sidebar."
  :group 'convenience)

(defcustom pe/directory-tree-function
  'pe/get-directory-tree-async
  "Backend used for tree retrieval"
  :group 'project-explorer
  :type '(radio
          (const :tag "External (GNU find)" pe/get-directory-tree-external)
          (const :tag "Internal (sync)" pe/get-directory-tree-simple)
          (const :tag "Internal (async)" pe/get-directory-tree-async)))

(defcustom pe/cache-enabled t
  "Whether to use cache."
  :group 'project-explorer
  :type 'boolean)

(defcustom pe/auto-refresh-cache t
  "Start a refresh when a cached listing is used.
The feature is available only for asynchronous backends."
  :group 'project-explorer
  :type 'boolean)

(defcustom pe/cache-directory
  (concat (file-name-as-directory
           user-emacs-directory)
          "project-explorer-cache/")
  "Directory where cached trees will be stored."
  :group 'project-explorer
  :type 'string)

(defcustom pe/get-directory-tree-external-command
  "find . \\( ! -path '*/.*' \\) \\( -type d -printf \"%p/\\n\" , -type f -print \\) "
  "Command to use for `pe/get-directory-tree-external'"
  :group 'project-explorer
  :type 'string)

(defcustom pe/side 'left
  "On which side to display the sidebar."
  :group 'project-explorer
  :type '(radio
          (const :tag "Left" left)
          (const :tag "Right" right)))

(defcustom pe/width 40
  "Width of the sidebar."
  :group 'project-explorer
  :type 'integer)

(defcustom pe/inline-folders t
  "Try to inline folders.
When set to t, folders containing only one folder will be displayed as one
entry."
  :group 'project-explorer
  :type 'boolean)

(defcustom pe/mode-line-format
  `(:eval (concat (propertize
                   (concat "  PE: "
                           (file-name-nondirectory
                            (directory-file-name
                             default-directory)))
                   'face 'font-lock-function-name-face
                   'help-echo default-directory)
                  (when pe/reverting
                    " (Indexing)")
                  ))
  "What to display in the mode-line.
Use the default when nil."
  :group 'project-explorer
  :type 'sexp)

(defcustom pe/goto-current-file-on-open t
  "When true, focus on the current file each time project explorer is revealed."
  :group 'project-explorer
  :type 'boolean)

(defcustom pe/omit-regex "^\\.\\|^#\\|~$"
  "Specify which files to omit.
Directories matching this regular expression won't be traversed."
  :group 'project-explorer
  :type '(choice
          (const :tag "Show all files" nil)
          (string :tag "Files matching this regex won't be shown")))

(defcustom pe/project-root-function
  'pe/project-root-function-default
  "A function that determines the project root.
Called with no arguments, with the originating buffer as current."
  :group 'project-explorer
  :type 'symbol)

(defcustom pe/confirm-delete t
  "Whether to ask for confimration before deleting."
  :group 'project-explorer
  :type 'boolean)

(defface pe/file-face
    '((t (:inherit default)))
  "Face used for regular files in project-explorer sidebar."
  :group 'project-explorer)

(defface pe/directory-face
    '((t (:inherit dired-directory)))
  "Face used for directories in project-explorer sidebar."
  :group 'project-explorer)

;;; * Internal variables

(defvar pe/get-directory-tree-async-delay 0.5
  "Delay for the idle timer in `pe/get-directory-tree-async'.")

(defvar pe/cache-alist nil
  "In-memory cache of directory trees.")

(defvar-local pe/project-root nil
  "The project a project-explorer buffer belongs to.
Set once, when the buffer is first created.")
(defvar-local pe/data nil
  "Raw data for the tree. Unsorted.")
(defvar-local pe/get-directory-tree-async-queue nil)
(defvar-local pe/folds-open nil)
(defvar-local pe/previous-directory nil)
(defvar-local pe/helm-cache nil)
(defvar-local pe/reverting nil)
(defvar-local pe/get-directory-tree-async-timer nil)
(defvar-local pe/origin-file-name nil)

;;; * Backend

(defun pe/project-root-function-default ()
  (expand-file-name
   (or (and (fboundp 'projectile-project-root)
            (projectile-project-root))
       (locate-dominating-file default-directory ".git")
       (cl-find-if (lambda (a-root) (string-prefix-p a-root default-directory))
                   (mapcar (apply-partially 'buffer-local-value 'pe/project-root)
                           (pe/get-project-explorer-buffers)))
       default-directory)))

(cl-defun pe/compress-tree (branch)
  (cond ( (not (consp branch))
          branch)
        ( (= (length branch) 1)
          branch)
        ( (and (= (length branch) 2)
               (consp (cl-second branch)))
          (pe/compress-tree
           (cons (concat (car branch) "/" (cl-caadr branch))
                 (cl-cdadr branch))))
        ( t (cons (car branch)
                  (mapcar 'pe/compress-tree (cdr branch))))))

(cl-defun pe/sort (branch &optional dont-recurse)
  "Recursively sort a tree.
Directories first, then alphabetically."
  (when (stringp branch)
    (cl-return-from pe/sort branch))
  (let (( new-rest
          (sort (cdr branch)
                (lambda (a b)
                  (cond ( (and (consp a)
                               (stringp b))
                          t)
                        ( (and (stringp a)
                               (consp b))
                          nil)
                        ( (and (consp a) (consp b))
                          (string< (car a) (car b)))
                        ( t (string< a b)))))))
    (if dont-recurse
        (setcdr branch new-rest)
      (setcdr branch (mapcar 'pe/sort new-rest)))
    branch
    ))

(defun pe/file-interesting-p (name)
  (if pe/omit-regex
      (not (string-match-p pe/omit-regex name))
    t))

(cl-defun pe/data-get (file-name)
  (let* (( relative-name
           (directory-file-name
            (substring file-name
                       (length default-directory))))
         ( segments
           (split-string relative-name "/" t))
         ( head pe/data))
    (while segments
      (if (not (cdr segments))
          (cl-return-from pe/data-get
            (cl-find (car segments)
                     (cdr head)
                     :key (lambda (it)
                            (if (consp it)
                                (car it)
                              it))
                     :test 'equal))
        (setq head (cl-find (car segments)
                            (cdr head)
                            :key 'car-safe
                            :test 'equal)))
      (pop segments))))

(cl-defun pe/data-add (file-name &optional thing-to-add)
  (unless (string-prefix-p default-directory file-name)
    (cl-return-from pe/data-add))
  (unless (consp thing-to-add)
    (setq thing-to-add nil))
  (let* (( is-directory (string-match-p "/$" file-name))
         ( relative-name
           (directory-file-name
            (substring file-name
                       (length default-directory))))
         ( segments
           (split-string relative-name "/" t))
         ( ---
           (when thing-to-add
             (setcar thing-to-add
                     (car (last segments)))))
         ( thing-to-add (or thing-to-add
                            (if is-directory
                                (last segments)
                              (car (last segments)))))
         ( head pe/data))
    (while segments
      (if (not (cdr segments))
          (setcdr head (cdr (pe/sort (nconc head (list thing-to-add)))))
        (setq head (cl-find (car segments)
                            (cdr head)
                            :key 'car-safe
                            :test 'equal)))
      (pop segments))))

(defun pe/data-delete (file-name)
  (let* (( relative-name
           (directory-file-name
            (substring file-name
                       (length default-directory))))
         ( segments
           (split-string relative-name "/" t))
         ( head pe/data))
    (while segments
      (if (not (cdr segments))
          (setcdr head (cl-remove (car segments)
                                  (cdr head)
                                  :key (lambda (it)
                                         (if (consp it)
                                             (car it)
                                           it))
                                  :test 'equal))
        (setq head (cl-find (car segments)
                            (cdr head)
                            :key 'car-safe
                            :test 'equal)))
      (pop segments))))

(defun pe/paths-to-tree (paths)
  "Takes a list of paths as input, and convertes it to a tree."
  (let* (( path-to-list
           (lambda (path)
             (let* (( normalized-path
                      (replace-regexp-in-string "\\\\" "/" path t t))
                    ( split-path (split-string normalized-path "/" t))
                    ( dir-path-p
                      (string-match-p "/$" normalized-path)))
               (unless (string-equal "." (car split-path))
                 (push "." split-path))
               (cons (if dir-path-p 'directory 'file)
                     split-path))))
         ( add-member (lambda (what where)
                        (setcdr where (cons what (cdr where)))
                        what))
         ( root (list nil))
         head)
    (cl-loop for path-raw in paths
             for (type . path) = (funcall path-to-list path-raw)
             do
             (setq head root)
             (cl-loop for segment in path
                      for i = 0 then (1+ i)
                      for is-last = (= (length path) (1+ i))
                      do (setq head
                               (or (cl-find segment
                                            (rest head)
                                            :test 'equal
                                            :key 'car-safe)
                                   (funcall add-member
                                            (if (or (not is-last)
                                                    (eq type 'directory))
                                                (list segment)
                                              segment)
                                            head)
                                   ))))
    (cadr root)
    ))

(defun pe/get-directory-tree-simple (dir done-func)
  (cl-labels
      ((walker (dir)
         (let (( files (cl-remove-if
                        (lambda (file)
                          (or (member file '("." ".."))
                              (not (pe/file-interesting-p file))))
                        (directory-files dir nil nil t))))
           (cons (file-name-nondirectory (directory-file-name dir))
                 (mapcar (lambda (file)
                           (if (file-directory-p (concat dir file))
                               (walker (concat dir file "/"))
                             file))
                         files)))))
    (funcall done-func (walker dir))))

;;; ** pe/get-directory-tree-external

(cl-defun pe/get-directory-tree-external (dir done-func)
  (let* (( default-directory dir)
         ( buffer (current-buffer))
         ( output "")
         ( process
           (start-process "tree-find"
                          buffer shell-file-name
                          shell-command-switch
                          pe/get-directory-tree-external-command)))
    (set-process-filter process
                        (lambda (process string)
                          (cl-callf concat output string)))
    (set-process-sentinel process
                          (lambda (process change)
                            (if (equal change "finished\n")
                                (let (( result
                                        (pe/paths-to-tree
                                         (split-string output "\n" t))))
                                  (setcar result (file-name-nondirectory
                                                  (directory-file-name
                                                   dir)))
                                  (funcall done-func result))
                              (setq pe/reverting nil))))
    ))

(put 'pe/get-directory-tree-external 'pe/async t)

(defun pe/get-directory-tree-external-cancel ()
  (let ((process (get-buffer-process (current-buffer))))
    (when process
      (kill-process process)))
  (setq pe/reverting nil))

(put 'pe/get-directory-tree-external
     'pe/cancel
     'pe/get-directory-tree-external-cancel)

;;; ** pe/get-directory-tree-async

(defun pe/get-directory-tree-async (dir done-func &optional root-level)
  (let* (( inhibit-quit t)
         ( buffer (current-buffer))
         ( files (cl-remove-if
                  (lambda (file)
                    (or (member file '("." ".."))
                        (not (pe/file-interesting-p file))))
                  (directory-files dir nil nil t)))
         ( level
           (cons (file-name-nondirectory (directory-file-name dir))
                 nil)))
    (setq root-level (or root-level level))
    (setcdr level
            (cl-loop for file in files
                     for i from 1
                     collecting
                     (if (file-directory-p (concat dir file))
                         (let ((dir (concat dir file "/"))
                               (iter i))
                           (push (lambda ()
                                   (when (buffer-live-p buffer)
                                     (with-current-buffer buffer
                                       (setf (nth iter level)
                                             (pe/get-directory-tree-async
                                              dir done-func root-level)))))
                                 pe/get-directory-tree-async-queue)
                           iter)
                       file)))
    (setq pe/get-directory-tree-async-timer
          (if pe/get-directory-tree-async-queue
              (run-with-idle-timer pe/get-directory-tree-async-delay
                                   nil (pop pe/get-directory-tree-async-queue))
            (run-with-idle-timer pe/get-directory-tree-async-delay
                                 nil done-func root-level)))
    level))

(put 'pe/get-directory-tree-async 'pe/async t)

(defun pe/get-directory-tree-async-cancel ()
  (when (timerp pe/get-directory-tree-async-timer)
    (cancel-timer pe/get-directory-tree-async-timer))
  (setq pe/get-directory-tree-async-queue nil)
  (setq pe/reverting nil))

(put 'pe/get-directory-tree-async
     'pe/cancel
     'pe/get-directory-tree-async-cancel)

;;; ** Caching

(defun pe/cache-clear ()
  "Clear local cache, and delete cache files for all directories."
  (interactive)
  (setq pe/cache-alist nil)
  (mapc (lambda (file-name)
          (unless (member file-name '("." ".."))
            (delete-file (concat pe/cache-directory file-name))))
        (directory-files pe/cache-directory nil nil t)))

(defun pe/cache-make-filename (filename)
  (concat
   (file-name-as-directory
    pe/cache-directory)
   (file-name-nondirectory
    (make-backup-file-name filename))))

(defun pe/cache-save ()
  (cl-assert pe/project-root)
  (let (( cache-file-name (pe/cache-make-filename default-directory))
        ( data pe/data))
    (when (cl-assoc default-directory pe/cache-alist
                    :test 'string-equal)
      (setq pe/cache-alist
            (cl-remove default-directory
                       pe/cache-alist
                       :key 'car
                       :test 'string-equal)))
    (unless (file-exists-p (file-name-as-directory pe/cache-directory))
      (make-directory pe/cache-directory t))
    (with-temp-buffer
      (let ((print-level nil)
            (print-length nil))
        (print data (current-buffer)))
      (write-region nil nil cache-file-name nil 'silent))
    (setq pe/cache-alist (acons default-directory data
                                pe/cache-alist))))

(cl-defun pe/cache-load ()
  (cl-assert pe/project-root)
  (let (( from-alist (cl-assoc default-directory pe/cache-alist
                               :test 'string-equal)))
    (when (and from-alist (cdr from-alist))
      (cl-return-from pe/cache-load (cdr from-alist))))
  (let ((cache-file-name (pe/cache-make-filename default-directory))
        cache-content)
    (when (file-exists-p cache-file-name)
      (setq cache-content
            (with-temp-buffer
              (insert-file-contents cache-file-name)
              (goto-char (point-min))
              (read (current-buffer))))
      (setq pe/cache-alist (acons default-directory cache-content
                                  pe/cache-alist))
      cache-content))
  )

;;; * Fold data

(defun pe/folds-add (file-name)
  (setq pe/folds-open
        (cons file-name
              (cl-remove-if
               (lambda (listed-file-name)
                 (string-prefix-p listed-file-name file-name))
               pe/folds-open))))

(defun pe/folds-remove (file-name)
  (let* (( parent
           (file-name-directory
            (directory-file-name
             file-name)))
         ( new-folds
           (cl-remove-if
            (lambda (listed-file-name)
              (string-prefix-p file-name listed-file-name))
            pe/folds-open))
         ( removed-folds
           (cl-set-difference pe/folds-open
                              new-folds
                              :test 'string-equal)))
    (setq pe/folds-open new-folds)
    (when (and parent
               (not (string-equal parent default-directory))
               (not (cl-find-if (lambda (file-name)
                                  (string-prefix-p parent file-name))
                                pe/folds-open)))
      (push parent pe/folds-open))
    removed-folds))

(defun pe/folds-restore ()
  (let ((old-folds pe/folds-open))
    (setq pe/folds-open nil)
    (cl-dolist (fold old-folds)
      (when (pe/goto-file fold nil t)
        (pe/unfold-prog)))))

;;; * Text

(defun pe/at-file-p ()
  (save-excursion
    (goto-char (line-beginning-position))
    (looking-at-p ".*[^/]$")))

(defun pe/at-directory-p ()
  (save-excursion
    (goto-char (line-beginning-position))
    (looking-at-p ".*/$")))

(cl-defun pe/print-tree
    (branch &optional (depth -1))
  (let (start)
    (cond ( (stringp branch)
            (insert (make-string depth ?\t)
                    branch
                    ?\n))
          ( t (when (>= depth 0)
                (insert (make-string depth ?\t)
                        (car branch) "/\n")
                (setq start (point)))
              (cl-dolist (item (cdr branch))
                (pe/print-tree item (1+ depth)))
              (when (and start (> (point) start))
                ;; (message "ran %s %s" start (point))
                (pe/make-hiding-overlay
                 (1- start) (1- (point))))
              ))))

(defun pe/get-filename ()
  "Return the filename at point."
  (save-excursion
    (cl-labels
        (( get-line-text ()
           (goto-char (line-beginning-position))
           (skip-chars-forward "\t ")
           (buffer-substring-no-properties
            (point) (line-end-position))))
      (let (( result (get-line-text)))
        (while (pe/up-element-prog)
          (setq result (concat (get-line-text) result)))
        (setq result (expand-file-name result))
        (when (file-directory-p result)
          (setq result (file-name-as-directory result)))
        result))))

(cl-defun pe/goto-file
    (file-name &optional on-each-semgent-function use-best-match)
  "Returns the position of the file, if it's found. Otherwise returns nil"
  (when (string-equal (expand-file-name file-name) default-directory)
    (cl-return-from pe/goto-file nil))
  (let* (( segments (split-string
                     (if (file-name-absolute-p file-name)
                         (if (string-prefix-p default-directory file-name)
                             (substring file-name (length default-directory))
                           (cl-return-from pe/goto-file))
                       file-name)
                     "/" t))
         ( init-pos (point))
         best-match
         next-round-start
         found)
    (goto-char (point-min))
    (save-match-data
      (cl-loop with limit
               for segment in segments
               for indent from 0
               do
               (when next-round-start
                 (goto-char next-round-start))
               (cond ( (and (cl-plusp indent)
                            (looking-at (concat (regexp-quote segment) "/")))
                       (setq next-round-start (match-end 0))
                       (setq best-match (point))
                       (cl-decf indent))
                     ( (re-search-forward
                        (format "^\t\\{%s\\}\\(?1:%s\\)[/\n]"
                                (int-to-string indent)
                                (regexp-quote segment))
                        limit t)
                       (setq next-round-start (match-end 0))
                       (setq limit (save-excursion
                                     (pe/forward-element)))
                       (setq best-match (match-beginning 1))
                       (when on-each-semgent-function
                         (save-excursion
                           (goto-char (match-beginning 1))
                           (funcall on-each-semgent-function))))
                     ( t (cl-return)))
               finally (setq found t)))
    (cl-assert (or (not found) (and found best-match)) nil
               "Found, without best-match, with file-name %s"
               file-name)
    (if (or found (and best-match use-best-match))
        (progn (goto-char best-match)
               (when found (point)))
      (goto-char init-pos)
      nil)))

(defun pe/user-get-filename ()
  "Return the aboslute file-name of the file at point.
Makes adjustments for folding."
  (save-excursion
    (goto-char (es-total-line-beginning))
    (pe/get-filename)))

(cl-defun pe/show-file-prog (&optional file-name)
  (let ((init-pos (point))
        (found (not file-name)))
    (and file-name
         (or (setq found (pe/goto-file file-name nil t))
             (cl-return-from pe/show-file-prog))
         (deactivate-mark))
    (save-excursion
      (when (pe/up-element-prog)
        (pe/unfold-prog)))
    ;; Fix for what looks like an emacs bug
    (when found
      (unless (posn-at-point)
        (recenter)))))

;;; ** Folding

(defun pe/make-hiding-overlay (from to)
  (let* (( ov (make-overlay from to))
         line-beginning
         ( indent (save-excursion
                    (goto-char from)
                    (setq line-beginning
                          (goto-char (line-beginning-position)))
                    (skip-chars-forward "\t")
                    (- (point) line-beginning)))
         ( priority (- 100 indent)))
    (mapc (apply-partially 'apply 'overlay-put ov)
          `((isearch-open-invisible-temporary
             pe/isearch-show-temporarily)
            (isearch-open-invisible pe/isearch-show)
            (invisible t)
            (display "...")
            (is-pe-hider t)
            (evaporate t)
            (priority ,priority)))
    ov))

(cl-defun pe/unfold-prog ()
  "Register current line as opened,\
and delete all overlays that might be hiding it.
Does nothing on an open line."
  (unless (pe/folded-p)
    (cl-return-from pe/unfold-prog))
  (save-excursion
    (or (pe/at-directory-p)
        (pe/up-element-prog)
        (cl-return-from pe/unfold-prog))
    (pe/folds-add (pe/get-filename))
    (mapc 'delete-overlay
          (cl-remove-if-not
           (lambda (ov)
             (overlay-get ov 'is-pe-hider))
           (overlays-at (line-end-position))
           ))))

(defun pe/folded-p ()
  "Will return t, at a folded directory, or a folded file."
  (let (( ovs (save-excursion
                (goto-char (es-total-line-beginning-position))
                (overlays-at (line-end-position)))))
    (cl-some (lambda (ov)
               (overlay-get ov 'is-pe-hider))
             ovs)))

(cl-defun pe/fold ()
  "Fold current directory. Will also fold any open subdirectories."
  (interactive)
  (when (or (looking-at-p ".*\n?\\'")   ; Last line
            (pe/folded-p)
            (not (pe/at-directory-p)))
    (cl-return-from pe/fold))
  (cl-labels (( fold-this-line ()
                (let* (( indent
                         (save-excursion
                           (goto-char (line-beginning-position))
                           (skip-chars-forward "\t")
                           (buffer-substring (line-beginning-position)
                                             (point))))
                       ( end
                         (save-excursion
                           (goto-char (line-end-position 1))
                           (let (( regex
                                   (format "^\t\\{0,%s\\}[^\t\n]"
                                           (length indent))))
                             (if (re-search-forward regex nil t)
                                 (line-end-position 0)
                               (point-max))))))
                  (pe/make-hiding-overlay (line-end-position 1)
                                          end))))
    (save-excursion
      (let* (( root (pe/user-get-filename))
             ( descendant-list (pe/folds-remove root))
             ( root-point (save-excursion (pe/goto-file root)))
             ( locations-to-fold (list root-point)))
        (cl-assert root-point nil
                   "pe/goto-file returned nil for %s"
                   root)
        (cl-dolist (path descendant-list)
          (cl-pushnew (pe/goto-file path) locations-to-fold)
          (cl-loop (pe/up-element)
                   (if (or (<= (point) root-point)
                           (memq (point) locations-to-fold))
                       (cl-return)
                     (cl-pushnew (point) locations-to-fold)))
          )
        (cl-dolist (location locations-to-fold)
          (goto-char location)
          (fold-this-line))
        ))))

(defun pe/fold-all ()
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^.+/$" nil t)
      (pe/fold))))

(defun pe/unfold-all ()
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^.+/$" nil t)
      (pe/unfold-descendants))))

(defun pe/unfold-descendants ()
  (save-excursion
    (goto-char (line-beginning-position))
    (let (( end (save-excursion (pe/forward-element))))
      (while (re-search-forward "/$" end t)
        (pe/unfold-prog)))))

;;; ** Navigation

(defun pe/forward-element (&optional arg)
  (interactive "p")
  (setq arg (or arg 1))
  (save-match-data
    (let* (( initial-indentation
             (es-current-character-indentation))
           ( regex (format "^\t\\{0,%s\\}[^\t\n]"
                           initial-indentation)))
      (if (cl-minusp arg)
          (goto-char (line-beginning-position))
        (goto-char (line-end-position)))
      (when (re-search-forward regex nil t arg)
        (goto-char (match-end 0))
        (forward-char -1)
        (point)))))

(defun pe/backward-element (&optional arg)
  (interactive "p")
  (setq arg (or arg 1))
  (pe/forward-element (- arg)))

(defun pe/up-element-prog ()
  "Go to the parent element, if there is such.
Returns the value of point if there has been movement. nil otherwise."
  (let (( indentation
          (es-current-character-indentation)))
    (and (cl-plusp indentation)
         (re-search-backward (format
                              "^\\(?1:\t\\{0,%s\\}\\)[^\t\n]"
                              (1- indentation))
                             nil t)
         (goto-char (match-end 1)))))

(defun pe/goto-top ()
  (interactive)
  (re-search-backward "^[^\t]" nil t))

;;; * Helm

(defvar pe/helm-buffer-max-length 30)

(defun pe/flatten-tree (tree &optional prefix)
  (let (( current-prefix
          (if prefix
              (concat prefix "/" (car tree))
            (car tree))))
    (cl-mapcan (lambda (it)
                 (if (consp it)
                     (pe/flatten-tree it current-prefix)
                   (list (concat current-prefix "/" it))))
               (cdr tree))))

(cl-defun pe/helm-candidates ()
  (with-current-buffer
      (pe/get-current-project-explorer-buffer)
    (let* (( visited-files
             (let (( buffer-list (remove helm-current-buffer (buffer-list))))
               (cl-remove-if (lambda (name)
                               (or (null name)
                                   (not (string-prefix-p default-directory
                                                         name))))
                             (mapcar 'buffer-file-name buffer-list))))
           ( get-fresh-data
             (lambda ()
               (cl-mapcan (lambda (it)
                            (if (consp it)
                                (mapcar (lambda (it2)
                                          (concat default-directory it2))
                                        (pe/flatten-tree it))
                              (list (concat default-directory it))))
                          (cdr pe/data))))
           ( flattened-file-list
             (cl-remove-if (lambda (file-name)
                             (or (string-match-p "/$" file-name)
                                 (member file-name visited-files)))
                           (or pe/helm-cache
                               (setq pe/helm-cache
                                     (funcall get-fresh-data)))))
           ( \default-directory-length
             (length default-directory))
           ( to-cons
             (lambda (highlight file-name)
               (cons (format "%s\t%s"
                             (progn
                               (let (( file-name-nondirectory
                                       (truncate-string-to-width
                                        (file-name-nondirectory
                                         file-name)
                                        pe/helm-buffer-max-length
                                        nil ?  t)))
                                 (if highlight
                                     (propertize file-name-nondirectory
                                                 'face
                                                 'font-lock-function-name-face)
                                   file-name-nondirectory)))
                             (progn
                               (propertize (substring file-name default-directory-length)
                                           'face 'font-lock-keyword-face)))
                     file-name))))
      (nconc (mapcar (apply-partially to-cons t)
                     visited-files)
             (mapcar (apply-partially to-cons nil)
                     flattened-file-list))
      )))

(eval-after-load 'helm-locate
  '(defvar pe/helm-source
    `(( name . "Project explorer")
      ( candidates . pe/helm-candidates)
      ( action . ,(cdr (helm-get-actions-from-type helm-source-locate)))
      ( no-delay-on-input)
      )))

(cl-defun project-explorer-helm ()
  "Browse the project using helm."
  (interactive)
  (require 'helm)
  (unless (pe/get-current-project-explorer-buffer)
    (let ((win-config (current-window-configuration)))
      (project-explorer-open)
      (unless (buffer-local-value 'pe/data (pe/get-current-project-explorer-buffer))
        (message "Helm will be available, once indexing is complete.")
        (cl-return-from project-explorer-helm))
      (set-window-configuration win-config)))
  (when (derived-mode-p 'project-explorer-mode)
    (select-window (car (cl-remove-if
                         (lambda (win)
                           (window-parameter win 'window-side))
                         (window-list)))))
  (helm :sources '(pe/helm-source)))

;;; * User functions

(defun pe/copy-file-name-as-kill ()
  (interactive)
  (let ((file-name (pe/user-get-filename)))
    (when (called-interactively-p 'any)
      (message "%s" file-name))
    (kill-new file-name)))

(defun pe/middle-click (event)
  (interactive "e")
  (mouse-set-point event)
  (pe/return))

(defun pe/left-click (event)
  (interactive "e")
  (and mouse-1-click-follows-link
       (save-excursion
         (mouse-set-point event)
         (looking-at-p "[^ \t\n]"))
       (pe/middle-click event)))

(defun pe/return ()
  (interactive)
  (if (file-directory-p (pe/user-get-filename))
      (pe/tab)
    (pe/find-file)))

(defun pe/find-file ()
  "Open the file or directory at point."
  (interactive)
  (let ((file-name (pe/user-get-filename)))
    (pe/show-buffer
     (find-file-noselect file-name))))

(defun pe/unfold (&optional expanded)
  "For interactive use only. Use `pe/unfold-prog' in code."
  (interactive "P")
  (let (( line-beginning
          (es-total-line-beginning-position)))
    (when (/= (line-number-at-pos)
              (line-number-at-pos
               line-beginning))
      (goto-char line-beginning)
      ;; Putting the cursor right at the beginning of a fold, may cause
      ;; unexpected behaviour. "-1" makes it less likely.
      (goto-char (1- (line-end-position)))
      ))
  (cond ( expanded
          (pe/unfold-descendants))
        ( (not (pe/folded-p)))
        ( t (pe/unfold-prog))))

(defun pe/up-element ()
  "Goto the parent element of the file at point.
Joined directories will be traversed as one. In programs use
 `pe/up-element-prog' instead."
  (interactive)
  (goto-char (es-total-line-beginning-position))
  (pe/up-element-prog))

(defun pe/tab (&optional arg)
  "Toggle folding at point.
With a prefix argument, unfold all children."
  (interactive "P")
  (if (or arg (pe/folded-p))
      (pe/unfold arg)
    (pe/fold)))

;;; * Minor mode integration

(defun pe/hl-line-range ()
  (save-excursion
    (cons (progn
            (forward-visible-line 0)
            (point))
          (progn
            (forward-visible-line 1)
            (point))
          )))

;;; * File management

(defun pe/create-file (file-name)
  "If FILE-NAME ends with a /, create a directory.
Otherwise an empty file."
  (interactive
   (let (( root (or (when (pe/at-directory-p)
                      (pe/user-get-filename))
                    (save-excursion
                      (when (pe/up-element-prog)
                        (pe/user-get-filename)))
                    default-directory)))
     (list (read-file-name "Create file: " root nil))))
  (cl-assert pe/data)
  (cl-assert (not (file-exists-p file-name)))
  (let* (( is-directory (string-match-p "/$" file-name))
         ( was-reverting
           (prog1 pe/reverting
             (when pe/reverting
               (funcall (get pe/directory-tree-function 'pe/cancel))
               (setq pe/reverting nil)))))

    (if is-directory
        (make-directory (directory-file-name file-name))
      (with-temp-buffer
        (write-region nil nil file-name nil 'silent nil 'excl)))

    (pe/data-add file-name)
    (pe/set-tree nil 'refresh pe/data)
    (pe/show-file-prog file-name)
    (when was-reverting
      (pe/revert-buffer))))

(cl-defun pe/delete-file (file-name)
  (interactive (list (pe/user-get-filename)))
  (cl-assert pe/data)
  (cl-assert (file-exists-p file-name))
  (let* (( is-directory (string-match-p "/$" file-name))
         ( point (point))
         ( was-reverting
           (prog1 pe/reverting
             (when pe/reverting
               (funcall (get pe/directory-tree-function 'pe/cancel))
               (setq pe/reverting nil)))))

    (unless (or (not pe/confirm-delete)
                (y-or-n-p (format "Delete %s?"
                                  (file-name-nondirectory
                                   (directory-file-name file-name)))))
      (cl-return-from pe/delete-file))

    (if is-directory
        (delete-directory file-name t t)
      (delete-file file-name t))

    (pe/data-delete file-name)
    (pe/set-tree nil 'refresh pe/data)
    (goto-char (max (point-min) (min (point-max) point)))
    (pe/goto-file (pe/get-filename))
    (when was-reverting
      (pe/revert-buffer))
    ))

(cl-defun pe/rename-file (file-name new-file-name)
  (interactive (list (pe/user-get-filename)
                     (read-file-name "Rename to: "
                                     (file-name-directory
                                      (directory-file-name
                                       (pe/user-get-filename)))
                                     nil nil
                                     (file-name-nondirectory
                                      (directory-file-name
                                       (pe/user-get-filename))))))
  (cl-assert pe/data)
  (cl-assert (file-exists-p file-name))

  (setq file-name (directory-file-name file-name))
  (let* (( is-directory (file-directory-p file-name))
         ( point (point))
         ( file-name-data (pe/data-get file-name))
         ( was-reverting
           (prog1 pe/reverting
             (when pe/reverting
               (funcall (get pe/directory-tree-function 'pe/cancel))
               (setq pe/reverting nil)))))

    (rename-file file-name new-file-name 1)

    (pe/data-delete file-name)
    (pe/data-add new-file-name file-name-data)
    (pe/set-tree nil 'refresh pe/data)
    (pe/show-file-prog new-file-name)
    (when was-reverting
      (pe/revert-buffer))
    ))

(cl-defun pe/copy-file (file-name new-file-name)
  (interactive (list (pe/user-get-filename)
                     (read-file-name "Rename to: "
                                     (file-name-directory
                                      (directory-file-name
                                       (pe/user-get-filename)))
                                     nil nil
                                     (file-name-nondirectory
                                      (directory-file-name
                                       (pe/user-get-filename))))))
  (cl-assert pe/data)
  (cl-assert (file-exists-p file-name))

  (setq file-name (directory-file-name file-name))
  (let* (( is-directory (file-directory-p file-name))
         ( point (point))
         ( file-name-data (pe/data-get file-name))
         ( was-reverting
           (prog1 pe/reverting
             (when pe/reverting
               (funcall (get pe/directory-tree-function 'pe/cancel))
               (setq pe/reverting nil)))))

    (copy-file file-name new-file-name 1)

    (pe/data-add new-file-name file-name-data)
    (pe/set-tree nil 'refresh pe/data)
    (pe/show-file-prog new-file-name)
    (when was-reverting
      (pe/revert-buffer))
    ))

;;; ** Isearch

(defun pe/isearch-show (ov)
  (save-excursion
    (goto-char (overlay-start ov))
    (pe/folds-add (pe/get-filename))
    (delete-overlay ov)))

(defun pe/isearch-show-temporarily (ov do-hide)
  (overlay-put ov 'display (when do-hide "..."))
  (overlay-put ov 'invisible do-hide))


;;; ** Occur

(defadvice occur-mode (after pe/try-matching-tab-width activate)
  (and (boundp 'buf-name)
       (boundp 'bufs)
       (consp bufs)
       (= 1 (length bufs))
       (with-current-buffer (car bufs)
         (derived-mode-p 'project-explorer-mode))
       (with-current-buffer buf-name
         (setq-local tab-width (buffer-local-value 'tab-width (car bufs))))))

(defun pe/occur-mode-find-occurrence-hook ()
  (save-excursion
    (pe/up-element-prog)
    (pe/unfold-prog)))

;;; * Window managment

(defun pe/quit ()
  (interactive)
  (let ((window (selected-window)))
    (quit-window)
    (when (window-live-p window)
      (delete-window))))

(defun pe/show-file (&optional file-name)
  "Show `file-name', in the associated project-explorer buffer.
File name defaults to `buffer-file-name'"
  (interactive)
  (let* (( error-message
           "The buffer is not associated with a file")
         ( file-name
           (expand-file-name
            (or file-name
                (buffer-file-name)
                (when (derived-mode-p 'dired-mode)
                  (dired-current-directory))
                (if (called-interactively-p 'interactive)
                    (user-error error-message)
                  (error error-message))))))
    (project-explorer-open)
    (pe/show-file-prog file-name)))

(defun pe/get-current-project-explorer-buffer ()
  (let (( project-root (funcall pe/project-root-function))
        ( project-explorer-buffers (pe/get-project-explorer-buffers)))
    (cl-find project-root
             project-explorer-buffers
             :key (apply-partially 'buffer-local-value 'pe/project-root)
             :test 'string-equal)))

(defun pe/show-buffer-in-side-window (buffer)
  (let* (( project-explorer-buffers
           (pe/get-project-explorer-buffers))
         ( --clean-up--
           (mapc (lambda (win)
                   (and (memq (window-buffer win) project-explorer-buffers)
                        (not (window-parameter win 'window-side))
                        (eq t (window-deletable-p win))
                        (delete-window win)))
                 (window-list)))
         ( existing-window
           (cl-find-if
            (lambda (window)
              (and (memq (window-buffer window) project-explorer-buffers)
                   (window-parameter window 'window-side)))
            (window-list)))
         ( window
           (or existing-window
               (display-buffer-in-side-window
                buffer
                `((side . ,pe/side)
                  )))))
    (when existing-window
      (setf (window-dedicated-p window) nil
            (window-buffer window) buffer))
    (setf (window-dedicated-p window) t)
    (unless existing-window
      (es-set-window-body-width window pe/width))
    (select-window window)
    window))

(defun pe/show-buffer (buffer)
  (let* (( non-side-windows
           (cl-remove-if
            (lambda (win)
              (window-parameter win 'window-side))
            (window-list)))
         ( existing
           (cl-find-if (lambda (win)
                         (not (window-dedicated-p win)))
                       non-side-windows))
         ( window
           (or existing
               (split-window (car non-side-windows)
                             nil 'left))))
    (select-window window)
    (setf (window-buffer window) buffer)))

(defun pe/get-project-explorer-buffers ()
  (es-buffers-with-mode 'project-explorer-mode))

;;; * Core

(defun pe/set-tree (buffer type data)
  "Called after data retrieval is complete.
Redraws the tree based on DATA. Will try to restore folds, if TYPE is
`refresh'. Saves data to cache, if caching is enabled."
  (cl-assert (memq type '(refresh directory-change)))
  (setq buffer (or buffer (current-buffer)))
  (let ((user-buffer (current-buffer)))
    (with-selected-window
        (or (get-buffer-window buffer)
            (selected-window))
      (with-current-buffer buffer
        (let* (( window-start (window-start))
               ( starting-column (current-column))
               ( starting-name
                 (and pe/data
                      (let ((\default-directory
                             (or pe/previous-directory
                                 default-directory)))
                        (pe/get-filename)))))

          (cl-assert pe/project-root)

          (setq pe/data data)

          (when pe/cache-enabled
            (pe/cache-save))

          (let ((inhibit-read-only t))
            (erase-buffer)
            (delete-all-overlays)
            (pe/print-tree (funcall (if pe/inline-folders
                                        'pe/compress-tree
                                      'identity)
                                    (pe/sort data)))
            (font-lock-fontify-buffer)
            (goto-char (point-min)))

          (cl-case type
            ( refresh
              (pe/folds-restore)
              (when (get-buffer-window buffer)
                (set-window-start nil window-start))
              (and starting-name
                   (pe/goto-file starting-name nil t)
                   (move-to-column starting-column)))
            ( directory-change
              (when (get-buffer-window buffer)
                (set-window-start nil (point-min)))
              (setq pe/folds-open nil)
              (when pe/goto-current-file-on-open
                (let (( file-name
                        (or (with-current-buffer user-buffer
                              (if (derived-mode-p 'dired-mode)
                                  (expand-file-name
                                   (dired-current-directory))
                                (when (buffer-file-name)
                                  (expand-file-name
                                   (buffer-file-name)))))
                            pe/origin-file-name)))
                  (when file-name
                    (pe/show-file-prog file-name))
                  ))))

          (setq pe/previous-directory default-directory
                pe/origin-file-name nil
                pe/helm-cache nil
                pe/reverting nil)
          )))))

(cl-defun pe/revert-buffer (&rest ignore)
  (when pe/reverting
    (if (get pe/directory-tree-function 'pe/cancel)
        (if (y-or-n-p "A refresh is already in progress. Cancel it?")
            (funcall (get pe/directory-tree-function 'pe/cancel))
          (cl-return-from pe/revert-buffer))
      (user-error "Revert already in progress")))
  (setq pe/reverting t)
  (funcall pe/directory-tree-function
           default-directory
           (apply-partially 'pe/set-tree (current-buffer) 'refresh)))

(define-derived-mode project-explorer-mode special-mode
    "Project explorer"
    nil
  (setq-local revert-buffer-function
              'pe/revert-buffer)
  (setq-local tab-width 2)
  (setq-local hl-line-range-function
              'pe/hl-line-range)

  (add-hook 'occur-mode-find-occurrence-hook
            'pe/occur-mode-find-occurrence-hook
            nil t)
  (face-remap-add-relative 'default 'pe/file-face)
  (font-lock-add-keywords
   'project-explorer-mode '(("^.+/$" (0 'pe/directory-face append))))

  (when pe/mode-line-format
    (setq-local mode-line-format
                pe/mode-line-format))

  (es-define-keys project-explorer-mode-map
    (kbd "+") 'pe/create-file
    (kbd "-") 'pe/delete-file
    (kbd "d") 'pe/delete-file
    (kbd "u") 'pe/up-element
    (kbd "a") 'pe/goto-top
    (kbd "TAB") 'pe/tab
    (kbd "M-}") 'pe/forward-element
    (kbd "M-{") 'pe/backward-element
    (kbd "]") 'pe/forward-element
    (kbd "[") 'pe/backward-element
    (kbd "n") 'next-line
    (kbd "p") 'previous-line
    (kbd "j") 'next-line
    (kbd "k") 'previous-line
    (kbd "l") 'forward-char
    (kbd "h") 'backward-char
    ;; (kbd "^") 'pe/up-directory
    (kbd "RET") 'pe/return
    (kbd "<mouse-2>") 'pe/middle-click
    (kbd "<mouse-1>") 'pe/left-click
    (kbd "q") 'pe/quit
    (kbd "s") 'pe/change-directory
    (kbd "r") 'pe/rename-file
    (kbd "c") 'pe/copy-file
    (kbd "f") 'pe/find-file
    (kbd "w") 'pe/copy-file-name-as-kill))

(cl-defun pe/change-directory (dir)
  "Changes the root directory of the project explorer.
The buffer will remain attached to it's project, even if the new directory is
outside of the project's root."
  (interactive
   (let ((file-name (pe/user-get-filename)))
     (list (read-file-name
            "Set directory to: "
            (if (file-directory-p file-name)
                file-name
              (file-name-directory
               (directory-file-name
                file-name)))))))
  (unless (file-directory-p dir)
    (funcall (if (called-interactively-p 'any)
                 'user-error 'error)
             "\"%s\" is not a directory" dir))

  (and pe/reverting
       (get pe/directory-tree-function
            'pe/cancel)
       (funcall (get pe/directory-tree-function
                     'pe/cancel)))

  (setq dir (file-name-as-directory dir)
        default-directory (expand-file-name dir))

  (let (( inhibit-read-only t)
        ( cache (and pe/cache-enabled
                     (pe/cache-load))))
    (erase-buffer)
    (delete-all-overlays)
    (if cache
        (progn
          (setq pe/data cache)
          (pe/set-tree nil 'directory-change pe/data))
      (setq pe/data nil)
      (insert "Searching for files..."))

    (when (or (not cache)
              (and (get pe/directory-tree-function
                        'pe/async)
                   pe/auto-refresh-cache))
      (setq pe/reverting t)
      (funcall pe/directory-tree-function
               default-directory
               (apply-partially 'pe/set-tree (current-buffer)
                                (if cache
                                    'refresh
                                  'directory-change))))))

(cl-defun project-explorer-open ()
  "Show or create the project explorer for the current project."
  (interactive)
  (let* (( origin-file-name
           (if (derived-mode-p 'dired-mode)
               (expand-file-name
                (dired-current-directory))
             (when (buffer-file-name)
               (expand-file-name
                (buffer-file-name)))))
         ( project-root (funcall pe/project-root-function))
         ( project-explorer-buffer
           (or (pe/get-current-project-explorer-buffer)
               (with-current-buffer
                   (generate-new-buffer " *project-explorer*")
                 (project-explorer-mode)
                 (setq default-directory
                       (setq pe/project-root
                             project-root))
                 (setq pe/origin-file-name origin-file-name)
                 (pe/change-directory default-directory)
                 (current-buffer)
                 ))))
    (pe/show-buffer-in-side-window project-explorer-buffer)
    (when (and origin-file-name
               pe/goto-current-file-on-open
               (buffer-local-value 'pe/data project-explorer-buffer))
      (with-current-buffer project-explorer-buffer
        (pe/show-file-prog origin-file-name)))
    project-explorer-buffer))

(provide 'project-explorer)

;; Local Variables:
;; eval: (orgstruct-mode)
;; eval: (hi-lock-mode)
;; orgstruct-heading-prefix-regexp: "^;;; \\*"
;; End:

;;; project-explorer.el ends here
