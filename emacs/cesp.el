;;; cesp.el --- Live-share client for Emacs         -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Wisdurm

;; Author: Wisdurm <wisdurm@TheEngineer.TWOFORT>
;; Keywords: comm, files

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Cesp is a protocol for facilitating cross-platform live file
;; editing. This package implements the protocol in Emacs.

;;; Code:

(require 'cesp-browse-mode)

;;; Public variables

(defgroup cespconf nil
  "Variables related to configuring Cesp"
  :group 'communication)

(defcustom cesp-name "Jaakko"
  "Your username on Cesp.
This is the name other users will see when
you are editing with them"
  :group 'cespconf
  :type '(string))

;;; Internal variables

(defvar cesp-is-host
  nil
  "Am I the host?")

(defvar cesp-server-process
  nil
  "The internal server process object.
This is the process object that represents
the connection to the tcp server")

(defvar cesp-cursors
  nil
  "An alist of other peoples cursors.
Cursors are overlays.
These will be shown, if you are in the
corresponding buffer.

Format is:
  (id . overlay )")

;;; Public commands

;;;; Connection management

(defun cesp-connect-server(host port owner)
  "Connects to a Cesp server.
This connects your Emacs session to a Cesp server
at HOST PORT, for example localhost 8080
which is the default for a Cesp server.

It will then perform the handshake, giving your
name as per the variable"
  (interactive
   (list (read-string "Server hostname: ")
		 (read-string "Server port: ")
		 (y-or-n-p "Become host if possible: ")))
  (if (or (not cesp-server-process) (not (process-live-p cesp-server-process)))
	  (progn
		(setq cesp-server-process (make-network-process
								 :name "cesp-process"
								 :buffer (get-buffer-create "*cesp*") ;; Don't think this does anything
								 :host host
								 :service port
								 :family 'ipv4 ;; TODO: Support for ipv6
								 :filter 'cesp--filter
								 :sentinel 'cesp--sentinel))
		;; Perform handshake
		(cesp--send `((event . "handshake") (name . "Jaakko") (host . ,(or owner
																		  :false)))))
	(error "You are already connected to a server!")))

(defun cesp-disconnect()
  "Disconnects Emacs from the Cesp server.
This will disconnect the Emacs from
the Cesp server it is currently connected to, if
any"
  (interactive)
  (if (and cesp-server-process (process-live-p cesp-server-process))
	  (delete-process "cesp-process")
	(error "You are not connected to a server!")))

;;;; File handling

(defun list-cesp-files()
  "Sends a request to get the host's files
This will send a request_files event to the host.
This function does not handle the response"
  (interactive)
  (if (and cesp-server-process (process-live-p cesp-server-process))
	  (cesp--send '((event . "request_files")))
	(error "You are not connected to a server!")))

(defun cesp-get-file(file)
  "Sends a request to get FILE from the host's computer.

This function may be used directly, or by cesp-browse-mode"
  (interactive "sFile path: ")
  (if (and cesp-server-process (process-live-p cesp-server-process))
	  (cesp--send `((event . "request_file") (path . ,file)))
	(error "You are not connected to a server!")))

;;; Internal functions

(defun cesp--send(json-object)
  "Sends the server a message formatted in Json.
This sends JSON to the Cesp server, which will then
forward the message accordingly to other clients or
the host.

JSON is an object that is parsed by json-serialize
into a string.
"
  (process-send-string cesp-server-process (concat (json-serialize json-object) "\n")))

(defun cesp--get-files(dir)
  "Returns a list containing file names, recursively."
  (let ((file-list nil))
	(dolist (entry (directory-files-and-attributes dir) nil)
	  ;; Straight up ignore all hidden files, for now
	  (if (not (equal (aref (car entry) 0) ?.))
		  ;; If directory, recurse
		  ;; (also make sure not to recurse . or .. :D )
		  (if (and (car (cdr entry))
				   (not (equal (car entry) "."))
				   (not (equal (car entry) "..")))
			  (setq file-list (append file-list (cesp--get-files (concat dir "/" (car entry)) )))
			;; Otherwise, add to list
			(setq file-list (cons (concat dir "/" (car entry)) file-list)))))
	file-list))

(defun cesp--send-update(beg end len)
  "Sends an update_content event when buffer is updated."
  (let ((lines (vconcat (split-string (buffer-substring-no-properties beg end) "
" t))) ;; Newline regex
		(first (line-number-at-pos beg))
		(old_last (line-number-at-pos end)))
	(cesp--send `((event . "update_content") (path . ,(buffer-name))
				  (changes . ((first . ,first) (old_last . ,old_last) (lines . ,lines))) ))))

(remove-hook 'after-change-functions 'cesp--send-update)
(add-hook 'after-change-functions 'cesp--send-update)
  
;;;; Handlers

(defun cesp--filter(proc msg)
  "Main function which parses Cesp input.
This function recieves all of the date recieved
by the tcp connection, and calls other functions,
as appropriate."
  (message "STRING: %s :STRING"  msg)
  ;; Split by newlines since sometimes multiple messages
  ;; come at once :shrug: Maybe TODO message buffer?
  (dolist (string (split-string msg "
" t) ) ;; Newline regex :DDDD
	(message "MESSAGE: %s" string)
	;; Event handling
	(let* ((json (json-parse-string string
									:object-type 'alist
									:array-type 'list))
		   (event (cdr (assoc 'event json))))
	  (message (concat "Event is: " event))
	  (cond
	   ((string= "response_files" event)
		;; TODO: Check if already open, and if so, just update
		(cesp--open-file-manager (cdr (assoc 'files json)) )
		)
	   ((string= "response_file" event)
		(cesp--open-remote-file
		 (cdr (assoc 'path json))
		 (cdr (assoc 'content json))))
	   ((string= "update_content" event)
		(cesp--update-content
		 (cdr (assoc 'path json))
		 (cdr (assoc 'changes json))))
	   ((string= "cursor_move" event)
		(cesp--render-cursor
		 (cdr (assoc 'from_id json))
		 (cdr (assoc 'position json))
		 (cdr (assoc 'path json))
		 (cdr (assoc 'name json))))
	   ((string= "handshake_response" event)
		(or (and (cdr (assoc 'is_host json))
				 (setq cesp-is-host t))
			(setq cesp-is-host nil)))
	   ))))

(defun cesp--sentinel(proc msg)
  "Sentinel function which handless statues changes in connection."
  (if (string= msg "connection broken by remote peer\n")
      (message (format "client %s has quit" proc))
	(message (concat "SENTINEL MESSAGE: "  msg))))

(defun cesp--open-file-manager(files)
  "Handler function which opens a Cesp file browser.
This will open a new window in cesp-browse-mode, where you
can browse files on the host's computer, and open them in
new buffers

FILES should be a list of file paths (strings)."
  (let ((file-window  (split-window-horizontally)))
	(set-window-buffer file-window (get-buffer "*scratch*"))
	(save-window-excursion ;; Set major mode
	  (select-window file-window)
	  (cesp-browse-mode)
	  ;; Convert file list into tabulated data
	  (setq tabulated-list-entries nil)
	  (dolist (file files nil)
		(setq tabulated-list-entries (cons (list
											nil (vector "Jaakko Pekka" file)
											)
										   tabulated-list-entries)))
	  (tabulated-list-print) ;; This doesn't seem very appropriate...
	  ;; I'm not sure where else to do this though, since it's
	  ;; hard to pass the data to the major mode startup
	  )))


(defun cesp--open-remote-file(path content)
  "Handler functon which opens a buffer with CONTENT.
This will create a buffer with the Cesp minor mode
instantiated, which means the buffers contents are
synchronized across the Cesp server.

If the buffer already exists, this will refresh the
contents."
  (switch-to-buffer (get-buffer-create path))
  ;; Replace everything
  (kill-region (point-min) (point-max))
  (insert content))

(defun cesp--render-cursor(id position buffer name)
  "Renders cursor ID at POSITION in BUFFER.
ID is unique id for cursor, POSITION is a list
with a column and row. NAME is rendered next to the
cursor.
The cursor is not rendered if you are not in the correct
buffer."
  (let ((buf (get-buffer buffer)))
	(if buf
		(let* ((pos (save-excursion ;; Get pos from column and row
					  (goto-char (point-min))
					  (forward-line (1- (car position)))
					  (forward-char (car (cdr position)))
					  (point)))
			   (overlay (or (cdr (assoc id cesp-cursors))
							(let ((o (make-overlay pos (1+ pos) buf)))
							  (overlay-put o 'face 'cursor)
							  (setq cesp-cursors (cons `(,id . ,o) cesp-cursors))
							  o))))
		  ;; Update values
		  (move-overlay overlay pos (1+ pos) buf)))))

(defun cesp--update-content(path changes)
  "Handler function which applies changes to a buffer.
If the specified buffer is not currently open, then
the changes are not applied.

CHANGES is a alist with the changes specified as such:
- first: First line (with 0 as the first line)
- old_last: Last line I guess?
- lines: List of lines the lines as they are now"
  (if (equal (buffer-name) path) ;; If correct buffer
	  (save-excursion ;; THIS ENTIRE BLOCK IS SUBJECT TO OPTIMIZATION
		(let ((beg (cdr (assoc 'first changes)) )
			  (end (cdr (assoc 'old_last changes)) )
			  (lines (cdr (assoc 'lines changes)) ))
		  ;; Goto first line
		  (goto-char (point-min))
		  (forward-line beg)
		  ;; Replace lines iteratively
		  (kill-line  (- end beg) )
		  (dolist (line lines)
			(insert (concat line "\n")))))))

;;; _
(provide 'cesp)
;;; cesp.el ends here
