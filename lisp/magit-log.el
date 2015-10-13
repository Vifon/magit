;;; magit-log.el --- inspect Git history

;; Copyright (C) 2010-2015  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; This library implements support for looking at Git logs, including
;; special logs like reflogs and cherry-logs, as well as for selecting
;; a commit from a log.

;;; Code:

(require 'magit-core)
(require 'magit-diff)

(declare-function magit-blame-chunk-get 'magit-blame)
(declare-function magit-blob-visit 'magit)
(declare-function magit-find-file-noselect 'magit)
(declare-function magit-insert-head-header 'magit)
(declare-function magit-insert-upstream-header 'magit)
(declare-function magit-read-file-from-rev 'magit)
(declare-function magit-show-commit 'magit)
(defvar magit-blame-mode)
(defvar magit-refs-indent-cherry-lines)
(defvar magit-refs-show-commit-count)

(require 'ansi-color)
(require 'crm)

;;; Options
;;;; Log Mode

(defgroup magit-log nil
  "Inspect and manipulate Git history."
  :group 'magit-modes)

(defcustom magit-log-mode-hook nil
  "Hook run after entering Magit-Log mode."
  :group 'magit-log
  :type 'hook)

(defcustom magit-log-arguments '("-n256" "--graph" "--decorate")
  "The log arguments used in `magit-log-mode' buffers."
  :package-version '(magit . "2.3.0")
  :group 'magit-log
  :group 'magit-commands
  :type '(repeat (string :tag "Argument")))

(defcustom magit-log-remove-graph-args '("--follow" "--grep" "-G" "-S" "-L")
  "The log arguments that cause the `--graph' argument to be dropped."
  :package-version '(magit . "2.3.0")
  :group 'magit-log
  :type '(repeat (string :tag "Argument"))
  :options '("--follow" "--grep" "-G" "-S" "-L"))

(defcustom magit-log-revision-headers-format "\
%+b
Author:    %aN <%aE>
Committer: %cN <%cE>"
  "Additional format string used with the `++header' argument."
  :package-version '(magit . "2.3.0")
  :group 'magit-log
  :type 'string)

(defcustom magit-log-auto-more nil
  "Insert more log entries automatically when moving past the last entry.
Only considered when moving past the last entry with
`magit-goto-*-section' commands."
  :group 'magit-log
  :type 'boolean)

(defcustom magit-log-format-graph-function 'identity
  "Function used to format graphs in log buffers.
The function is called with one argument, the graph of a single
line as a propertized string.  It has to return the formatted
string.  Use `identity' to forgo changing the graph."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type '(choice (function-item identity)
                 (function-item magit-log-format-unicode-graph)
                 function))

(defcustom magit-log-format-unicode-graph-alist
  '((?/ . ?╱) (?| . ?│) (?\\ . ?╲) (?* . ?◆) (?o . ?◇))
  "Alist used by `magit-log-format-unicode-graph' to translate chars."
  :package-version '(magit . "1.4.0")
  :group 'magit-log
  :type '(repeat (cons :format "%v\n"
                       (character :format "replace %v ")
                       (character :format "with %v"))))

(defcustom magit-log-show-margin t
  "Whether to initially show the margin in log buffers.

When non-nil the author name and date are initially displayed in
the margin of log buffers.  The margin can be shown or hidden in
the current buffer using the command `magit-toggle-margin'.  In
status buffers this option is ignored but it is possible to show
the margin using the mentioned command."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type 'boolean)

(defcustom magit-duration-spec
  `((?Y "year"   "years"   ,(round (* 60 60 24 365.2425)))
    (?M "month"  "months"  ,(round (* 60 60 24 30.436875)))
    (?w "week"   "weeks"   ,(* 60 60 24 7))
    (?d "day"    "days"    ,(* 60 60 24))
    (?h "hour"   "hours"   ,(* 60 60))
    (?m "minute" "minutes" 60)
    (?s "second" "seconds" 1))
  "Units used to display durations in a human format.
The value is a list of time units, beginning with the longest.
Each element has the form (CHAR UNIT UNITS SECONDS).  UNIT is the
time unit, UNITS is the plural of that unit.  CHAR is a character
abbreviation.  And SECONDS is the number of seconds in one UNIT.
Also see option `magit-log-margin-spec'."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type '(repeat (list (character :tag "Unit character")
                       (string    :tag "Unit singular string")
                       (string    :tag "Unit plural string")
                       (integer   :tag "Seconds in unit"))))

(defcustom magit-log-margin-spec '(28 7 magit-duration-spec)
  "How to format the log margin.

The log margin is used to display each commit's author followed
by the commit's age.  This option controls the total width of the
margin and how time units are formatted, the value has the form:

  (WIDTH UNIT-WIDTH DURATION-SPEC)

WIDTH specifies the total width of the log margin.  UNIT-WIDTH is
either the integer 1, in which case time units are displayed as a
single characters, leaving more room for author names; or it has
to be the width of the longest time unit string in DURATION-SPEC.
DURATION-SPEC has to be a variable, its value controls which time
units, in what language, are being used."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :set-after '(magit-duration-spec)
  :type '(list (integer  :tag "Margin width")
               (choice   :tag "Time unit style"
                         (const   :format "%t\n"
                                  :tag "abbreviate to single character" 1)
                         (integer :format "%t\n"
                                  :tag "show full name" 7))
               (variable :tag "Duration spec variable")))

(defcustom magit-log-show-refname-after-summary nil
  "Whether to show refnames after commit summaries.
This is useful if you use really long branch names."
  :package-version '(magit . "2.2.0")
  :group 'magit-log
  :type 'boolean)

(defface magit-log-graph
  '((((class color) (background light)) :foreground "grey30")
    (((class color) (background  dark)) :foreground "grey80"))
  "Face for the graph part of the log output."
  :group 'magit-faces)

(defface magit-log-author
  '((((class color) (background light)) :foreground "firebrick")
    (((class color) (background  dark)) :foreground "tomato"))
  "Face for the author part of the log output."
  :group 'magit-faces)

(defface magit-log-date
  '((((class color) (background light)) :foreground "grey30")
    (((class color) (background  dark)) :foreground "grey80"))
  "Face for the date part of the log output."
  :group 'magit-faces)

;;;; Select Mode

(defcustom magit-log-select-arguments '("-n256" "--decorate")
  "The log arguments used in `magit-log-select-mode' buffers."
  :package-version '(magit . "2.3.0")
  :group 'magit-log
  :type '(repeat (string :tag "Argument")))

(defcustom magit-log-select-show-usage 'both
  "Whether to show usage information when selecting a commit from a log.
The message can be shown in the `echo-area' or the `header-line', or in
`both' places.  If the value isn't one of these symbols, then it should
be nil, in which case no usage information is shown."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type '(choice (const :tag "in echo-area" echo-area)
                 (const :tag "in header-line" header-line)
                 (const :tag "in both places" both)
                 (const :tag "nowhere")))

;;;; Cherry Mode

(defcustom magit-cherry-sections-hook
  '(magit-insert-cherry-headers
    magit-insert-cherry-commits)
  "Hook run to insert sections into the cherry buffer."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type 'hook)

;;;; Reflog Mode

(defcustom magit-reflog-arguments '("-n256")
  "The log arguments used in `magit-reflog-mode' buffers."
  :package-version '(magit . "2.3.0")
  :group 'magit-log
  :group 'magit-commands
  :type '(repeat (string :tag "Argument")))

(defcustom magit-reflog-show-margin t
  "Whether to initially show the margin in reflog buffers.

When non-nil the author name and date are initially displayed in
the margin of reflog buffers.  The margin can be shown or hidden
in the current buffer using the command `magit-toggle-margin'."
  :package-version '(magit . "2.1.0")
  :group 'magit-log
  :type 'boolean)

(defface magit-reflog-commit '((t :foreground "green"))
  "Face for commit commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-amend '((t :foreground "magenta"))
  "Face for amend commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-merge '((t :foreground "green"))
  "Face for merge, checkout and branch commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-checkout '((t :foreground "blue"))
  "Face for checkout commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-reset '((t :foreground "red"))
  "Face for reset commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-rebase '((t :foreground "magenta"))
  "Face for rebase commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-cherry-pick '((t :foreground "green"))
  "Face for cherry-pick commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-remote '((t :foreground "cyan"))
  "Face for pull and clone commands in reflogs."
  :group 'magit-faces)

(defface magit-reflog-other '((t :foreground "cyan"))
  "Face for other commands in reflogs."
  :group 'magit-faces)

;;;; Log Sections

(defcustom magit-log-section-commit-count 10
  "How many recent commits to show in certain log sections.
How many recent commits `magit-insert-recent-commits' and
`magit-insert-unpulled-or-recent-commits' (provided there
are no unpulled commits) show."
  :package-version '(magit . "2.1.0")
  :group 'magit-status
  :type 'number)

(defcustom magit-log-section-arguments '("--decorate")
  "The log arguments used in buffers that show other things besides logs."
  :package-version '(magit . "2.2.0")
  :group 'magit-log
  :group 'magit-status
  :type '(repeat (string :tag "Argument")))

(define-obsolete-variable-alias 'magit-log-section-args
  'magit-log-section-arguments "2.2.0")

;;; Commands

(defvar magit-log-popup
  '(:variable magit-log-arguments
    :man-page "git-log"
    :switches ((?g "Show graph"              "--graph")
               (?c "Show graph in color"     "--color")
               (?d "Show refnames"           "--decorate")
               (?S "Show signatures"         "--show-signature")
               (?u "Show diffs"              "--patch")
               (?s "Show diffstats"          "--stat")
               (?h "Show header"             "++header")
               (?D "Simplify by decoration"  "--simplify-by-decoration")
               (?f "Follow renames when showing single-file log" "--follow"))
    :options  ((?n "Limit number of commits" "-n"        read-from-minibuffer)
               (?f "Limit to files"          "-- "       magit-read-files)
               (?a "Limit to author"         "--author=" read-from-minibuffer)
               (?g "Search messages"         "--grep="   read-from-minibuffer)
               (?G "Search changes"          "-G"        read-from-minibuffer)
               (?S "Search occurences"       "-S"        read-from-minibuffer)
               (?L "Trace line evolution"    "-L"        magit-read-file-trace))
    :actions  ((?l "Log current"             magit-log-current)
               (?L "Log local branches"      magit-log-branches)
               (?r "Reflog current"          magit-reflog-current)
               (?o "Log other"               magit-log)
               (?b "Log all branches"        magit-log-all-branches)
               (?O "Reflog other"            magit-reflog)
               (?h "Log HEAD"                magit-log-head)
               (?a "Log all references"      magit-log-all)
               (?H "Reflog HEAD"             magit-reflog-head))
    :default-action magit-log-current
    :max-action-columns 3))

(defvar magit-log-mode-refresh-popup
  '(:variable magit-log-arguments
    :man-page "git-log"
    :switches ((?g "Show graph"              "--graph")
               (?c "Show graph in color"     "--color")
               (?d "Show refnames"           "--decorate")
               (?S "Show signatures"         "--show-signature")
               (?u "Show diffs"              "--patch")
               (?s "Show diffstats"          "--stat")
               (?D "Simplify by decoration"  "--simplify-by-decoration")
               (?f "Follow renames when showing single-file log" "--follow"))
    :options  ((?n "Limit number of commits" "-n"        read-from-minibuffer)
               (?f "Limit to files"          "-- "       magit-read-files)
               (?a "Limit to author"         "--author=" read-from-minibuffer)
               (?g "Search messages"         "--grep="   read-from-minibuffer)
               (?G "Search changes"          "-G"        read-from-minibuffer)
               (?S "Search occurences"       "-S"        read-from-minibuffer)
               (?L "Trace line evolution"    "-L"        magit-read-file-trace))
    :actions  ((?g "Refresh"       magit-log-refresh)
               (?t "Toggle margin" magit-toggle-margin)
               (?s "Set defaults"  magit-log-set-default-arguments) nil
               (?w "Save defaults" magit-log-save-default-arguments))
    :max-action-columns 2))

(defvar magit-reflog-mode-refresh-popup
  '(:variable magit-reflog-arguments
    :man-page "git-reflog"
    :options  ((?n "Limit number of commits" "-n" read-from-minibuffer))))

(defvar magit-log-refresh-popup
  '(:variable magit-log-arguments
    :man-page "git-log"
    :switches ((?g "Show graph"          "--graph")
               (?c "Show graph in color" "--color")
               (?d "Show refnames"       "--decorate"))
    :actions  ((?g "Refresh"       magit-log-refresh)
               (?t "Toggle margin" magit-toggle-margin)
               (?s "Set defaults"  magit-log-set-default-arguments) nil
               (?w "Save defaults" magit-log-save-default-arguments))
    :max-action-columns 2))

(magit-define-popup-keys-deferred 'magit-log-popup)
(magit-define-popup-keys-deferred 'magit-log-mode-refresh-popup)
(magit-define-popup-keys-deferred 'magit-log-refresh-popup)

(defun magit-read-file-trace (&rest ignored)
  (let ((file  (magit-read-file-from-rev "HEAD" "File"))
        (trace (magit-read-string "Trace")))
    (if (string-match
         "^\\(/.+/\\|:[^:]+\\|[0-9]+,[-+]?[0-9]+\\)\\(:\\)?$" trace)
        (concat trace (or (match-string 2 trace) ":") file)
      (user-error "Trace is invalid, see man git-log"))))

(defun magit-log-arguments (&optional refresh)
  (cond ((memq magit-current-popup
               '(magit-log-popup magit-log-refresh-popup))
         (magit-popup-export-file-args magit-current-popup-args))
        ((derived-mode-p 'magit-log-mode)
         (list (nth 1 magit-refresh-args)
               (nth 2 magit-refresh-args)))
        (refresh
         (list magit-log-section-arguments nil))
        (t
         (-if-let (buffer (magit-mode-get-buffer 'magit-log-mode))
             (with-current-buffer buffer
               (list (nth 1 magit-refresh-args)
                     (nth 2 magit-refresh-args)))
           (list (default-value 'magit-log-arguments) nil)))))

(defun magit-log-popup (arg)
  "Popup console for log commands."
  (interactive "P")
  (let ((magit-log-refresh-popup
         (pcase major-mode
           (`magit-log-mode magit-log-mode-refresh-popup)
           (_               magit-log-refresh-popup)))
        (magit-log-arguments
         (-if-let (buffer (magit-mode-get-buffer 'magit-log-mode))
             (with-current-buffer buffer
               (magit-popup-import-file-args (nth 1 magit-refresh-args)
                                             (nth 2 magit-refresh-args)))
           (default-value 'magit-log-arguments))))
    (magit-invoke-popup 'magit-log-popup nil arg)))

(defun magit-log-refresh-popup (arg)
  "Popup console for changing log arguments in the current buffer."
  (interactive "P")
  (magit-log-refresh-assert)
  (let ((magit-log-refresh-popup
         (cond ((derived-mode-p 'magit-log-select-mode)
                magit-log-refresh-popup)
               ((derived-mode-p 'magit-log-mode)
                (let ((def (copy-sequence magit-log-refresh-popup)))
                  (plist-put def :switches (plist-get magit-log-popup :switches))
                  (plist-put def :options  (plist-get magit-log-popup :options))
                  def))
               (t
                magit-log-refresh-popup)))
        (magit-log-arguments
         (cond ((derived-mode-p 'magit-log-select-mode)
                (cadr magit-refresh-args))
               ((derived-mode-p 'magit-log-mode)
                (magit-popup-import-file-args (nth 1 magit-refresh-args)
                                              (nth 2 magit-refresh-args)))
               (t
                magit-log-section-arguments))))
    (magit-invoke-popup 'magit-log-refresh-popup nil arg)))

(defun magit-log-refresh (args files)
  "Set the local log arguments for the current buffer."
  (interactive (magit-log-arguments t))
  (magit-log-refresh-assert)
  (cond ((derived-mode-p 'magit-log-select-mode)
         (setcar (cdr magit-refresh-args) args))
        ((derived-mode-p 'magit-log-mode)
         (setcdr magit-refresh-args (list args files)))
        (t
         (setq-local magit-log-section-arguments args)))
  (magit-refresh))

(defun magit-log-set-default-arguments (args files)
  "Set the global log arguments for the current buffer."
  (interactive (magit-log-arguments t))
  (magit-log-refresh-assert)
  (cond ((derived-mode-p 'magit-log-select-mode)
         (customize-set-variable 'magit-log-select-arguments args)
         (setcar (cdr magit-refresh-args) args))
        ((derived-mode-p 'magit-log-mode)
         (customize-set-variable 'magit-log-arguments args)
         (setcdr magit-refresh-args (list args files)))
        (t
         (customize-set-variable 'magit-log-section-arguments args)
         (kill-local-variable    'magit-log-section-arguments)))
  (magit-refresh))

(defun magit-log-save-default-arguments (args files)
  "Set and save the global log arguments for the current buffer."
  (interactive (magit-log-arguments t))
  (magit-log-refresh-assert)
  (cond ((derived-mode-p 'magit-log-select-mode)
         (customize-save-variable 'magit-log-select-arguments args)
         (setcar (cdr magit-refresh-args) args))
        ((derived-mode-p 'magit-log-mode)
         (customize-save-variable 'magit-log-arguments args)
         (setcdr magit-refresh-args (list args files)))
        (t
         (customize-save-variable 'magit-log-section-arguments args)
         (kill-local-variable     'magit-log-section-arguments)))
  (magit-refresh))

(defun magit-log-refresh-assert ()
  (cond ((derived-mode-p 'magit-reflog-mode)
         (user-error "Cannot change log arguments in reflog buffers"))
        ((derived-mode-p 'magit-cherry-mode)
         (user-error "Cannot change log arguments in cherry buffers"))))

(defvar magit-log-read-revs-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map crm-local-completion-map)
    (define-key map "\s" 'self-insert-command)
    map))

(defun magit-log-read-revs (&optional use-current)
  (or (and use-current (--when-let (magit-get-current-branch) (list it)))
      (let* ((choose-completion-string-functions
              '(crm--choose-completion-string))
             (minibuffer-completion-table #'crm--collection-fn)
             (minibuffer-completion-confirm t)
             (crm-completion-table
              `(,@(and (file-exists-p (magit-git-dir "FETCH_HEAD"))
                       (list "FETCH_HEAD"))
                ,@(magit-list-branch-names)))
             (crm-separator "\\(\\.\\.\\.?\\|[, ]\\)")
             (default (or (magit-branch-or-commit-at-point)
                          (unless use-current
                            (magit-get-previous-branch))))
             (input (read-from-minibuffer
                     (format "Log rev,s%s: "
                             (if default (format " (%s)" default) ""))
                     nil magit-log-read-revs-map
                     nil 'magit-revision-history default)))
        (when (string-equal input "")
          (or (setq input default)
              (user-error "Nothing selected")))
        (split-string input "[, ]" t))))

;;;###autoload
(defun magit-log-current (revs &optional args files)
  "Show log for the current branch.
When `HEAD' is detached or with a prefix argument show log for
one or more revs read from the minibuffer."
  (interactive (cons (magit-log-read-revs t)
                     (magit-log-arguments)))
  (magit-log revs args files))

;;;###autoload
(defun magit-log (revs &optional args files)
  "Show log for one or more revs read from the minibuffer.
The user can input any revision or revisions separated by a
space, or even ranges, but only branches and tags, and a
representation of the commit at point, are available as
completion candidates."
  (interactive (cons (magit-log-read-revs)
                     (magit-log-arguments)))
  (magit-mode-setup #'magit-log-mode revs args files)
  (magit-log-goto-same-commit))

;;;###autoload
(defun magit-log-head (&optional args files)
  "Show log for `HEAD'."
  (interactive (magit-log-arguments))
  (magit-log (list "HEAD") args files))

;;;###autoload
(defun magit-log-branches (&optional args files)
  "Show log for all local branches and `HEAD'."
  (interactive (magit-log-arguments))
  (magit-log (if (magit-get-current-branch)
                 (list "--branches")
               (list "HEAD" "--branches"))
             args files))

;;;###autoload
(defun magit-log-all-branches (&optional args files)
  "Show log for all local and remote branches and `HEAD'."
  (interactive (magit-log-arguments))
  (magit-log (if (magit-get-current-branch)
                 (list "--branches" "--remotes")
               (list "HEAD" "--branches" "--remotes"))
             args files))

;;;###autoload
(defun magit-log-all (&optional args files)
  "Show log for all references and `HEAD'."
  (interactive (magit-log-arguments))
  (magit-log (if (magit-get-current-branch)
                 (list "--all")
               (list "HEAD" "--all"))
             args files))

;;;###autoload
(defun magit-log-buffer-file (&optional follow beg end)
  "Show log for the blob or file visited in the current buffer.
With a prefix argument or when `--follow' is part of
`magit-log-arguments', then follow renames."
  (interactive (if (region-active-p)
                   (list current-prefix-arg
                         (1- (line-number-at-pos (region-beginning)))
                         (1- (line-number-at-pos (region-end))))
                 (list current-prefix-arg)))
  (-if-let (file (magit-file-relative-name))
      (magit-mode-setup #'magit-log-mode
                        (list (or magit-buffer-refname
                                  (magit-get-current-branch) "HEAD"))
                        (let ((args (car (magit-log-arguments))))
                          (when (and follow (not (member "--follow" args)))
                            (push "--follow" args))
                          (when (and beg end)
                            (setq args (cons (format "-L%s,%s:%s" beg end file)
                                             (cl-delete "-L" args :test
                                                        'string-prefix-p)))
                            (setq file nil))
                          args)
                        (and file (list file)))
    (user-error "Buffer isn't visiting a file"))
  (magit-log-goto-same-commit))

;;;###autoload
(defun magit-reflog-current ()
  "Display the reflog of the current branch."
  (interactive)
  (magit-reflog (magit-get-current-branch)))

;;;###autoload
(defun magit-reflog (ref)
  "Display the reflog of a branch."
  (interactive (list (magit-read-local-branch-or-ref "Show reflog for")))
  (magit-mode-setup #'magit-reflog-mode ref magit-reflog-arguments))

;;;###autoload
(defun magit-reflog-head ()
  "Display the `HEAD' reflog."
  (interactive)
  (magit-reflog "HEAD"))

(defun magit-log-toggle-commit-limit ()
  "Toggle the number of commits the current log buffer is limited to.
If the number of commits is currently limited, then remove that
limit.  Otherwise set it to 256."
  (interactive)
  (magit-log-set-commit-limit (lambda (&rest _) nil)))

(defun magit-log-double-commit-limit ()
  "Double the number of commits the current log buffer is limited to."
  (interactive)
  (magit-log-set-commit-limit '*))

(defun magit-log-half-commit-limit ()
  "Half the number of commits the current log buffer is limited to."
  (interactive)
  (magit-log-set-commit-limit '/))

(defun magit-log-set-commit-limit (fn)
  (let* ((val (car (magit-log-arguments t)))
         (arg (--first (string-match "^-n\\([0-9]+\\)?$" it) val))
         (num (and arg (string-to-number (match-string 1 arg))))
         (num (if num (funcall fn num 2) 256)))
    (setq val (delete arg val))
    (setcar (cdr magit-refresh-args)
            (if (and num (> num 0))
                (cons (format "-n%i" num) val)
              val)))
  (magit-refresh))

(defun magit-log-get-commit-limit ()
  (--when-let (--first (string-match "^-n\\([0-9]+\\)?$" it)
                       (car (magit-log-arguments t)))
    (string-to-number (match-string 1 it))))

(defun magit-log-bury-buffer (&optional arg)
  "Bury the current buffer or the revision buffer in the same frame.
Like `magit-mode-bury-buffer' (which see) but with a negative
prefix argument instead bury the revision buffer, provided it
is displayed in the current frame."
  (interactive "p")
  (if (< arg 0)
      (let* ((buf (magit-mode-get-buffer 'magit-revision-mode))
             (win (and buf (get-buffer-window buf (selected-frame)))))
        (if win
            (with-selected-window win
              (with-current-buffer buf
                (magit-mode-bury-buffer (> (abs arg) 1))))
          (user-error "No revision buffer in this frame")))
    (magit-mode-bury-buffer (> arg 1))))

;;; Log Mode

(defvar magit-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-mode-map)
    (define-key map "\C-c\C-b" 'magit-go-backward)
    (define-key map "\C-c\C-f" 'magit-go-forward)
    (define-key map "=" 'magit-log-toggle-commit-limit)
    (define-key map "+" 'magit-log-double-commit-limit)
    (define-key map "-" 'magit-log-half-commit-limit)
    (define-key map "q" 'magit-log-bury-buffer)
    map)
  "Keymap for `magit-log-mode'.")

(define-derived-mode magit-log-mode magit-mode "Magit Log"
  "Mode for looking at Git log.

This mode is documented in info node `(magit)Log Buffer'.

\\<magit-mode-map>\
Type \\[magit-refresh] to refresh the current buffer.
Type \\[magit-visit-thing] or \\[magit-diff-show-or-scroll-up] \
to visit the commit at point.

Type \\[magit-branch-popup] to see available branch commands.
Type \\[magit-merge-popup] to merge the branch or commit at point.
Type \\[magit-cherry-pick-popup] to apply the commit at point.
Type \\[magit-reset] to reset HEAD to the commit at point.

\\{magit-log-mode-map}"
  :group 'magit-log
  (hack-dir-local-variables-non-file-buffer))

(defvar magit-log-disable-graph-hack-args
  '("-G" "--grep" "--author")
  "Arguments which disable the graph speedup hack.")

(defun magit-log-refresh-buffer (revs args files)
  (setq header-line-format
        (propertize
         (concat " Commits in " (mapconcat 'identity revs  " ")
                 (and files (concat " touching "
                                    (mapconcat 'identity files " "))))
         'face 'magit-header-line))
  (unless (= (length files) 1)
    (setq args (remove "--follow" args)))
  (when (--any-p (string-match-p
                  (concat "^" (regexp-opt magit-log-remove-graph-args)) it)
                 args)
    (setq args (remove "--graph" args)))
  (unless (member "--graph" args)
    (setq args (remove "--color" args)))
  (-when-let* ((limit (magit-log-get-commit-limit))
               (limit (* 2 limit)) ; increase odds for complete graph
               (count (and (= (length revs) 1)
                           (> limit 1024) ; otherwise it's fast enough
                           (setq revs (car revs))
                           (not (string-match-p "\\.\\." revs))
                           (not (member revs '("--all" "--branches")))
                           (-none-p (lambda (arg)
                                      (--any-p (string-prefix-p it arg)
                                               magit-log-disable-graph-hack-args))
                                    args)
                           (magit-git-string "rev-list" "--count"
                                             "--first-parent" args revs))))
    (setq revs (if (< (string-to-number count) limit)
                   revs
                 (format "%s~%s..%s" revs limit revs))))
  (magit-insert-section (logbuf)
    (magit-insert-log revs args files)))

(defun magit-insert-log (revs &optional args files)
  "Insert a log section.
Do not add this to a hook variable."
  (magit-git-wash (apply-partially #'magit-log-wash-log 'log)
    "log"
    (format "--format=%%h%s %s[%%aN][%%at]%%s%s"
            (if (member "--decorate" args) "%d" "")
            (if (member "--show-signature" args)
                (progn (setq args (remove "--show-signature" args)) "%G?")
              "")
            (if (member "++header" args)
                (if (member "--graph" (setq args (delete "++header" args)))
                    (concat "\n" magit-log-revision-headers-format "\n")
                  (concat "\n" magit-log-revision-headers-format "\n"))
              ""))
    (if (member "--decorate" args)
        (cons "--decorate=full" (remove "--decorate" args))
      args)
    "--use-mailmap" "--no-prefix" revs "--" files))

(defvar magit-commit-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit-visit-thing] 'magit-show-commit)
    (define-key map "a" 'magit-cherry-apply)
    (define-key map "v" 'magit-revert-no-commit)
    map)
  "Keymap for `commit' sections.")

(defvar magit-module-commit-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit-visit-thing] 'magit-show-commit)
    map)
  "Keymap for `module-commit' sections.")

(defconst magit-log-heading-re
  (concat "^"
          "\\(?4:[-_/|\\*o. ]*\\)"                 ; graph
          "\\(?1:[0-9a-fA-F]+\\) "                 ; sha1
          "\\(?:\\(?3:([^()]+)\\) \\)?"            ; refs
          "\\(?7:[BGUN]\\)?"                       ; gpg
          "\\[\\(?5:[^]]*\\)\\]"                   ; author
          "\\[\\(?6:[^]]*\\)\\]"                   ; date
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit-log-cherry-re
  (concat "^"
          "\\(?8:[-+]\\) "                         ; cherry
          "\\(?1:[0-9a-fA-F]+\\) "                 ; sha1
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit-log-module-re
  (concat "^"
          "\\(?:\\(?11:[<>]\\) \\)?"               ; side
          "\\(?1:[0-9a-fA-F]+\\) "                 ; sha1
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit-log-bisect-vis-re
  (concat "^"
          "\\(?1:[0-9a-fA-F]+\\) "                 ; sha1
          "\\(?:\\(?3:([^()]+)\\) \\)?"            ; refs
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit-log-bisect-log-re
  (concat "^# "
          "\\(?3:bad:\\|skip:\\|good:\\) "         ; "refs"
          "\\[\\(?1:[^]]+\\)\\] "                  ; sha1
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit-log-reflog-re
  (concat "^"
          "\\(?1:[^ ]+\\) "                        ; sha1
          "\\(?:\\(?:[^@]+@{\\(?6:[^}]+\\)} "      ; date
          "\\(?10:merge \\|autosave \\|restart \\|[^:]+: \\)?" ; refsub
          "\\(?2:.*\\)?\\)\\| \\)$"))              ; msg

(defconst magit-reflog-subject-re
  (concat "\\(?1:[^ ]+\\) ?"                       ; command
          "\\(?2:\\(?: ?-[^ ]+\\)+\\)?"            ; option
          "\\(?: ?(\\(?3:[^)]+\\))\\)?"))          ; type

(defconst magit-log-stash-re
  (concat "^"
          "\\(?1:[^ ]+\\)"                         ; "sha1"
          "\\(?5: \\)"                             ; "author"
          "\\(?6:[^ ]+\\) "                        ; date
          "\\(?2:.*\\)$"))                         ; msg

(defvar magit-log-count nil)

(defun magit-log-wash-log (style args)
  (setq args (-flatten args))
  (when (and (member "--graph" args)
             (member "--color" args))
    (let ((ansi-color-apply-face-function
           (lambda (beg end face)
             (put-text-property beg end 'font-lock-face
                                (or face 'magit-log-graph)))))
      (ansi-color-apply-on-region (point-min) (point-max))))
  (when (eq style 'cherry)
    (reverse-region (point-min) (point-max)))
  (let ((magit-log-count 0)
        (abbrev (magit-abbrev-length)))
    (magit-wash-sequence (apply-partially 'magit-log-wash-rev style abbrev))
    (if (derived-mode-p 'magit-log-mode)
        (when (eq magit-log-count (magit-log-get-commit-limit))
          (magit-insert-section (longer)
            (insert-text-button
             (substitute-command-keys
              (format "Type \\<%s>\\[%s] to show more history"
                      'magit-log-mode-map
                      'magit-log-double-commit-limit))
             'action (lambda (button)
                       (magit-log-double-commit-limit))
             'follow-link t
             'mouse-face 'magit-section-highlight)))
      (unless (equal (car args) "cherry")
        (insert ?\n)))))

(defun magit-log-wash-rev (style abbrev)
  (when (derived-mode-p 'magit-log-mode)
    (cl-incf magit-log-count))
  (looking-at (pcase style
                (`log        magit-log-heading-re)
                (`cherry     magit-log-cherry-re)
                (`module     magit-log-module-re)
                (`reflog     magit-log-reflog-re)
                (`stash      magit-log-stash-re)
                (`bisect-vis magit-log-bisect-vis-re)
                (`bisect-log magit-log-bisect-log-re)))
  (magit-bind-match-strings
      (hash msg refs graph author date gpg cherry _ refsub side) nil
    (let ((align (not (member "--stat" (cadr magit-refresh-args)))))
      (magit-delete-line)
      (magit-insert-section section (commit hash)
        (pcase style
          (`stash      (setf (magit-section-type section) 'stash))
          (`module     (setf (magit-section-type section) 'module-commit))
          (`bisect-log (setq hash (magit-rev-parse "--short" hash))))
        (when cherry
          (when (and (derived-mode-p 'magit-refs-mode)
                     magit-refs-show-commit-count)
            (insert (make-string magit-refs-indent-cherry-lines ?\s)))
          (magit-insert cherry (if (string= cherry "-")
                                   'magit-cherry-equivalent
                                 'magit-cherry-unmatched) ?\s))
        (when side
          (magit-insert side (if (string= side "<")
                                 'magit-diff-removed
                               'magit-diff-added) ?\s))
        (when align
          (insert (propertize hash 'face 'magit-hash) ?\s))
        (when graph
          (insert (funcall magit-log-format-graph-function graph)))
        (unless align
          (insert (propertize hash 'face 'magit-hash) ?\s))
        (when (and refs (not magit-log-show-refname-after-summary))
          (magit-insert (magit-format-ref-labels refs) nil ?\s))
        (when refsub
          (insert (format "%-2s " (1- magit-log-count)))
          (magit-insert
           (magit-reflog-format-subject
            (substring refsub 0 (if (string-match-p ":" refsub) -2 -1)))))
        (when msg
          (magit-insert msg
                        (pcase (and gpg (aref gpg 0))
                          (?G 'magit-signature-good)
                          (?B 'magit-signature-bad)
                          (?U 'magit-signature-untrusted))))
        (when (and refs magit-log-show-refname-after-summary)
          (insert ?\s)
          (magit-insert (magit-format-ref-labels refs)))
        (insert ?\n)
        (when (memq style '(log reflog stash))
          (goto-char (line-beginning-position))
          (when (and refsub
                     (string-match "\\`\\([^ ]\\) \\+\\(..\\)\\(..\\)" date))
            (setq date (+ (string-to-number (match-string 1 date))
                          (* (string-to-number (match-string 2 date)) 60 60)
                          (* (string-to-number (match-string 3 date)) 60))))
          (save-excursion
            (backward-char)
            (magit-format-log-margin author date)))
        (when (and (eq style 'log)
                   (not (or (eobp) (looking-at magit-log-heading-re))))
          (when (looking-at "")
            (magit-insert-heading)
            (delete-char 1)
            (magit-insert-section (commit-header)
              (forward-line)
              (magit-insert-heading)
              (re-search-forward "")
              (backward-delete-char 1)
              (forward-char)
              (insert ?\n))
            (delete-char 1))
          (if (looking-at "^\\(---\\|\n\s\\|\ndiff\\)")
              (progn (unless (magit-section-content magit-insert-section--current)
                       (magit-insert-heading))
                     (delete-char (if (looking-at "\n") 1 4))
                     (magit-diff-wash-diffs (list "--stat")))
            (when align
              (setq align (make-string (1+ abbrev) ? )))
            (while (and (not (eobp)) (not (looking-at magit-log-heading-re)))
              (when align
                (setq align (make-string (1+ abbrev) ? )))
              (while (and (not (eobp)) (not (looking-at magit-log-heading-re)))
                (when align
                  (save-excursion (insert align)))
                (magit-format-log-margin)
                (forward-line))
              ;; When `--format' is used and its value isn't one of the
              ;; predefined formats, then `git-log' does not insert a
              ;; separator line.
              (save-excursion
                (forward-line -1)
                (looking-at "[-_/|\\*o. ]*"))
              (setq graph (match-string 0))
              (unless (string-match-p "[/\\]" graph)
                (insert graph ?\n))))))))
  t)

(defun magit-log-format-unicode-graph (string)
  "Translate ascii characters to unicode characters.
Whether that actually is an improvment depends on the unicode
support of the font in use.  The translation is done using the
alist in `magit-log-format-unicode-graph-alist'."
  (replace-regexp-in-string
   "[/|\\*o ]"
   (lambda (str)
     (propertize
      (string (or (cdr (assq (aref str 0)
                             magit-log-format-unicode-graph-alist))
                  (aref str 0)))
      'face (get-text-property 0 'face str)))
   string))

(defun magit-format-log-margin (&optional author date)
  (cl-destructuring-bind (width unit-width duration-spec)
      magit-log-margin-spec
    (when (and date (not author))
      (setq width (+ (if (= unit-width 1) 1 (1+ unit-width))
                     (if (derived-mode-p 'magit-log-mode) 1 0))))
    (if date
        (magit-make-margin-overlay
         (and author
              (concat (propertize (truncate-string-to-width
                                   (or author "")
                                   (- width 1 3 ; gap, digits
                                      (if (= unit-width 1) 1 (1+ unit-width))
                                      (if (derived-mode-p 'magit-log-mode) 1 0))
                                   nil ?\s (make-string 1 magit-ellipsis))
                                  'face 'magit-log-author)
                      " "))
         (propertize (magit-format-duration
                      (abs (truncate (- (float-time)
                                        (string-to-number date))))
                      (symbol-value duration-spec)
                      unit-width)
                     'face 'magit-log-date)
         (and (derived-mode-p 'magit-log-mode)
              (propertize " " 'face 'fringe)))
      (magit-make-margin-overlay
       (propertize (make-string (1- width) ?\s) 'face 'default)
       (propertize " " 'face 'fringe)))))

(defun magit-format-duration (duration spec &optional width)
  (cl-destructuring-bind (char unit units weight)
      (car spec)
    (let ((cnt (round (/ duration weight 1.0))))
      (if (or (not (cdr spec))
              (>= (/ duration weight) 1))
          (if (eq width 1)
              (format "%3i%c" cnt char)
            (format (if width (format "%%3i %%-%is" width) "%i %s")
                    cnt (if (= cnt 1) unit units)))
        (magit-format-duration duration (cdr spec) width)))))

(defun magit-log-maybe-show-more-commits (section)
  "Automatically insert more commit sections in a log.
Only do so if `point' is on the \"show more\" section,
and `magit-log-auto-more' is non-nil."
  (when (and (eq (magit-section-type section) 'longer)
             magit-log-auto-more)
    (magit-log-double-commit-limit)
    (forward-line -1)
    (magit-section-forward)))

(defvar magit-update-other-window-timer nil)

(defun magit-log-maybe-show-commit (&optional _)
  "Automatically show commit at point in another window.
If the section at point is a `commit' section and the value of
`magit-diff-auto-show-p' calls for it, then show that commit in
another window, using `magit-show-commit'."
  (when (and (or (derived-mode-p 'magit-log-mode)
                 (derived-mode-p 'magit-status-mode))
             (not magit-update-other-window-timer))
    (setq magit-update-other-window-timer
          (run-with-idle-timer
           magit-update-other-window-delay nil
           (lambda ()
             (magit-section-when commit
               (let ((rev (magit-section-value it)))
                 (--if-let (and (magit-diff-auto-show-p 'blob-follow)
                                (derived-mode-p 'magit-log-mode)
                                (--first (with-current-buffer it
                                           magit-buffer-revision)
                                         (-map #'window-buffer (window-list))))
                     (save-excursion
                       (with-selected-window (get-buffer-window it)
                         (with-current-buffer it
                           (magit-blob-visit (list (magit-rev-parse rev)
                                                   (magit-file-relative-name
                                                    magit-buffer-file-name))
                                             (line-number-at-pos)))))
                   (when (and (not (magit-section-children
                                    (magit-current-section)))
                              (or (and (magit-diff-auto-show-p 'log-follow)
                                       (magit-mode-get-buffer
                                        'magit-revision-mode nil t))
                                  (and (magit-diff-auto-show-p 'log-oneline)
                                       (derived-mode-p 'magit-log-mode))))
                     (let ((magit-display-buffer-noselect t))
                       (apply #'magit-show-commit rev (magit-diff-arguments)))))))
             (setq magit-update-other-window-timer nil))))))

(defun magit-log-goto-same-commit ()
  (-when-let* ((prev magit-previous-section)
               (rev  (cond ((magit-section-match 'commit prev)
                            (magit-section-value prev))
                           ((magit-section-match 'branch prev)
                            (magit-rev-format
                             "%h" (magit-section-value prev)))))
               (same (--first (equal (magit-section-value it) rev)
                              (magit-section-children magit-root-section))))
    (goto-char (magit-section-start same))))

;;; Select Mode

(defvar magit-log-select-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-log-mode-map)
    (define-key map "\C-c\C-b" 'undefined)
    (define-key map "\C-c\C-f" 'undefined)
    (define-key map "."        'magit-log-select-pick)
    (define-key map "e"        'magit-log-select-pick)
    (define-key map "\C-c\C-c" 'magit-log-select-pick)
    (define-key map "q"        'magit-log-select-quit)
    (define-key map "\C-c\C-k" 'magit-log-select-quit)
    map)
  "Keymap for `magit-log-select-mode'.")

(put 'magit-log-select-pick :advertised-binding [?\C-c ?\C-c])
(put 'magit-log-select-quit :advertised-binding [?\C-c ?\C-k])

(define-derived-mode magit-log-select-mode magit-log-mode "Magit Select"
  "Mode for selecting a commit from history.

This mode is documented in info node `(magit)Select from log'.

\\<magit-mode-map>\
Type \\[magit-refresh] to refresh the current buffer.
Type \\[magit-visit-thing] or \\[magit-diff-show-or-scroll-up] \
to visit the commit at point.

\\<magit-log-select-mode-map>\
Type \\[magit-log-select-pick] to select the commit at point.
Type \\[magit-log-select-quit] to abort without selecting a commit."
  :group 'magit-log
  (hack-dir-local-variables-non-file-buffer))

(defun magit-log-select-refresh-buffer (rev args)
  (magit-insert-section (logbuf)
    (magit-insert-log rev args)))

(defvar-local magit-log-select-pick-function nil)
(defvar-local magit-log-select-quit-function nil)

(defun magit-log-select (pick &optional msg quit branch)
  (declare (indent defun))
  (magit-mode-setup #'magit-log-select-mode
                    (or branch (magit-get-current-branch) "HEAD")
                    magit-log-select-arguments)
  (magit-log-goto-same-commit)
  (setq magit-log-select-pick-function pick)
  (setq magit-log-select-quit-function quit)
  (when magit-log-select-show-usage
    (setq msg (substitute-command-keys
               (format-spec
                (if msg
                    (if (string-suffix-p "," msg)
                        (concat msg " or %q to abort")
                      msg)
                  "Type %p to select commit at point, or %q to abort")
                '((?p . "\\[magit-log-select-pick]")
                  (?q . "\\[magit-log-select-quit]")))))
    (when (memq magit-log-select-show-usage '(both header-line))
      (setq header-line-format (propertize (concat " " msg) 'face 'bold)))
    (when (memq magit-log-select-show-usage '(both echo-area))
      (message "%s" msg))))

(defun magit-log-select-pick ()
  "Select the commit at point and act on it.
Call `magit-log-select-pick-function' with the selected
commit as argument."
  (interactive)
  (let ((fun magit-log-select-pick-function)
        (rev (magit-commit-at-point)))
    (kill-buffer (current-buffer))
    (funcall fun rev)))

(defun magit-log-select-quit ()
  "Abort selecting a commit, don't act on any commit."
  (interactive)
  (kill-buffer (current-buffer))
  (when magit-log-select-quit-function
    (funcall magit-log-select-quit-function)))

;;; Cherry Mode

(defvar magit-cherry-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-mode-map)
    (define-key map "q" 'magit-log-bury-buffer)
    (define-key map "L" 'magit-toggle-margin)
    map)
  "Keymap for `magit-cherry-mode'.")

(define-derived-mode magit-cherry-mode magit-mode "Magit Cherry"
  "Mode for looking at commits not merged upstream.

\\<magit-mode-map>\
Type \\[magit-refresh] to refresh the current buffer.
Type \\[magit-visit-thing] or \\[magit-diff-show-or-scroll-up] \
to visit the commit at point.

Type \\[magit-cherry-pick-popup] to apply the commit at point.

\\{magit-cherry-mode-map}"
  :group 'magit-log
  (hack-dir-local-variables-non-file-buffer))

;;;###autoload
(defun magit-cherry (head upstream)
  "Show commits in a branch that are not merged in the upstream branch."
  (interactive
   (let  ((head (magit-read-branch "Cherry head")))
     (list head (magit-read-other-branch "Cherry upstream" head
                                         (magit-get-tracked-branch head)))))
  (magit-mode-setup #'magit-cherry-mode upstream head))

(defun magit-cherry-refresh-buffer (_upstream _head)
  (magit-insert-section (cherry)
    (run-hooks 'magit-cherry-sections-hook)))

(defun magit-insert-cherry-headers ()
  "Insert headers appropriate for `magit-cherry-mode' buffers."
  (magit-insert-head-header (nth 1 magit-refresh-args))
  (magit-insert-upstream-header (nth 1 magit-refresh-args)
                                (nth 0 magit-refresh-args))
  (insert ?\n))

(defun magit-insert-cherry-commits ()
  "Insert commit sections into a `magit-cherry-mode' buffer."
  (magit-insert-section (cherries)
    (magit-insert-heading "Cherry commits:")
    (magit-git-wash (apply-partially 'magit-log-wash-log 'cherry)
      "cherry" "-v" "--abbrev" magit-refresh-args)))

;;; Reflog Mode

(defvar magit-reflog-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-log-mode-map)
    (define-key map "L" 'magit-toggle-margin)
    map)
  "Keymap for `magit-reflog-mode'.")

(define-derived-mode magit-reflog-mode magit-log-mode "Magit Reflog"
  "Mode for looking at Git reflog.

This mode is documented in info node `(magit)Reflog'.

\\<magit-mode-map>\
Type \\[magit-refresh] to refresh the current buffer.
Type \\[magit-visit-thing] or \\[magit-diff-show-or-scroll-up] \
to visit the commit at point.

Type \\[magit-cherry-pick-popup] to apply the commit at point.
Type \\[magit-reset] to reset HEAD to the commit at point.

\\{magit-reflog-mode-map}"
  :group 'magit-log
  (hack-dir-local-variables-non-file-buffer))

(defun magit-reflog-refresh-buffer (ref args)
  (setq header-line-format
        (propertize (concat " Reflog for " ref) 'face 'magit-header-line))
  (magit-insert-section (reflogbuf)
    (magit-git-wash (apply-partially 'magit-log-wash-log 'reflog)
      "reflog" "show" "--format=%h %gd %gs" "--date=raw" args ref)))

(defvar magit-reflog-labels
  '(("commit"      . magit-reflog-commit)
    ("amend"       . magit-reflog-amend)
    ("merge"       . magit-reflog-merge)
    ("checkout"    . magit-reflog-checkout)
    ("branch"      . magit-reflog-checkout)
    ("reset"       . magit-reflog-reset)
    ("rebase"      . magit-reflog-rebase)
    ("cherry-pick" . magit-reflog-cherry-pick)
    ("initial"     . magit-reflog-commit)
    ("pull"        . magit-reflog-remote)
    ("clone"       . magit-reflog-remote)
    ("autosave"    . magit-reflog-commit)
    ("restart"     . magit-reflog-reset)))

(defun magit-reflog-format-subject (subject)
  (let* ((match (string-match magit-reflog-subject-re subject))
         (command (and match (match-string 1 subject)))
         (option  (and match (match-string 2 subject)))
         (type    (and match (match-string 3 subject)))
         (label (if (string= command "commit")
                    (or type command)
                  command))
         (text (if (string= command "commit")
                   label
                 (mapconcat #'identity
                            (delq nil (list command option type))
                            " "))))
    (format "%-16s "
            (propertize text 'face
                        (or (cdr (assoc label magit-reflog-labels))
                            'magit-reflog-other)))))

;;; Log Sections

(defvar magit-unpulled-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit-visit-thing] 'magit-diff-unpulled)
    map)
  "Keymap for the `unpulled' section.")

(magit-define-section-jumper unpulled "Unpulled commits")

(defun magit-insert-unpulled-commits ()
  "Insert section showing unpulled commits."
  (-when-let (tracked (magit-get-tracked-ref))
    (magit-insert-section (unpulled)
      (magit-insert-heading "Unpulled commits:")
      (magit-insert-log (concat "HEAD.." tracked)
                        magit-log-section-arguments))))

(defun magit-insert-unpulled-or-recent-commits ()
  "Insert section showing unpulled or recent commits.
If an upstream is configured for the current branch and it is
ahead of the current branch, then show the missing commits,
otherwise show the last `magit-log-section-commit-count'
commits."
  (let ((tracked (magit-get-tracked-ref)))
    (if (and tracked (not (equal (magit-rev-parse "HEAD")
                                 (magit-rev-parse tracked))))
        (magit-insert-unpulled-commits)
      (magit-insert-recent-commits t))))

(defun magit-insert-recent-commits (&optional collapse)
  "Insert section showing recent commits.
Show the last `magit-log-section-commit-count' commits."
  (magit-insert-section (recent nil collapse)
    (magit-insert-heading "Recent commits:")
    (magit-insert-log
     (let ((beg (format "HEAD~%s" magit-log-section-commit-count)))
       (and (magit-rev-verify beg)
            (concat beg "..HEAD")))
     (cons (format "-%d" magit-log-section-commit-count)
           magit-log-section-arguments))))

(defun magit-insert-unpulled-cherries ()
  "Insert section showing unpulled commits.
Like `magit-insert-unpulled-commits' but prefix each commit
which has not been applied yet (i.e. a commit with a patch-id
not shared with any local commit) with \"+\", and all others
with \"-\"."
  (-when-let (tracked (magit-get-tracked-ref))
    (magit-insert-section (unpulled)
      (magit-insert-heading "Unpulled commits:")
      (magit-git-wash (apply-partially 'magit-log-wash-log 'cherry)
        "cherry" "-v" (magit-abbrev-arg) (magit-get-current-branch) tracked))))

(defun magit-insert-unpulled-module-commits ()
  "Insert sections for all submodules with unpulled commits.
These sections can be expanded to show the respective commits."
  (-when-let (modules (magit-get-submodules))
    (magit-insert-section section (unpulled-modules)
      (magit-insert-heading "Unpulled modules:")
      (magit-with-toplevel
        (dolist (module modules)
          (let ((default-directory
                  (expand-file-name (file-name-as-directory module))))
            (-when-let (tracked (magit-get-tracked-ref))
              (magit-insert-section sec (file module t)
                (magit-insert-heading
                  (concat (propertize module 'face 'magit-diff-file-heading) ":"))
                (magit-insert-submodule-commits
                 section (concat "HEAD.." tracked)))))))
      (if (> (point) (magit-section-content section))
          (insert ?\n)
        (magit-cancel-section)))))

(defun magit-insert-submodule-commits (section range)
  "For internal use, don't add to a hook."
  (if (magit-section-hidden section)
      (setf (magit-section-washer section)
            (apply-partially #'magit-insert-submodule-commits section range))
    (magit-git-wash (apply-partially 'magit-log-wash-log 'module)
      "log" "--oneline" range)
    (when (> (point) (magit-section-content section))
      (delete-char -1))))

(defvar magit-unpushed-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit-visit-thing] 'magit-diff-unpushed)
    map)
  "Keymap for the `unpushed' section.")

(magit-define-section-jumper unpushed "Unpushed commits")

(defun magit-insert-unpushed-commits ()
  "Insert section showing unpushed commits."
  (-when-let (tracked (magit-get-tracked-ref))
    (magit-insert-section (unpushed)
      (magit-insert-heading "Unpushed commits:")
      (magit-insert-log (concat tracked "..HEAD")
                        magit-log-section-arguments))))

(defun magit-insert-unpushed-cherries ()
  "Insert section showing unpushed commits.
Like `magit-insert-unpushed-commits' but prefix each commit
which has not been applied to upstream yet (i.e. a commit with
a patch-id not shared with any upstream commit) with \"+\", and
all others with \"-\"."
  (-when-let (tracked (magit-get-tracked-ref))
    (magit-insert-section (unpushed)
      (magit-insert-heading "Unpushed commits:")
      (magit-git-wash (apply-partially 'magit-log-wash-log 'cherry)
        "cherry" "-v" (magit-abbrev-arg) tracked))))

(defun magit-insert-unpushed-module-commits ()
  "Insert sections for all submodules with unpushed commits.
These sections can be expanded to show the respective commits."
  (-when-let (modules (magit-get-submodules))
    (magit-insert-section section (unpushed-modules)
      (magit-insert-heading "Unpushed modules:")
      (magit-with-toplevel
        (dolist (module modules)
          (let ((default-directory
                  (expand-file-name (file-name-as-directory module))))
            (-when-let (tracked (magit-get-tracked-ref))
              (magit-insert-section sec (file module t)
                (magit-insert-heading
                  (concat (propertize module 'face 'magit-diff-file-heading) ":"))
                (magit-insert-submodule-commits
                 section (concat tracked "..HEAD")))))))
      (if (> (point) (magit-section-content section))
          (insert ?\n)
        (magit-cancel-section)))))

;;; Buffer Margins

(defvar-local magit-set-buffer-margin-refresh nil)

(defvar-local magit-show-margin nil)
(put 'magit-show-margin 'permanent-local t)

(defun magit-toggle-margin ()
  "Show or hide the Magit margin."
  (interactive)
  (unless (derived-mode-p 'magit-log-mode 'magit-status-mode 'magit-refs-mode)
    (user-error "Buffer doesn't contain any logs"))
  (magit-set-buffer-margin (not (cdr (window-margins)))))

(defun magit-maybe-show-margin ()
  "Maybe show the margin, depending on the major-mode and an option.
Supported modes are `magit-log-mode' and `magit-reflog-mode',
and the respective options are `magit-log-show-margin' and
`magit-reflog-show-margin'."
  (pcase major-mode
    (`magit-log-mode    (magit-set-buffer-margin magit-log-show-margin))
    (`magit-reflog-mode (magit-set-buffer-margin magit-reflog-show-margin))))

(defun magit-set-buffer-margin (enable)
  (let ((width (cond ((not enable) nil)
                     ((derived-mode-p 'magit-reflog-mode)
                      (+ (cadr magit-log-margin-spec) 5))
                     (t (car magit-log-margin-spec)))))
    (setq magit-show-margin width)
    (when (and enable magit-set-buffer-margin-refresh)
      (magit-refresh))
    (-when-let (window (get-buffer-window))
      (with-selected-window window
        (set-window-margins nil (car (window-margins)) width)
        (if enable
            (add-hook  'window-configuration-change-hook
                       'magit-set-buffer-margin-1 nil t)
          (remove-hook 'window-configuration-change-hook
                       'magit-set-buffer-margin-1 t))))))

(defun magit-set-buffer-margin-1 ()
  (-when-let (window (get-buffer-window))
    (with-selected-window window
      (set-window-margins nil (car (window-margins)) magit-show-margin))))

(defun magit-make-margin-overlay (&rest strings)
  ;; Don't put the overlay on the complete line to work around #1880.
  (let ((o (make-overlay (1+ (line-beginning-position))
                         (line-end-position)
                         nil t)))
    (overlay-put o 'evaporate t)
    (overlay-put o 'before-string
                 (propertize "o" 'display
                             (list '(margin right-margin)
                                   (apply #'concat strings))))))

;;; magit-log.el ends soon
(provide 'magit-log)
;; Local Variables:
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:
;;; magit-log.el ends here
