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

(defvar cesp-server-process
  nil
  "The internal server process object.
This is the process object that represents
the connection to the tcp server")

;;; Public commands

;;;; Connection management

(defun cesp-connect-server(host port)
  "Connects to a Cesp server.
This connects your Emacs session to a Cesp server
at HOST PORT, for example localhost 8080
which is the default for a Cesp server.

It will then perform the handshake, giving your
name as per the variable"
  (interactive "sServer hostname: \nsServer port: ")
  (setq cesp-server-process (make-network-process
   :name "cesp-process"
   :buffer (get-buffer-create "*cesp*") ;; Don't think this does anything
   :host host
   :service port
   :family 'ipv4 ;; TODO: Support for ipv6
   :filter 'cesp--filter
   :sentinel 'cesp--sentinel))
  ;; Perform handshake
  (cesp--client-forward '((event . "handshake") (name . "Jaakko")) ))

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
	  (cesp--client-forward '((event . "request_files")))
	(error "You are not connected to a server!")))

;;; Internal functions

(defun cesp--client-forward(json-object)
  "Client sends the host a message formatted in Json.
This sends JSON to the host from a client connection.
Clients will only ever directly message the host.

JSON is an object that is parsed by json-serialize
into a string.
"
  (process-send-string cesp-server-process (concat (json-serialize json-object) "\n")))

;;;; Handlers

(defun cesp--filter(proc string)
  "Main function which parses Cesp input.
This function recieves all of the date recieved
by the tcp connection, and calls other functions,
as appropriate."
  (message string)
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
	  ))))

(defun cesp--sentinel(proc msg)
  "Sentinel function which handless statues changes in connection."
  (if (string= msg "connection broken by remote peer\n")
      (message (format "client %s has quit" proc))
	(message msg)))

(defun cesp--open-file-manager(files)
  "Handler function which opens a Cesp file browser.
This will open a new window in cesp-browse-mode, where you
can browse files on the host's computer, and open them in
new buffers

FILES should be a list of file paths (strings).
"
  (let (
		(file-window  (split-window-horizontally))
		)
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
										   tabulated-list-entries))
		)
	  (tabulated-list-print) ;; This doesn't seem very appropriate...
	  ;; I'm not sure where else to do this though, since it's
	  ;; hard to pass the data to the major mode startup
	  )))
;(cesp--open-file-manager (list "asdf" "moi"))
;;; _
(provide 'cesp)
;;; cesp.el ends here
