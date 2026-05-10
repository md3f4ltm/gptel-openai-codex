;;; gptel-openai-codex.el --- OpenAI Codex backend for gptel -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Micael Medeiros
;; Author: Micael Medeiros <md3f4ltm@users.noreply.github.com>
;; Maintainer: Micael Medeiros <md3f4ltm@users.noreply.github.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.8"))
;; Keywords: ai, tools
;; URL: https://github.com/md3f4ltm/gptel-openai-codex

;;; Commentary:

;; OpenAI Codex browser-login backend for gptel.  It uses a separate OAuth token
;; file for gptel instead of reusing the Codex CLI session.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'gptel-openai-responses)

(cl-defstruct (gptel-openai-codex (:constructor gptel--make-openai-codex)
                                  (:copier nil)
                                  (:include gptel-openai-responses)))

(defgroup gptel-openai-codex nil
  "OpenAI Codex browser-login support for gptel."
  :group 'gptel)

(defcustom gptel-openai-codex-auth-file
  (expand-file-name "gptel/openai-codex-auth.json"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "gptel OpenAI Codex browser-login auth file."
  :type 'file
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-node-command "node"
  "Node.js command used to run the OpenAI Codex browser-login helper."
  :type 'file
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-helper
  (expand-file-name
   "gptel-openai-codex-auth.mjs"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Node.js helper used for OpenAI Codex browser login and token refresh."
  :type 'file
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-refresh-margin 300
  "Refresh Codex browser-login tokens this many seconds before expiry."
  :type 'integer
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-default-instructions
  "You are a helpful assistant."
  "Default instructions for OpenAI Codex browser-login requests."
  :type 'string
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-use-codex-cli-auth nil
  "When non-nil, fall back to ~/.codex/auth.json if gptel has no token."
  :type 'boolean
  :group 'gptel-openai-codex)

(defconst gptel-openai-codex-host "chatgpt.com")
(defconst gptel-openai-codex-endpoint "/backend-api/codex/responses")

(defconst gptel-openai-codex-models
  '((gpt-5.5 :description "OpenAI Codex GPT-5.5"
             :capabilities (media tool-use json url responses-api))
    (gpt-5.5-pro :description "OpenAI Codex GPT-5.5 Pro"
                 :capabilities (media tool-use json url responses-api))
    (gpt-5.4 :description "OpenAI Codex GPT-5.4"
             :capabilities (media tool-use json url responses-api))
    (gpt-5.4-pro :description "OpenAI Codex GPT-5.4 Pro"
                 :capabilities (media tool-use json url responses-api))
    (gpt-5.4-mini :description "OpenAI Codex GPT-5.4 Mini"
                  :capabilities (media tool-use json url responses-api))
    (gpt-5.3-codex :description "OpenAI Codex GPT-5.3"
                   :capabilities (media tool-use json url responses-api))
    (gpt-5.2-codex :description "OpenAI Codex GPT-5.2"
                   :capabilities (media tool-use json url responses-api)))
  "Known OpenAI Codex browser-login models.")

(defun gptel-openai-codex--json-read-file (file)
  "Read JSON object from FILE as an alist."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (with-temp-buffer
      (insert-file-contents file)
      (json-read))))

(defun gptel-openai-codex--codex-cli-auth-file ()
  "Return the Codex CLI auth file path."
  (expand-file-name "auth.json" (or (getenv "CODEX_HOME") "~/.codex")))

(defun gptel-openai-codex--base64url-decode-string (string)
  "Base64url decode STRING."
  (let* ((base64 (replace-regexp-in-string
                  "_" "/"
                  (replace-regexp-in-string "-" "+" string)))
         (padding (mod (- 4 (mod (length base64) 4)) 4)))
    (base64-decode-string (concat base64 (make-string padding ?=)))))

(defun gptel-openai-codex--auth ()
  "Read OpenAI Codex browser-login auth data."
  (cond
   ((file-readable-p gptel-openai-codex-auth-file)
    (gptel-openai-codex--json-read-file gptel-openai-codex-auth-file))
   (gptel-openai-codex-use-codex-cli-auth
    (let ((file (gptel-openai-codex--codex-cli-auth-file)))
      (unless (file-readable-p file)
        (user-error "No readable Codex CLI auth file at %s; run `codex login' or `M-x gptel-openai-codex-login'"
                    file))
      (gptel-openai-codex--json-read-file file)))
   (t
    (user-error "No gptel OpenAI Codex auth at %s; run `M-x gptel-openai-codex-login'"
                gptel-openai-codex-auth-file))))

(defun gptel-openai-codex--jwt-expiry (jwt)
  "Return JWT expiry from JWT as epoch seconds, or nil."
  (when (and (stringp jwt) (string-match-p "\\`[^.]+\\.[^.]+\\.[^.]+\\'" jwt))
    (let* ((payload (cadr (split-string jwt "\\.")))
           (json-object-type 'alist)
           (json-array-type 'list)
           (json-key-type 'symbol)
           (decoded (ignore-errors
                      (gptel-openai-codex--base64url-decode-string payload)))
           (parsed (and decoded (ignore-errors (json-read-from-string decoded))))
           (exp (alist-get 'exp parsed)))
      (when (numberp exp) exp))))

(defun gptel-openai-codex--token-expiring-p (token)
  "Non-nil when TOKEN is missing or near expiry."
  (let ((exp (gptel-openai-codex--jwt-expiry token)))
    (or (not (stringp token))
        (string-empty-p token)
        (and exp
             (< (- exp (float-time)) gptel-openai-codex-refresh-margin)))))

(defun gptel-openai-codex--auth-expiring-p (auth token)
  "Non-nil when AUTH or TOKEN is missing or near expiry."
  (let ((expires (alist-get 'expires auth)))
    (or (gptel-openai-codex--token-expiring-p token)
        (and (numberp expires)
             (< (- (/ expires 1000.0) (float-time))
                gptel-openai-codex-refresh-margin)))))

(defun gptel-openai-codex--call-helper (command)
  "Run OpenAI Codex auth helper COMMAND synchronously."
  (unless (executable-find gptel-openai-codex-node-command)
    (user-error "Cannot find Node.js command `%s'"
                gptel-openai-codex-node-command))
  (unless (file-readable-p gptel-openai-codex-helper)
    (user-error "Cannot read OpenAI Codex auth helper at %s"
                gptel-openai-codex-helper))
  (let ((process-environment
         (cons (concat "GPTEL_OPENAI_CODEX_AUTH_FILE="
                       (expand-file-name gptel-openai-codex-auth-file))
               process-environment)))
    (with-temp-buffer
      (let ((status (call-process gptel-openai-codex-node-command nil t nil
                                  gptel-openai-codex-helper command)))
        (unless (zerop status)
          (user-error "OpenAI Codex auth helper failed: %s"
                      (string-trim (buffer-string))))))))

;;;###autoload
(defun gptel-openai-codex-login ()
  "Start OpenAI Codex browser login for gptel."
  (interactive)
  (unless (executable-find gptel-openai-codex-node-command)
    (user-error "Cannot find Node.js command `%s'"
                gptel-openai-codex-node-command))
  (unless (file-readable-p gptel-openai-codex-helper)
    (user-error "Cannot read OpenAI Codex auth helper at %s"
                gptel-openai-codex-helper))
  (let* ((buffer (get-buffer-create "*gptel OpenAI Codex login*"))
         (process-environment
          (cons (concat "GPTEL_OPENAI_CODEX_AUTH_FILE="
                        (expand-file-name gptel-openai-codex-auth-file))
                process-environment)))
    (with-current-buffer buffer
      (erase-buffer)
      (special-mode))
    (pop-to-buffer buffer)
    (make-process
     :name "gptel-openai-codex-login"
     :buffer buffer
     :command (list gptel-openai-codex-node-command
                    gptel-openai-codex-helper
                    "login")
     :sentinel
     (lambda (_process event)
       (when (string-match-p "\\(?:finished\\|exited\\)" event)
         (message "gptel OpenAI Codex login %s" (string-trim event)))))))

;;;###autoload
(defun gptel-openai-codex-refresh ()
  "Refresh gptel OpenAI Codex browser-login credentials."
  (interactive)
  (gptel-openai-codex--call-helper "refresh"))

;;;###autoload
(defun gptel-openai-codex-logout ()
  "Delete gptel OpenAI Codex browser-login credentials."
  (interactive)
  (when (and (file-exists-p gptel-openai-codex-auth-file)
             (yes-or-no-p (format "Delete %s? "
                                  gptel-openai-codex-auth-file)))
    (delete-file gptel-openai-codex-auth-file)
    (message "Deleted %s" gptel-openai-codex-auth-file)))

(defun gptel-openai-codex-access-token ()
  "Return a fresh Codex browser-login access token."
  (let* ((auth (gptel-openai-codex--auth))
         (tokens (alist-get 'tokens auth))
         (access-token (or (alist-get 'access auth)
                           (alist-get 'access_token tokens))))
    (when (gptel-openai-codex--auth-expiring-p auth access-token)
      (gptel-openai-codex-refresh)
      (setq auth (gptel-openai-codex--auth)
            tokens (alist-get 'tokens auth)
            access-token (or (alist-get 'access auth)
                             (alist-get 'access_token tokens))))
    (unless (and (stringp access-token) (not (string-empty-p access-token)))
      (user-error "No OpenAI Codex browser-login access token found; run `M-x gptel-openai-codex-login'"))
    access-token))

(defun gptel-openai-codex--content-type (role)
  "Return Codex content type for ROLE."
  (if (equal role "assistant") "output_text" "input_text"))

(defun gptel-openai-codex--content-part (part role)
  "Return Codex-compatible content PART for ROLE."
  (if (and (listp part) (plist-member part :type))
      (let ((copy (copy-sequence part)))
        (when (member (plist-get copy :type) '("input_text" "output_text"))
          (plist-put copy :type (gptel-openai-codex--content-type role)))
        copy)
    part))

(defun gptel-openai-codex--input-content (content role)
  "Return Codex-compatible input CONTENT for ROLE."
  (cond
   ((stringp content)
    (vector (list :type (gptel-openai-codex--content-type role)
                  :text content)))
   ((vectorp content)
    (vconcat
     (mapcar (lambda (part)
               (gptel-openai-codex--content-part part role))
             (append content nil))))
   ((listp content)
    (vconcat
     (mapcar (lambda (part)
               (gptel-openai-codex--content-part part role))
             content)))
   (t content)))

(defun gptel-openai-codex--input-item (item)
  "Return a Codex-compatible input ITEM."
  (if (and (listp item) (plist-member item :content))
      (let ((copy (copy-sequence item))
            (role (plist-get item :role)))
        (plist-put copy :content
                   (gptel-openai-codex--input-content
                    (plist-get copy :content)
                    role))
        copy)
    item))

(cl-defmethod gptel--request-data ((_backend gptel-openai-codex) _prompts)
  "JSON encode PROMPTS for sending to the OpenAI Codex endpoint."
  (let ((data (cl-call-next-method)))
    (unless (plist-get data :instructions)
      (plist-put data :instructions gptel-openai-codex-default-instructions))
    (plist-put data :store :json-false)
    (plist-put data :stream t)
    (cl-remf data :max_output_tokens)
    (cl-remf data :temperature)
    (when-let* ((input (plist-get data :input)))
      (plist-put data :input
                 (vconcat
                  (mapcar #'gptel-openai-codex--input-item
                          (append input nil)))))
    data))

;;;###autoload
(cl-defun gptel-make-openai-codex
    (name &key curl-args (models gptel-openai-codex-models)
          stream request-params
          (host gptel-openai-codex-host)
          (protocol "https")
          (endpoint gptel-openai-codex-endpoint)
          (header
           (lambda (_info)
             `(("Authorization" . ,(concat "Bearer "
                                           (gptel-openai-codex-access-token)))
               ("OpenAI-Beta" . "responses=experimental")))))
  "Register an OpenAI Codex browser-login backend for gptel with NAME."
  (declare (indent 1))
  (let ((backend (gptel--make-openai-codex
                  :curl-args curl-args
                  :name name
                  :host host
                  :header header
                  :key #'gptel-openai-codex-access-token
                  :models (gptel--process-models models)
                  :protocol protocol
                  :endpoint endpoint
                  :stream (or stream t)
                  :request-params request-params
                  :url (if protocol
                           (concat protocol "://" host endpoint)
                         (concat host endpoint)))))
    (prog1 backend
      (setf (alist-get name gptel--known-backends
                       nil nil #'equal)
            backend))))

(provide 'gptel-openai-codex)
;;; gptel-openai-codex.el ends here
