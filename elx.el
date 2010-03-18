;;; elx.el --- extract information from Emacs Lisp libraries

;; Copyright (C) 2008, 2009  Jonas Bernoulli

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Created: 20081202
;; Updated: 20091226
;; Version: 0.2
;; Homepage: https://github.com/tarsius/elx
;; Keywords: docs, libraries, packages

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This library extracts information from Emacs Lisp libraries.

;; This extends library `lisp-mnt', which is only suitable for libraries
;; that closely follow the header conventions.  Unfortunately there are
;; many libraries that do not - this library tries to cope with that.

;; This library is also able to extract some values that `lisp-mnt' can't.
;; Most notably this library can extract the features required and
;; provided by a file or group of files.  Libraries `load-hist' and
;; `lib-requires' provide similar functionality by inspecting
;; `load-history' and thus require the inspected library to be loaded.

;; This library on the other hand uses regexp search in the respective
;; files making it unnecessary to load them first.  This means that the
;; `require' and `provide' have to satisfy certain restrictions (see
;; `elx-required' and `elx-provided') and features required or provided
;; by other means are not recognized.  But this is very rare, and this
;; library has the advantage that it can be used even when the required
;; features can't be loaded (because the providing libraries are not
;; available) or when one doesn't want to load them for security reasons.

;; Some of the features implemented here will hopefully be merged into
;; `lisp-mnt.el' once I find the time to create patches.  Likewise code
;; from `elm.el' is likely to be moved to this library.  The important
;; thing to note here is that this library is going to change a lot over
;; the next month or so.

;;; Code:

(require 'cl)
(require 'cl-merge)
(require 'dconv)
(require 'vcomp)
(require 'lisp-mnt)

(defgroup elx nil
  "Extract information from Emacs Lisp libraries."
  :group 'maint
  :link '(url-link :tag "Homepage" "https://github.com/tarsius/elx"))

(defstruct elx-pkg
  "A structure containing info about a single package.

This contains all of the information that can be pulled from the
package's source tree (which excludes things like the package
elpa archive, and archive type).

 - NAME: The name of the package, as a symbol.

 - VERSION: The parsed version of the package.

 - VERSION-RAW: The unsanitized string version of the package version.

 - SUMMARY: The brief description of the package.

 - CREATED: The date this package was created.

 - UPDATED: The date the current version was published.

 - LICENSE: The license of this package (as a symbol).

 - AUTHORS: Alist of author names to email addresses.

 - MAINTAINER: Cons cell of maintainer name and email address.

 - PROVIDES: Features provided by this package.

 - REQUIRES-HARD: The packages hard-required by this package, as
   a list of ((REQ-NAME . REQ-VERSION) features...) lists, where
   REQ-NAME is a symbol and REQ-VERSION is a parsed version
   string.

 - REQUIRES-SOFT: The packages soft-required by this package.
   Format is the same as REQUIRES-HARD.

 - KEYWORDS: The keywords which describe this package.

 - HOMEPAGE: The upstream homepage of this package.

 - WIKIPAGE: The page on EmacsWiki about this package.

 - COMMENTARY: The package commentary."
  name
  version
  version-raw
  summary
  created
  updated
  license
  authors
  maintainer
  provides
  requires-hard
  requires-soft
  keywords
  homepage
  wikipage
  commentary)

(defmacro elx-with-file (file &rest body)
  "Execute BODY in a buffer containing the contents of FILE.

If FILE is nil or equal to `buffer-file-name' execute BODY in the
current buffer. If FILE is a buffer or the name of a buffer,
execute body in that buffer.

Move to beginning of buffer before executing BODY."
  (declare (indent 1) (debug t))
  (let ((filesym (gensym "file")))
    `(let ((,filesym ,file))
       (cond
        ((and ,filesym (stringp ,filesym) (not (equal ,filesym buffer-file-name)))
         (with-temp-buffer
           (insert-file-contents ,filesym)
           (with-syntax-table emacs-lisp-mode-syntax-table
             (goto-char (point-min))
             ,@body)))
        ((buffer-live-p (get-buffer ,filesym))
         (save-excursion
           (with-current-buffer ,filesym
             (with-syntax-table emacs-lisp-mode-syntax-table
               (goto-char (point-min))
               ,@body))))
        (t
         (save-excursion
           (with-syntax-table emacs-lisp-mode-syntax-table
             (goto-char (point-min))
             ,@body)))))))

;; This is almost identical to `lm-header-multiline' and will be merged
;; into that function.
;;
(defun elx-header-multiline (header)
  "Return the contents of the header named HEADER, with continuation lines.
The returned value is a list of strings, one per line."
  (save-excursion
    (goto-char (point-min))
    (let ((res (lm-header header)))
      (when res
	(setq res (list res))
	(forward-line 1)
	(while (and (or (looking-at (concat lm-header-prefix "[\t ]+"))
			(and (not (looking-at
				   (lm-get-header-re
				    "\\sw\\(\\sw\\|\\s_\\|\\s-\\)*")))
			     (looking-at lm-header-prefix)))
		    (goto-char (match-end 0))
		    (looking-at ".+"))
	  (setq res (cons (match-string-no-properties 0) res))
	  (forward-line 1)))
      (nreverse res))))

(defun elx-header (header &optional multiline seperator)
  "Return the contents of the header named HEADER, a string.
Or if MULTILINE and/or SEPERATOR is non-nil return a list of strings,
one per continuation line and/or substring split by SEPERATOR."
  (let ((value (if multiline
		   (elx-header-multiline header)
		 (save-excursion
		   (list (lm-header header))))))
    (when seperator
      (setq value (mapcan (lambda (string)
			    (when string
			      (split-string string seperator t)))
			  value)))
    (if (or seperator multiline)
	value
      (car value))))

;;; Extract Various.

(defun elx-summary (&optional file standardize)
  "Return the summary of file FILE.
Or the current buffer if FILE is equal to `buffer-file-name' or is nil.
If STANDARDIZE is non-nil remove trailing period and upcase first word."
  (let ((summary
	 (elx-with-file file
	   (when (and (looking-at lm-header-prefix)
		      (progn (goto-char (match-end 0))
			     (looking-at "[^ ]+[ \t]+--+[ \t]+\\(.*\\)")))
	     (let ((summary (match-string-no-properties 1)))
	       (if (string-match "[ \t]*-\\*-.*-\\*-" summary)
		   (substring summary 0 (match-beginning 0))
		 summary))))))
    (unless (member summary '(nil ""))
      (when standardize
	(when (string-match "\\.$" summary)
	  (setq summary (substring summary 0 -1)))
	(when (string-match "^[a-z]" summary)
	  (setq summary
		(concat (upcase (substring summary 0 1))
			(substring summary 1)))))
      summary)))

(defun elx-keywords (&optional file)
  "Return list of keywords given in file FILE.
Or the current buffer if FILE is equal to `buffer-file-name' or is nil."
  (elx-with-file file
    (let ((keywords (elx-header "keywords" t)))
      (when keywords
	(mapcan
	 ;; Filter some nonsense.
	 (lambda (str)
	   (when (string-match "^[-a-z]+$" str)
	     (list str)))
	 (split-string
	  (replace-regexp-in-string
	   "\\(\t\\|\s\\)+" "\s"
	   (replace-regexp-in-string
	    "," ""
	    (downcase (mapconcat #'identity keywords " "))))
	  " "))))))

(defsubst elx-commentary-start (&optional afterp)
  "Return the buffer location of the `Commentary' start marker.
If optional AFTERP is non-nil return the locations after the
commentary header itself."
  (lm-section-start lm-commentary-header t))
(defalias 'lm-commentary-mark 'lm-commentary-start)

(defsubst elx-commentary-end ()
  "Return the buffer location of the `Commentary' section end.
This even works when no other section follows the commentary section
like when the actual code is not prefixed with the \"Code\" seciton tag."
  (goto-char (elx-commentary-start t))
  (min (lm-section-end lm-commentary-header)
       (1- (or (re-search-forward "^[\s\t]*[^;\n]" nil t) (point-max)))))

(defun elx-commentary (&optional file)
  "Return the commentary in file FILE.
Or the current buffer if FILE is equal to `buffer-file-name' or is nil.

Return the commentary as a normalized string.  The commentary section
starts with the tag `Commentary' or `Documentation' and ends just before
the next section.  Leading and trailing whitespace is removed from the
returned value but it always ends with exactly one newline. On each line
the leading semicolons and exactly one space are removed, likewise
leading \"\(\" is replaced with just \"(\".  Lines only consisting only of
whitespace are converted to empty lines."
  (elx-with-file file
    (let ((start (elx-commentary-start t)))
      (when start
	(let ((commentary (buffer-substring-no-properties
			   start (elx-commentary-end))))
	  (mapc (lambda (elt)
		  (setq commentary (replace-regexp-in-string
				    (car elt) (cdr elt) commentary)))
		'(("^;+ ?"        . "")
		  ("^\\\\("       . "(")
		  ("^[\n\t\s]\n$" . "\n")
		  ("\\`[\n\t\s]*" . "")
		  ("[\n\t\s]*\\'" . "")))
	  (when (string-match "[^\s\t\n]" commentary)
	    (concat commentary "\n")))))))

;;; Extract Pages.

(defcustom elx-wiki-directory
  (convert-standard-filename "~/.emacs.d/wikipages/")
  "The directory containing the Emacswiki pages.

This variable is used by function `elx-wikipage' when determining the page
on the Emacswiki about a given package.

It's value should be a directory containing all or a subset of pages from
the Emacswiki all at the top-level.  You can create such a directory by
cloning eigher the svn or git repository described at
http://www.emacswiki.org/emacs/SVN_repository and
http://www.emacswiki.org/emacs/Git_repository respectively."
  :group 'elx
  :type 'directory)

(defun elx-wikipage (file &optional pages urlp)
  "Extract the page on the Emacswiki for the specified package.

FILE is the the main file of the package.  Optional PAGES if non-nil
should be either a list of existing pages or a directory containing
the pages.  If it is not specified or nil the value of function
`elx-wiki-directory' is used.  If optional URLP is specified and
non-nil return the url of the page otherwise only the name.

The page is determined by comparing the name of FILE with
existing pages. So their is no guarantee that this will always
return the page about a package, even if it exists.
False-positives might also occur."
  (or (elx-with-file file
	(elx-header "\\(?:x-\\)?\\(?:emacs\\)?wiki-?page"))
      (let ((page (upcase-initials
		   (replace-regexp-in-string "\\+$" "Plus"
		    (replace-regexp-in-string "-."
		     (lambda (str)
		       (upcase (substring str 1)))
		     (or (and (stringp file) (file-name-sans-extension
                   (file-name-nondirectory file)))
                 (buffer-name (get-buffer file))))))))
	(when (member page (if (consp pages)
                           pages
                         (let ((dirname (or pages elx-wiki-directory)))
                           (unless (and (file-exists-p dirname)
                                        (eq t (car (file-attributes dirname))))
                             (mkdir dirname))
                           (directory-files dirname
                                            nil "^[^.]" t))))
	  (concat (when urlp "http://www.emacswiki.org/emacs/") page)))))

(defun elx-homepage (file)
  "Extract the homepage of the specified package."
  (elx-with-file file
    (elx-header "\\(?:x-\\)?\\(?:homepage\\|?url\\)")))

;;; Extract License.

(defcustom elx-license-search
  (let* ((r "[\s\t\n;]+")
	 (l "^;\\{1,4\\} ")
	 (g (concat " General Public Licen[sc]e"
		    "\\( as published by the Free Software Foundation\\)?.?"))
	 (c (concat g " \\(either \\)?version"))
	 (d "Documentation"))
    `(("GPL-3"      . ,(replace-regexp-in-string " " r (concat "GNU" c " 3")))
      ("GPL-2"      . ,(replace-regexp-in-string " " r (concat "GNU" c " 2")))
      ("GPL-1"      . ,(replace-regexp-in-string " " r (concat "GNU" c " 1")))
      ("GPL"        . ,(replace-regexp-in-string " " r (concat "GNU" g)))
      ("LGPL-3"     . ,(replace-regexp-in-string " " r (concat "GNU Lesser"  c " 3")))
      ("LGPL-2.1"   . ,(replace-regexp-in-string " " r (concat "GNU Lesser"  c " 2.1")))
      ("LGPL-2"     . ,(replace-regexp-in-string " " r (concat "GNU Library" c " 2")))
      ("AGPL-3"     . ,(replace-regexp-in-string " " r (concat "GNU Affero"  c " 3")))
      ("FDL-2.1"    . ,(replace-regexp-in-string " " r (concat "GNU Free " d c " 1.2")))
      ("FDL-1.1"    . ,(replace-regexp-in-string " " r (concat "GNU Free " d c " 1.1")))
      ("EPL-1.1"    . ,(replace-regexp-in-string " " r
			"Erlang Public License,? Version 1.1"))
      ("Apache-2.0" . ,(replace-regexp-in-string " " r
			"Apache License, Version 2.0"))
      ("GPL"        . ,(replace-regexp-in-string " " r (concat
		        "Everyone is granted permission to copy, modify and redistribute "
                        ".*, but only under the conditions described in the "
                        "GNU Emacs General Public License.")))
      ("GPL"        . ,(concat l "GPL'ed as under the GNU license"))
      ("GPL"        . ,(concat l "GPL'ed under GNU's public license"))
      ("GPL-2"      . ,(concat l ".* GPL v2 applies."))
      ("GPL-2"      . ,(concat l "The same license/disclaimer for "
			         "XEmacs also applies to this package."))
      ("GPL-3"      . ,(concat l "Licensed under the same terms as Emacs."))
      ("MIT"        . ,(concat l ".* mit license"))
      ("as-is"      . ,(concat l ".* \\(provided\\|distributed\\) "
			         "\\(by the author \\)?"
			         "[\"`']\\{0,2\\}as[- ]is[\"`']\\{0,2\\}"))
      ("public-domain" . ,(concat l ".*in\\(to\\)? the public[- ]domain"))
      ("public-domain" . "^;+ +Public domain.")))
  "List of regexp to common license string mappings.
Used by function `elx-license'.  Each entry has the form
\(LICENSE . REGEXP) where LICENSE is used instead of matches of REGEXP.
Unambitious expressions should come first and those that might produce
false positives last."
  :group 'elx
  :type '(repeat (cons (string :tag "use")
		       (regexp :tag "for regexp"))))

(defcustom elx-license-replace
  '(("GPL-3"      .  "gpl[- ]?v?3")
    ("GPL-2"      .  "gpl[- ]?v?2")
    ("GPL-1"      .  "gpl[- ]?v?1")
    ("GPL"        .  "gpl")
    ("LGPL-3"     . "lgpl[- ]?v?3")
    ("LGPL-2.1"   . "lgpl[- ]?v?2.1")
    ("AGPL-3"     . "agpl[- ]?v?3")
    ("FDL-2.1"    .  "fdl[- ]?v?2.1")
    ("FDL-2.1"    .  "fdl[- ]?v?2.1")
    ("EPL-1.1"    .  "epl[- ]?v?1.1")
    ("EPL-1.1"    .  "erlang-1.1")
    ("Apache-2.0" .  "apache-2.0")
    ("MIT"        .  "mit")
    ("as-is"      .  "as-?is")
    ("public-domain" . "public[- ]domain"))
  "List of string to common license string mappings.
Used by function `elx-license'.  Each entry has the form
\(LICENSE . REGEXP) where LICENSE is used instead of matches of REGEXP."
  :group 'elx
  :type '(repeat (cons (string :tag "use")
		       (regexp :tag "for regexp"))))

(defun elx-license (&optional file)
  "Return the license of file FILE.
Or the current buffer if FILE is equal to `buffer-file-name' or is nil.

The license is extracted from the \"License\" header or if that is missing
by searching the file header for text matching entries in `elx-license-regexps'.

The extracted license string might be modified using `elx-license-mappings'
before it is returned ensuring that each known license is always represented
the same.  If the extracted license does not match \"^[-_.a-zA-Z0-9]+$\"
return nil."
  (elx-with-file file
    (let ((license (elx-header "License")))
      (unless license
	(let ((regexps elx-license-search)
	      (case-fold-search t)
	      (elt))
	  (while (and (not license)
		      (setq elt (pop regexps)))
	    (when (re-search-forward (cdr elt) (lm-code-start) t)
	      (setq license (car elt)
		    regexps nil)))))
      (when license
	(let (elt (mappings elx-license-replace))
	  (while (setq elt (pop mappings))
	    (when (string-match (cdr elt) license)
	      (setq license (car elt)
		    mappings nil))))
	(when (string-match "^[-_.a-zA-Z0-9]+$" license)
	  license)))))

(defcustom elx-license-url
  '(("GPL-3"         . "http://www.fsf.org/licensing/licenses/gpl.html")
    ("GPL-2"         . "http://www.gnu.org/licenses/old-licenses/gpl-2.0.html")
    ("GPL-1"         . "http://www.gnu.org/licenses/old-licenses/gpl-1.0.html")
    ("LGPL-3"        . "http://www.fsf.org/licensing/licenses/lgpl.html")
    ("LGPL-2.1"      . "http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")
    ("LGPL-2.0"      . "http://www.gnu.org/licenses/old-licenses/lgpl-2.0.html")
    ("AGPL-3"        . "http://www.fsf.org/licensing/licenses/agpl.html")
    ("FDL-1.2"       . "http://www.gnu.org/licenses/old-licenses/fdl-1.2.html")
    ("FDL-1.1"       . "http://www.gnu.org/licenses/old-licenses/fdl-1.1.html")
    ("Apache-2.0"    . "http://www.apache.org/licenses/LICENSE-2.0.html")
    ("EPL-1.1"       . "http://www.erlang.org/EPLICENSE")
    ("MIT"           . "http://www.emacsmirror.org/licenses/MIT.html)")
    ("as-is"         . "http://www.emacsmirror.org/licenses/as-is.html)")
    ("public-domain" . "http://www.emacsmirror.org/licenses/public-domain.html)"))
  "List of license to canonical license url mappings.
Each entry has the form (LICENSE . URL) where LICENSE is a license string
and URL the canonial url to the license.
Where no caonconical url is known use a page on the Emacsmirror instead."
  :group 'elx
  :type '(repeat (cons (string :tag "License")
		       (url    :tag "URL"))))

(defun elx-license-url (license)
  "Return the canonical url to LICENSE.
The license is looked up in the variable `elx-license-url'.
If no matching entry exists return nil."
  (cdar (member* license elx-license-url :key 'car :test 'equal)))

;;; Extract Dates.

(defun elx-date--id-header (&optional file)
  (elx-with-file file
    (when (re-search-forward "\\$[I]d: [^ ]+ [^ ]+ \\([^ ]+\\)"
			     (lm-code-mark) t)
      (match-string-no-properties 1))))

(defun elx-date--first-copyright (&optional file)
  (elx-with-file file
    (let ((lm-copyright-prefix "^\\(;+[ \t]\\)+Copyright \\((C) \\)?"))
      (when (lm-copyright-mark)
	(cadr (lm-crack-copyright))))))

(defun elx-date--last-copyright (&optional file)
  (elx-with-file file
    (let ((lm-copyright-prefix "^\\(;+[ \t]\\)+Copyright \\((C) \\)?"))
      (when (lm-copyright-mark)
	(let ((last (car (last (lm-crack-copyright)))))
	  last)))))

(defun elx-date--time-stamp-header (&optional file)
  (let ((value (elx-header "time-stamp")))
    (when (and value
	       (string-match "[\"<]\\([-0-9]+\\)[\s\t].+[\">]" value))
      (match-string 1 value))))

(defun elx-updated (file)
  (elx-with-file file
    (or (dconv-convert-date (elx-header "\\(last-\\)?updated"))
	(dconv-convert-date (elx-header "modified"))
	(dconv-convert-date (elx-header "\\$date"))
	(dconv-convert-date (elx-date--id-header))
	(dconv-convert-date (elx-date--time-stamp-header))
	(dconv-convert-date (elx-date--last-copyright)))))

(defun elx-created (&optional file)
  (elx-with-file file
    (or (dconv-convert-date (lm-creation-date))
	(dconv-convert-date (elx-date--first-copyright)))))

;;; Extract Version.

(defun elx-version--no-colon (&optional file)
  (elx-with-file file
    (when (re-search-forward ";+[\s\t]+Version[\s\t]+\\([\s\t]+\\)"
			     (lm-code-mark) t)
      (match-string-no-properties 1))))

(defun elx-version--id-header (&optional file)
  (elx-with-file file
    (when (re-search-forward "\\$[Ii]d: [^ ]+ \\([^ ]+\\) "
			     (lm-code-mark) t)
      (match-string-no-properties 1))))

(defun elx-version--revision-header (&optional file)
  (elx-with-file file
    (when (re-search-forward "\\$Revision: +\\([^ ]+\\) "
			     (lm-code-mark) t)
      (match-string-no-properties 1))))

(defun elx-version--variable (file)
  (elx-with-file file
    (when (re-search-forward
	   (concat "(def\\(var\\|const\\) "
		   (file-name-sans-extension
		    (file-name-nondirectory file))
		   "[-:]version \"\\([-_.0-9a-z]+\\)\"")
	   (lm-code-mark) t)
      (match-string-no-properties 2))))

(defconst elx-version-canonical-mapping '((-3 . "alpha")
                                          (-2 . "beta")
                                          (-1 . "rc"))
  "Mapping used for translating negative version numbers to strings.

The list returned by `version-to-list' can contain negative
numbers, which represent non-numeric components in the original,
string-based version. These must be translated back to strings,
but in a way such that the operation is fully reversible. This
constant contains a mapping of negative integers and the string
to which to decode them.

Each element has the following form:

    (NUM . STR)

Where NUM is the negative integer returned by `version-to-list'
and STR is the string to which to decode that number.")

(defun elx-version-canonical (version)
  "Returns a canonical string representation of the version list VERSION.

Uses `elx-version-canonical-mapping' to decode negative integers
to their non-numeric representations. The string returned is
itself parse-able by `version-to-list', and so is reversible.

Since `version-to-list' uses the same priority for multiple
different strings, sometimes different version can produce the
same canonical string. For example:

    (elx-version-canonical (version-to-list \"1rc1\"))
      => \"1rc1\"

    (elx-version-canonical (version-to-list \"1pre1\"))
      => \"1rc1\""
  (unless (listp version)
    (error "VERSION must be an integer list"))
  (let ((result (mapconcat '(lambda (part)
                              (if (>= part 0)
                                  (number-to-string part)
                                (format "_%s_" (cdr (assq part elx-version-canonical-mapping)))))
                           version ".")))
    ;; This is an ugly hack, but it is an easy way of preventing (1 -1 1) from
    ;; becoming "1.rc.1", which `version-to-list' cannot parse.
    (replace-regexp-in-string "_\\.\\|\\._" "" result)))

(defun elx-version--do-standardize (version)
  "Standardize common version names such as \"alpha\" or \"v1.0\".

Changes the VERSION name to a more standard form, hopefully
removing discrepancies between version formats. Many libraries
use different conventions for naming their versions, and this is
an attempt to reconcile those varying conventions.

Some examples of the conversion are:

  - \"0.1alpha\" => \"0.1_alpha\"
  - \"v1.0\" => \"1.0\"
  - \"v1.2.3rc3\" => \"1.2.3_rc3\"
"
  (mapc (lambda (elt)
	  (setq version (replace-regexp-in-string
			 (car elt) (cdr elt) version t t 1)))
	'(("[^_]\\(alpha\\)\\([0-9]+\\)?$" . "_alpha")
	  ("[^_]\\(beta\\)\\([0-9]+\\)?$" . "_beta")
	  ("[^_]\\(pre\\)\\([0-9]+\\)?$" . "_pre")
	  ("[^_]\\(rc\\)\\([0-9]+\\)?$" . "_rc")
	  ("\\(^[vV]\\)\\.?" . "")))
  (elx-version--do-verify version))

(defun elx-version--do-verify (version)
  (if (and version (vcomp-version-p version))
      version
    (dconv-convert-date version)))

(defun elx-version--greater (version old-version)
  (when (and version old-version
	     (vcomp-compare version old-version #'<))
    (error "New version is smaller than old version: %s %s"
	   version old-version))
  (elx-version--do-verify
   (if version
       (if (equal version old-version)
	   (if (string-match "[^a-z][a-z]$" old-version)
	       (concat (substring old-version 0 -1)
		       (char-to-string (1+ (string-to-char
					    (substring old-version -1)))))
	     (concat old-version "a"))
	 version)
     (if old-version
	 (number-to-string (1+ (string-to-number old-version)))
       "0001"))))

(defvar elx-version-sanitize-regexps '(("\\$[Ii]d: [^ ]+ \\([^ ]+\\) " . "\\1")
                                       ("\\$[Rr]evision: +\\([^ ]+\\) " . "\\1")
                                       ("\\([-_.0-9a-z]+\\)[\s\t].+" . "\\1")
                                       ("[^[:digit:]]+\\([[:alnum]_.-]+\\)" . "\\1"))
  "List of regexps to use to sanitize a version string.

This is a list of (REGEXP . REP), to be passed to
`replace-regexp-in-string'.")

(defun elx-version-sanitize (version)
  "Clean up a VERSION, stripping extraneous text.

If VERSION passes all of the checks, return it unmodified."
  ;; TODO: Make this into a list of regexps against which to match.
  (mapc '(lambda (filter)
             (setq version (replace-regexp-in-string
                            (car filter)
                            (cdr filter)
                            version)))
        elx-version-sanitize-regexps)
  version)

(defun elx-version (file &optional standardize)
  "Return the version of file FILE.
Or the current buffer if FILE is equal to `buffer-file-name'.

Return the value of header \"Version\".  If header \"Update\\( #\\)?\" is
also defined append it's value after a period.  If \"Update\\( #\\)?\" is
defined but \"Version\" is not assume 0 for \"Version\".

If optional STANDARDIZE is non-nil verify and possible convert the version
using function `elx-version--do-standardize' (which see).

If the file fails to properly define the version and you absolutely need
something else than nil try function `elx-version+' or even `elx-version>'
and complain to the respective author."
  (elx-with-file file
    (let ((version (or (elx-header "version")
		       (elx-version--no-colon)))
	  (update (elx-header "update\\( #\\)?")))
      (setq version (elx-version-sanitize version))
      (when update
	(setq version (concat (or version "0") "." update)))
      (elx-version--do-verify (if (and version standardize)
				  (elx-version--do-standardize version)
				version)))))

(defun elx-version+ (file &optional standardize)
  "Return _a_ version string for file FILE.
Or the current buffer if FILE is equal to `buffer-file-name'.

If the file properly defines a version extract it using `elx-version'.
Otherwise try several known ways in which people have defined the version
in Emacs Lisp libraries.

If optional STANDARDIZE is non-nil verify and possible convert the version
using function `elx-version--do-standardize' (which see).

If this function returns nil then the author of FILE sucks badly at
writing library headers and if you can absolutely not live with that use
`elx-version>' instead."
  (let ((version (elx-version file standardize)))
    (if version
	version
      (elx-with-file file
	(setq version (or (elx-version--variable file)
			  (elx-version--id-header)
			  (elx-version--revision-header))))
      (elx-version--do-verify
       (if (and version standardize)
	   (elx-version--do-standardize version)
	 version)))))

(defun elx-version> (file old-version &optional standardize)
  "Return _a_ version string for the file FILE.
Or the current buffer if FILE is equal to `buffer-file-name'.

If no version can be found return a pseudo version like \"0001\".

If OLD-VERSION is non-nil the new version has to be greater.  If it is
smaller this is an error.  If it is equal increase it.  E.g. \"0.1\" becomes
\"0.1a\" but if OLD-VERSION appears to be a pseudo version like \"0001\" use
something like \"0002\" instead.

If optional STANDARDIZE is non-nil verify and possible convert the version
using function `elx-version--do-standardize' (which see).

Also see functions `elx-version' and `elx-version+' for less aggressive
approches and more aggressive doc-strings."
  ;; FIXME doc-string might be wrong for some side cases.
  (elx-version--greater (or (elx-version+ file standardize)
			    (elx-updated file))
			old-version))

(defun elx-version-internal (file &optional standardize)
  "Return the version string of the file FILE.
Or the current buffer if FILE is equal to `buffer-file-name'.

Only use this for files that are distributed with GNU Emacs otherwise use
function `elx-version'.

If optional STANDARDIZE is non-nil verify and possibly convert the version
using function `elx-version--do-standardize' (which see).

If the file defines a version extract it using function `elx-version' and
if that fails using function `elx-version--variable'.  If that fails return
the value of variable `emacs-version'."
  (or (elx-version file t)
      (let ((version (elx-version--variable file)))
	(elx-version--do-verify
	 (if (and version standardize)
	     (elx-version--do-standardize version)
	   version)))
      emacs-version))

(defun elx-version-internal> (file old-version &optional standardize)
  (elx-version--greater (elx-version-internal file standardize) old-version))

;;; Extract People.

(defun elx-crack-address (x)
  "Split up an email address X into full name and real email address.
The value is a cons of the form (FULLNAME . ADDRESS)."
  (let (name mail)
    (cond ((string-match (concat "\\(.+\\) "
				 "?[(<]\\(\\S-+@\\S-+\\)[>)]") x)
	   (setq name (match-string 1 x)
		 mail (match-string 2 x)))
	  ((string-match (concat "\\(.+\\) "
				 "[(<]\\(?:\\(\\S-+\\) "
				 "\\(?:\\*?\\(?:AT\\|[.*]\\)\\*?\\) "
				 "\\(\\S-+\\) "
				 "\\(?:\\*?\\(?:DOT\\|[.*]\\)\\*? \\)?"
				 "\\(\\S-+\\)\\)[>)]") x)
	   (setq name (match-string 1 x)
		 mail (concat (match-string 2 x) "@"
			      (match-string 3 x) "."
			      (match-string 4 x))))
	  ((string-match (concat "\\(.+\\) "
				 "[(<]\\(?:\\(\\S-+\\) "
				 "\\(?:\\*?\\(?:AT\\|[.*]\\)\\*?\\) "
				 "\\(\\S-+\\)[>)]\\)") x)
	   (setq name (match-string 1 x)
		 mail (concat (match-string 2 x) "@"
			      (match-string 3 x))))
	  ((string-match (concat "\\(\\S-+@\\S-+\\) "
				 "[(<]\\(.*\\)[>)]") x)
	   (setq name (match-string 2 x)
		 mail (match-string 1 x)))
	  ((string-match "\\S-+@\\S-+" x)
	   (setq mail x))
	  (t
	   (setq name x)))
    (cons (and (stringp name)
	       (string-match "^ *\\([^:0-9<@>]+?\\) *$" name)
	       (match-string 1 name))
	  (and (stringp mail)
	       (string-match
		(concat "^\\s-*\\("
			"[a-z0-9!#$%&'*+/=?^_`{|}~-]+"
			"\\(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+\\)*@"
			"\\(?:[a-z0-9]\\(?:[a-z0-9-]*[a-z0-9]\\)?\.\\)+"
			"[a-z0-9]\\(?:[a-z0-9-]*[a-z0-9]\\)?"
			"\\)\\s-*$") mail)
	       (downcase (match-string 1 mail))))))

(defun elx-authors (&optional file)
  "Return the author list of file FILE.
Or the current buffer if FILE is equal to `buffer-file-name' or is nil.
Each element of the list is a cons; the car is the full name,
the cdr is an email address."
  (elx-with-file file
    (let ((authors (elx-header "authors?" t ", +")))
      (mapcar 'elx-crack-address authors))))

(defun elx-maintainer (&optional file)
  "Return the maintainer of file FILE.
Or the current buffer if FILE is equal to `buffer-file-name' or is nil.
The return value has the form (NAME . ADDRESS)."
  (elx-with-file file
    (let ((maint (elx-header "maintainer" nil ", +")))
      (if maint
	  (elx-crack-address (car maint))
	(car (elx-authors))))))

(defun elx-adapted-by (&optional file)
  "Return the person how adapted file FILE.
Or the current buffer if FILE is equal to `buffer-file-name' or is nil.
The return value has the form (NAME . ADDRESS)."
  (elx-with-file file
    (let ((adapter (elx-header "adapted-by" nil ", +")))
      (when adapter
	(car (elx-crack-address adapter))))))

;;; Extract Features.

(defvar elx-known-features nil
  "List of known features.
Each element is a cons cell whose car is a feature symbol and whose cdr is
the providing package, a symbol.  You are responsible to setup the value
yourself.  This variable may be used in function `elx-required-packages'.")

(defvar elx-missing-features nil
  "List of missing features.
Each element is a feature symbol.  Function `elx-required-packages'
populates this variable with features it can not find in variable
`elx-known-features'.")

(defconst elx-provided-regexp "\
\(\\(?:cc-\\)?provide[\s\t\n]'\
\\([^(),\s\t\n]+\\)\\(?:[\s\t\n]+'\
\(\\([^(),]+\\))\\)?)")

(defun elx--buffer-provided (buffer)
  (let (features)
    (with-current-buffer buffer
      (save-excursion
	(goto-char (point-min))
	(while (re-search-forward elx-provided-regexp nil t)
	  (unless (save-match-data
		    (or (nth 3 (syntax-ppss))   ; in string
			(nth 4 (syntax-ppss)))) ; in comment
	    (dolist (feature (cons (match-string 1)
				   (when (match-string 2)
				     (split-string (match-string 2) " " t))))
	      (add-to-list 'features (intern feature))))))
      (sort features #'string<))))

(defun elx-provided (source)
  "Return a list of the features provided by SOURCE.

SOURCE has to be a file, directory or list of files and/or directories.

If SOURCE is a directory return all features provided by Emacs lisp files
inside SOURCE and recursively all subdirectories.  Files not ending in
\".el\" and directories starting with a period are ignored, except when
explicitly passed to this function.

This will only find features required exactly like:
\([cc-]require 'FEATURE [nil|\"PATH\" [nil|t]]).
The regexp being used is stored in variable `elx-provided-regexp'."
  (delete-duplicates
   (sort (cond ((listp source)
                (mapcan #'elx-provided source))
               ;; TODO: This is a basic hack to avoid symlink loops, a more
               ;; sophisticated version would use `file-truename' and keep track
               ;; of previously-visited files and directories.
               ((and (stringp source) (file-symlink-p source))
                nil)
	       ((and (stringp source) (file-directory-p source))
		(mapcan (lambda (elt)
			  (when (or (file-directory-p elt)
				    (string-match "\\.el\\(.gz\\)?$" elt))
			    (elx-provided elt)))
			(directory-files source t "^[^\\.]" t)))
	       (t
		(elx-with-file source
		  (elx--buffer-provided (current-buffer)))))
	 #'string<)
   :test #'equal))

(defconst elx-required-regexp "\
\(\\(?:cc-\\)?require[\s\t\n]'\
\\([^(),\s\t\n]+\\)\
\\(?:\\(?:[\s\t\n]+\\(?:nil\\|\".*\"\\)\\)\
\\(?:[\s\t\n]+\\(?:nil\\|\\(t\\)\\)\\)?\\)?)")

(defun elx--format-required (required &optional sort-fn unique-p)
  (let ((hard (nth 0 required))
	(soft (nth 1 required)))
    (when sort-fn
      (setq hard (sort hard sort-fn)
	    soft (sort soft sort-fn)))
    (when unique-p
      (setq hard (delete-duplicates hard :test #'equal)
	    soft (delete-duplicates soft :test #'equal)))
    (if soft
	(list hard soft)
      (when hard
	(list hard)))))

(defun elx--lookup-required (provided known required include exclude)
  (unless known
    (setq known elx-known-features))
  (let (packages)
    (dolist (requ (nconc (copy-list required) include))
      (unless (memq requ exclude)
	(let* ((package (if (hash-table-p known)
			    (gethash requ known)
			  (cdr (assoc requ known))))
	       (elt (car (member* package packages :test 'equal :key 'car))))
	  (unless package
	    (add-to-list 'elx-missing-features requ))
	  (if elt
	      (unless (memq requ (cdr elt))
		(setcdr elt (sort (cons requ (cdr elt)) 'string<)))
	    (push (list package requ) packages)))))
    (sort* packages
	   (lambda (a b)
	     (cond ((null a) nil)
		   ((null b) t)
		   (t (string< a b))))
	   :key 'car)))

(defun elx--buffer-required (buffer &optional provided)
  (let (required-hard
	required-soft)
    (with-current-buffer buffer
      (save-excursion
	(goto-char (point-min))
	(while (re-search-forward elx-required-regexp nil t)
	  (let ((feature (intern (match-string 1))))
	    (cond ((save-match-data
		      (or (nth 3 (syntax-ppss))    ; in string
			  (nth 4 (syntax-ppss))))) ; in comment
		  ((match-string 2)
		   (unless (or (member feature required-hard)
			       (member feature required-soft))
		     (push feature required-soft)))
		  ((not (member feature required-hard))
		   (setq required-soft (remove feature required-soft))
		   (push feature required-hard))))))
      (elx--format-required (list required-hard required-soft)
			    #'string<))))

(defun elx-required (source &optional provided)
  "Return the features required by SOURCE.
The returned value has the form:

  ((HARD-REQUIRED...)
   [(SOFT-REQUIRED...)])

Where HARD-REQUIREDs and SOFT-REQUIREDs are symbols.  If no features are
required nil is returned.

SOURCE has to be a file, directory or list of files and/or directories.

If SOURCE is a directory return all features required by Emacs lisp files
inside SOURCE and recursively all subdirectories.  Files not ending in
\".el\" and directories starting with a period are ignored, except when
explicetly passed to this function.

If optional PROVIDED is provided and non-nil is has to be a list of
features, t or a function.  If it is t call `elx-provided' with SOURCE as
only argument and use the returned list of features.  Members of this list
of features are not included in the return value.

This function will only find features provided exactly like:
\(provide 'FEATURE '(SUBFEATURE...)).
The regexp being used is stored in variable `elx-required-regexp'."
  (when (eq provided t)
    (setq provided (elx-provided source)))
  (elx--format-required
   (cond ((listp source)
	  (mapcan (lambda (elt)
		    (elx-required elt provided))
		  source))
	 ((and (stringp source) (file-directory-p source))
	  (mapcan (lambda (source)
		    (when (or (file-directory-p source)
			      (string-match "\\.el$" source))
		      (elx-required source provided)))
		  (directory-files source t "^[^\\.]" t)))
	 (t
	  (elx-with-file source
	    (elx--buffer-required (current-buffer) provided))))
   #'string< t))

(defun elx-required-packages (source &optional provided known include exclude)
  "Return the packages packages required by SOURCE.
The returned value has the form:

  (((HARD-REQUIRED-PACKAGE FEATURE...)...)
   [((SOFT-REQUIRED-PACKAGE FEATURE...)...)])

Where HARD-REQUIRED-PACKAGE, SOFT-REQUIRED-PACKAGE, and FEATURE
are symbols. If no features/packages are required nil is
returned.

SOURCE has to be a file, directory, list of files and/or directories or
a function.

If SOURCE is a function use it instead of `elx-required' to extract the
list of required *features*.  It will be called with two arguments
PROVIDED and KNOWN.

If SOURCE is a directory return all features required by Emacs lisp files
inside SOURCE and recursively all subdirectories.  Files not ending in
\".el\" and directories starting with a period are ignored, except when
explicetly passed to this function.

If optional PROVIDED is provided and non-nil is has to be a list of
features, t or a function.  If it is a function call it with SOURCE as
only argument and use the returned list of features.  Likewise if it is t
call `elx-provided'.  Members of this list of features are not included
in the return value.

If optional KNOWN is provided and non-nil it has to be an alist or
hash table mapping features to packages.  If it is omitted or nil the
value of variable `elx-known-features' is used, however you have to setup
the value of its yourself.

INCLUDE and EXCLUDE are useful when you know that the value returned by
the function (usually `elx-required') used to extract the list of required
*features* is not absolutely correct.

If optional INCLUDE is provided and non-nil it has to be a list of
features.  These features will be treated as if they were returned by the
function used to extract the list of provided *features*.

If optional EXCLUDE is provided and non-nil it has to be a list of
features.  These features and the corresponding packages won't be part of
the returned value.

This function will only find features provided exactly like:
\(provide 'FEATURE '(SUBFEATURE...)).
The regexp being used is stored in variable `elx-required-regexp'."
  (unless (listp provided)
    (setq provided (apply (if (functionp provided)
			      provided
			    'elx-provided)
			  source)))
  (let ((required (if (functionp source)
		      (apply source provided known)
		    (elx-required source provided))))
    (elx--format-required
     (list
      (elx--lookup-required provided known
			    (nth 0 required)
			    (nth 0 include)
			    (nth 0 exclude))
      (elx--lookup-required provided known
			    (nth 1 required)
			    (nth 1 include)
			    (nth 1 exclude))))))

;;; Extract Complete Metadata.

(defun elx--lisp-files (directory &optional full)
  (let (files)
    (dolist (file (directory-files directory t "^[^.]" t))
      (cond ((file-directory-p file)
	     (setq files (nconc (elx--lisp-files file t) files)))
	    ((string-match "\\.el$" file)
	     (setq files (cons file files)))))
    (if full
	files
      (let ((default-directory directory))
	(mapcar 'file-relative-name files)))))

(defun elx-package-mainfile (directory &optional full)
  "Return the mainfile of the package inside DIRECTORY.

If optional FULL is non-nil return an absolute path, otherwise return the
path relative to DIRECTORY.

If the package has only one file ending in \".el\" return that file
unconditionally.  Otherwise return the file which provides the feature
matching the basename of DIRECTORY, or if no such file exists the file
that provides the feature matching the basename of DIRECTORY with \"-mode\"
added to or removed from the end, whatever makes sense."
  (let ((files (elx--lisp-files directory full))
	(name (regexp-quote (file-name-nondirectory
			     (directory-file-name directory)))))
    (if (= 1 (length files))
	(car files)
      (flet ((match (feature)
		    (car (member* (format "%s\\.el$" feature)
				  files :test 'string-match))))
	(cond ((match name))
	      ((match (if (string-match "-mode$" name)
			  (substring name 0 -5)
			(concat name "-mode")))))))))

(defun elx-package-metadata (source &optional mainfile prev)
  "Extract and return the metadata of an Emacs Lisp package.

SOURCE has to be the path to an Emacs Lisp library (a single
file) or the path to a directory containing a package consisting of
several Emacs Lisp files and/or auxiliary files.

If SOURCE is a directory this function needs to know which
file is the package's \"mainfile\"; that is the file from which most
information is extracted (everything but the required and provided
features which are extracted from all Emacs Lisp files in the directory
collectively).

Optional MAINFILE can be used to specify the \"mainfile\" explicitly.
Otherwise function `elx-package-mainfile' (which see) is used to guess it.
MAINFILE has to be relative to the package directory or an absolute path.

If PREV is non-nil, then treat it as the previous version of this
package and overwrite its fields with those found by looking
through SOURCE.

\(fn SOURCE [MAINFILE] [PREV])"
  (unless mainfile
    (setq mainfile
	  (if (and (stringp source) (file-directory-p source))
	      (elx-package-mainfile source t)
	    source)))
  (cond
   ((and mainfile (stringp mainfile) (not (file-name-absolute-p mainfile)))
    (setq mainfile (concat source mainfile)))
   ((buffer-live-p mainfile))
   (t
    (error "The mainfile can not be determined")))
  (let* ((provided (elx-provided source))
         (required (elx-required-packages source provided))
         (version-raw (elx-version mainfile))
         (version (version-to-list version-raw))
         (prev (or prev (make-elx-pkg)))
         meta)
    (elx-with-file mainfile
      (setq meta
            (make-elx-pkg :version version
                          :version-raw version-raw
                          :summary (elx-summary nil t)
                          :created (elx-created mainfile)
                          :updated (elx-updated mainfile)
                          :license (elx-license)
                          :authors (elx-authors)
                          :maintainer (elx-maintainer)
                          :provides provided
                          :requires-hard (nth 0 required)
                          :requires-soft (nth 1 required)
                          :keywords (elx-keywords mainfile)
                          :homepage (elx-homepage mainfile)
                          :wikipage (elx-wikipage mainfile nil t)
                          :commentary (elx-commentary mainfile)))
      (cl-merge-struct 'elx-pkg prev meta))))

(defun elx-read-file (source)
  "Read `elx-pkg' data, as output by `cl-merge-pp'.

SOURCE is the file to read. Returns a `elx-pkg' structure if
successful."
  (let (str data)
    (when (file-regular-p source)
      (with-temp-buffer
        (insert-file-contents source)
        (setq str (buffer-string)))
      (when str
        (setq data (read str))))
    (apply 'make-elx-pkg data)))

(provide 'elx)
;;; elx.el ends here
