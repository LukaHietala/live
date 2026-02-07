;;; cesp-browse-mode.el --- Major mode for Cesp file browsing  -*- lexical-binding: t; -*-
;;; Commentary:
;; Major mode to facilitate a user interface for browsing files on the host's computer.
;;
;;; Code:

;;; Variables

;;; Functions

(defun cesp-browse--open()
  "Open the file at the current mouse position"
  (interactive)
  (message "Hello :D"))

;;; Define the mode

(defvar cesp-browse-mode-map
  (let ((map (make-sparse-keymap)))
	(define-key map (kbd "O") #'cesp-browse--open)
	map)
  "Keymap for 'cesp-browse-mode'.")

;;;###autoload
(define-derived-mode cesp-browse-mode tabulated-list-mode "cesp-browse"
  "Major mode for browsing host files with Cesp"
  :interactive nil
  (setq tabulated-list-format
			  [("Name" 10 t)
			   ("Path" 10 t)])
  (tabulated-list-init-header))
;; Tabulated list data and calling is done in the main function,
;; since I cant come up with a smart way to pass the data over
;; here. A future refactor is a promising proposal.

(provide 'cesp-browse-mode)
;;; cesp-browse-mode.el ends here
