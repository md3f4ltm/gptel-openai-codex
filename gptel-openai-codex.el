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
(require 'browse-url)
(require 'json)
(require 'subr-x)
(require 'transient nil t)
(require 'url)
(require 'url-util)
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
  "Gptel OpenAI Codex browser-login auth file."
  :type 'file
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-refresh-margin 300
  "Refresh Codex browser-login tokens this many seconds before expiry."
  :type 'integer
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-callback-host "127.0.0.1"
  "Host for the local OpenAI Codex browser-login callback server."
  :type 'string
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-callback-port 1455
  "Port for the local OpenAI Codex browser-login callback server."
  :type 'integer
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-default-instructions
  "You are a helpful assistant."
  "Default instructions for OpenAI Codex browser-login requests."
  :type 'string
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-reasoning-effort nil
  "Default reasoning effort for OpenAI Codex requests.

When nil, omit the reasoning effort field and let the service choose its
default.  Non-nil values are sent as `reasoning.effort'."
  :type '(choice (const :tag "Service default" nil)
                 (const :tag "Low" "low")
                 (const :tag "Medium" "medium")
                 (const :tag "High" "high")
                 (const :tag "Extra high" "xhigh"))
  :group 'gptel-openai-codex)

(defcustom gptel-openai-codex-use-codex-cli-auth nil
  "When non-nil, fall back to ~/.codex/auth.json if gptel has no token."
  :type 'boolean
  :group 'gptel-openai-codex)

(defconst gptel-openai-codex-host "chatgpt.com")
(defconst gptel-openai-codex-endpoint "/backend-api/codex/responses")
(defconst gptel-openai-codex--client-id "app_EMoamEEZ73f0CkXaXp7hrann")
(defconst gptel-openai-codex--authorize-url
  "https://auth.openai.com/oauth/authorize")
(defconst gptel-openai-codex--token-url "https://auth.openai.com/oauth/token")
(defconst gptel-openai-codex--scope "openid profile email offline_access")
(defconst gptel-openai-codex--jwt-claim-path "https://api.openai.com/auth")

(defconst gptel-openai-codex-models
  '((gpt-5.5 :description "OpenAI Codex GPT-5.5"
             :capabilities (reasoning media tool-use json url responses-api))
    (gpt-5.5-pro :description "OpenAI Codex GPT-5.5 Pro"
                 :capabilities (reasoning media tool-use json url responses-api))
    (gpt-5.4 :description "OpenAI Codex GPT-5.4"
             :capabilities (reasoning media tool-use json url responses-api))
    (gpt-5.4-pro :description "OpenAI Codex GPT-5.4 Pro"
                 :capabilities (reasoning media tool-use json url responses-api))
    (gpt-5.4-mini :description "OpenAI Codex GPT-5.4 Mini"
                  :capabilities (reasoning media tool-use json url responses-api))
    (gpt-5.3-codex :description "OpenAI Codex GPT-5.3"
                   :capabilities (reasoning media tool-use json url responses-api))
    (gpt-5.2-codex :description "OpenAI Codex GPT-5.2"
                   :capabilities (reasoning media tool-use json url responses-api)))
  "Known OpenAI Codex browser-login models.")

(defconst gptel-openai-codex-reasoning-efforts
  '("low" "medium" "high" "xhigh")
  "Reasoning effort values accepted by OpenAI Codex.")

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

(defun gptel-openai-codex--base64url-encode-string (string)
  "Base64url encode STRING."
  (replace-regexp-in-string
   "=" ""
   (replace-regexp-in-string
    "/" "_"
    (replace-regexp-in-string
     "\\+" "-"
     (base64-encode-string string t)))))

(defun gptel-openai-codex--random-bytes (length)
  "Return LENGTH pseudo-random bytes as a unibyte string."
  (apply #'unibyte-string
         (cl-loop repeat length collect (random 256))))

(defun gptel-openai-codex--make-pkce ()
  "Return a plist with PKCE verifier and challenge."
  (let* ((verifier
          (gptel-openai-codex--base64url-encode-string
           (gptel-openai-codex--random-bytes 32)))
         (challenge
          (gptel-openai-codex--base64url-encode-string
           (secure-hash 'sha256 verifier nil nil t))))
    (list :verifier verifier :challenge challenge)))

(defun gptel-openai-codex--redirect-uri ()
  "Return the OAuth redirect URI."
  (format "http://localhost:%d/auth/callback"
          gptel-openai-codex-callback-port))

(defun gptel-openai-codex--auth-url (state challenge)
  "Return the OpenAI authorization URL for STATE and PKCE CHALLENGE."
  (concat
   gptel-openai-codex--authorize-url
   "?"
   (url-build-query-string
    `(("response_type" "code")
      ("client_id" ,gptel-openai-codex--client-id)
      ("redirect_uri" ,(gptel-openai-codex--redirect-uri))
      ("scope" ,gptel-openai-codex--scope)
      ("code_challenge" ,challenge)
      ("code_challenge_method" "S256")
      ("state" ,state)
      ("id_token_add_organizations" "true")
      ("codex_cli_simplified_flow" "true")
      ("originator" "gptel")))))

(defun gptel-openai-codex--parse-authorization-input (input)
  "Parse an authorization code and state from INPUT."
  (let ((value (string-trim input)))
    (cond
     ((string-empty-p value) nil)
     ((string-match-p "\\`https?://" value)
      (let* ((url (url-generic-parse-url value))
             (query (url-filename url))
             (query (when (string-match "\\?\\(.*\\)" query)
                      (match-string 1 query)))
             (params (and query (url-parse-query-string query))))
        (list :code (cadr (assoc "code" params))
              :state (cadr (assoc "state" params)))))
     ((string-match "\\`\\([^#]+\\)#\\(.+\\)\\'" value)
      (list :code (match-string 1 value)
            :state (match-string 2 value)))
     ((string-match-p "code=" value)
      (let ((params (url-parse-query-string value)))
        (list :code (cadr (assoc "code" params))
              :state (cadr (assoc "state" params)))))
     (t (list :code value)))))

(defun gptel-openai-codex--callback-response (title body)
  "Return a small HTML callback page with TITLE and BODY."
  (format (concat "HTTP/1.1 200 OK\r\n"
                  "Content-Type: text/html; charset=utf-8\r\n"
                  "Connection: close\r\n\r\n"
                  "<!doctype html><html><head><meta charset=\"utf-8\">"
                  "<title>%s</title></head><body><h2>%s</h2><p>%s</p>"
                  "</body></html>")
          title title body))

(defun gptel-openai-codex--callback-request (request)
  "Return a plist describing OAuth callback REQUEST."
  (let* ((path (and (string-match "\\`GET \\([^ ]+\\) HTTP/" request)
                    (match-string 1 request)))
         (query (and path
                     (string-match "\\?\\(.*\\)" path)
                     (match-string 1 path)))
         (params (and query (url-parse-query-string query))))
    (list :path path
          :code (cadr (assoc "code" params))
          :state (cadr (assoc "state" params)))))

(defun gptel-openai-codex--start-callback-server (state callback)
  "Start an OAuth callback server for STATE.

CALLBACK is called with the authorization code on success, or nil and an error
message on failure.  This function returns immediately with the server process."
  (let (server done)
    (setq
     server
     (make-network-process
      :name "gptel-openai-codex-callback"
      :server t
      :host gptel-openai-codex-callback-host
      :service gptel-openai-codex-callback-port
      :noquery t
      :filter
      (lambda (process string)
        (process-put process 'request
                     (concat (or (process-get process 'request) "")
                             string))
        (when (and (not done)
                   (string-match "\r?\n\r?\n"
                                 (process-get process 'request)))
          (setq done t)
          (let* ((parsed
                  (gptel-openai-codex--callback-request
                   (process-get process 'request)))
                 (path (plist-get parsed :path))
                 (received-state (plist-get parsed :state))
                 (code (plist-get parsed :code))
                 error)
            (cond
             ((not (and path (string-prefix-p "/auth/callback" path)))
              (setq error "Callback route not found.")
              (process-send-string
               process
               (gptel-openai-codex--callback-response
                "OpenAI Codex login failed" error)))
             ((not (equal received-state state))
              (setq error "OAuth state mismatch.")
              (process-send-string
               process
               (gptel-openai-codex--callback-response
                "OpenAI Codex login failed" error)))
             ((not code)
              (setq error "Missing authorization code.")
              (process-send-string
               process
               (gptel-openai-codex--callback-response
                "OpenAI Codex login failed" error)))
             (t
              (process-send-string
               process
               (gptel-openai-codex--callback-response
                "OpenAI Codex login complete"
                "You can close this window and return to Emacs."))))
            (delete-process process)
            (when (process-live-p server)
              (delete-process server))
            (funcall callback code error))))))
    (message "Waiting for browser callback on http://%s:%d/auth/callback"
             gptel-openai-codex-callback-host
             gptel-openai-codex-callback-port)
    server))

(defun gptel-openai-codex--jwt-account-id (access)
  "Return the ChatGPT account id from ACCESS."
  (let* ((payload (cadr (split-string access "\\.")))
         (json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'string)
         (decoded (and payload
                       (gptel-openai-codex--base64url-decode-string payload)))
         (parsed (and decoded (json-read-from-string decoded)))
         (auth (cdr (assoc gptel-openai-codex--jwt-claim-path parsed)))
         (account-id (cdr (assoc "chatgpt_account_id" auth))))
    (unless (and (stringp account-id) (not (string-empty-p account-id)))
      (user-error "Could not extract ChatGPT account id from access token"))
    account-id))

(defun gptel-openai-codex--exchange-token (params)
  "Exchange OAuth PARAMS for OpenAI Codex credentials."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/x-www-form-urlencoded")))
         (url-request-data (url-build-query-string params))
         (buffer (url-retrieve-synchronously
                  gptel-openai-codex--token-url t t 30)))
    (unless buffer
      (user-error "Token request failed"))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (let ((status (and (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                             (string-to-number (match-string 1)))))
            (unless (and status (<= 200 status 299))
              (user-error "Token request failed (%s): %s"
                          (or status "unknown")
                          (string-trim (buffer-substring-no-properties
                                        (point-min) (point-max))))))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (user-error "Token response missing body"))
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (json (json-read))
                 (access (alist-get 'access_token json))
                 (refresh (alist-get 'refresh_token json))
                 (expires-in (alist-get 'expires_in json)))
            (unless (and (stringp access)
                         (stringp refresh)
                         (numberp expires-in))
              (user-error "Token response missing expected fields"))
            (list (cons 'access access)
                  (cons 'refresh refresh)
                  (cons 'expires (+ (* (float-time) 1000)
                                    (* expires-in 1000)))
                  (cons 'accountId
                        (gptel-openai-codex--jwt-account-id access)))))
      (kill-buffer buffer))))

(defun gptel-openai-codex--exchange-token-async (params callback)
  "Exchange OAuth PARAMS asynchronously.

CALLBACK is called with credentials on success, or nil and an error message on
failure."
  (let ((url-request-method "POST")
        (url-request-extra-headers
         '(("Content-Type" . "application/x-www-form-urlencoded")))
        (url-request-data (url-build-query-string params)))
    (url-retrieve
     gptel-openai-codex--token-url
     (lambda (status)
       (unwind-protect
           (condition-case error
               (if-let* ((url-error (plist-get status :error)))
                   (funcall callback nil (format "%S" url-error))
                 (goto-char (point-min))
                 (let ((http-status
                        (and (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                             (string-to-number (match-string 1)))))
                   (unless (and http-status (<= 200 http-status 299))
                     (user-error "Token request failed (%s): %s"
                                 (or http-status "unknown")
                                 (string-trim
                                  (buffer-substring-no-properties
                                   (point-min) (point-max))))))
                 (unless (re-search-forward "\r?\n\r?\n" nil t)
                   (user-error "Token response missing body"))
                 (let* ((json-object-type 'alist)
                        (json-array-type 'list)
                        (json-key-type 'symbol)
                        (json (json-read))
                        (access (alist-get 'access_token json))
                        (refresh (alist-get 'refresh_token json))
                        (expires-in (alist-get 'expires_in json)))
                   (unless (and (stringp access)
                                (stringp refresh)
                                (numberp expires-in))
                     (user-error "Token response missing expected fields"))
                   (funcall
                    callback
                    (list (cons 'access access)
                          (cons 'refresh refresh)
                          (cons 'expires (+ (* (float-time) 1000)
                                            (* expires-in 1000)))
                          (cons 'accountId
                                (gptel-openai-codex--jwt-account-id access)))
                    nil)))
             (error
              (funcall callback nil (error-message-string error))))
         (kill-buffer (current-buffer))))
     nil t t)))

(defun gptel-openai-codex--write-auth (credentials)
  "Write CREDENTIALS to `gptel-openai-codex-auth-file'."
  (make-directory (file-name-directory gptel-openai-codex-auth-file) t)
  (with-temp-file gptel-openai-codex-auth-file
    (let ((json-encoding-pretty-print t))
      (insert (json-encode (append credentials
                                   `((updatedAt . ,(* (float-time) 1000)))))
              "\n")))
  (set-file-modes gptel-openai-codex-auth-file #o600))

;;;###autoload
(defun gptel-openai-codex-login ()
  "Start OpenAI Codex browser login for gptel."
  (interactive)
  (random t)
  (let* ((pkce (gptel-openai-codex--make-pkce))
         (state (secure-hash 'sha256
                             (concat (gptel-openai-codex--random-bytes 16)
                                     (format "%s" (current-time)))))
         (url (gptel-openai-codex--auth-url
               state (plist-get pkce :challenge))))
    (message "Starting OpenAI Codex browser login for gptel.")
    (condition-case error
        (progn
          (gptel-openai-codex--start-callback-server
           state
           (lambda (code callback-error)
             (if callback-error
                 (message "OpenAI Codex login failed: %s" callback-error)
               (gptel-openai-codex--exchange-token-async
                `(("grant_type" "authorization_code")
                  ("client_id" ,gptel-openai-codex--client-id)
                  ("code" ,code)
                  ("code_verifier" ,(plist-get pkce :verifier))
                  ("redirect_uri" ,(gptel-openai-codex--redirect-uri)))
                (lambda (credentials token-error)
                  (if token-error
                      (message "OpenAI Codex token exchange failed: %s"
                               token-error)
                    (gptel-openai-codex--write-auth credentials)
                    (message "OpenAI Codex auth saved to %s"
                             gptel-openai-codex-auth-file)))))))
          (browse-url url))
      (file-error
       (message "%s" (error-message-string error))
       (let* ((input (read-string
                      "Paste the authorization code or redirect URL: "))
              (parsed (gptel-openai-codex--parse-authorization-input input))
              (received-state (plist-get parsed :state))
              (code (plist-get parsed :code)))
         (when (and received-state (not (equal received-state state)))
           (user-error "OAuth state mismatch"))
         (unless code
           (user-error "Missing authorization code"))
         (gptel-openai-codex--exchange-token-async
          `(("grant_type" "authorization_code")
            ("client_id" ,gptel-openai-codex--client-id)
            ("code" ,code)
            ("code_verifier" ,(plist-get pkce :verifier))
            ("redirect_uri" ,(gptel-openai-codex--redirect-uri)))
          (lambda (credentials token-error)
            (if token-error
                (message "OpenAI Codex token exchange failed: %s" token-error)
              (gptel-openai-codex--write-auth credentials)
              (message "OpenAI Codex auth saved to %s"
                       gptel-openai-codex-auth-file)))))))))

;;;###autoload
(defun gptel-openai-codex-refresh ()
  "Refresh gptel OpenAI Codex browser-login credentials."
  (interactive)
  (let* ((auth (gptel-openai-codex--json-read-file
                gptel-openai-codex-auth-file))
         (refresh (alist-get 'refresh auth)))
    (unless (and (stringp refresh) (not (string-empty-p refresh)))
      (user-error "No refresh token in %s" gptel-openai-codex-auth-file))
    (gptel-openai-codex--write-auth
     (gptel-openai-codex--exchange-token
      `(("grant_type" "refresh_token")
        ("refresh_token" ,refresh)
        ("client_id" ,gptel-openai-codex--client-id))))
    (message "OpenAI Codex auth refreshed at %s"
             gptel-openai-codex-auth-file)))

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

(defun gptel-openai-codex--normalize-reasoning-effort (effort)
  "Return normalized reasoning EFFORT, or nil for service default."
  (cond
   ((or (null effort) (eq effort :json-false)) nil)
   ((symbolp effort) (symbol-name effort))
   ((stringp effort) effort)
   (t (user-error "Invalid OpenAI Codex reasoning effort: %S" effort))))

(defun gptel-openai-codex--reasoning (effort)
  "Return request reasoning object for EFFORT."
  (when-let* ((normalized
               (gptel-openai-codex--normalize-reasoning-effort effort)))
    (unless (member normalized gptel-openai-codex-reasoning-efforts)
      (user-error "Invalid OpenAI Codex reasoning effort `%s'; expected one of: %s"
                  normalized
                  (string-join gptel-openai-codex-reasoning-efforts ", ")))
    (list :effort normalized)))

(defun gptel-openai-codex--current-reasoning-effort ()
  "Return the currently effective OpenAI Codex reasoning effort."
  (if (plist-member gptel--request-params :reasoning)
      (gptel-openai-codex--normalize-reasoning-effort
       (map-nested-elt gptel--request-params '(:reasoning :effort)))
    (or (gptel-openai-codex--normalize-reasoning-effort
         (map-nested-elt (and (boundp 'gptel-backend)
                              (gptel-backend-request-params gptel-backend))
                         '(:reasoning :effort)))
        (gptel-openai-codex--normalize-reasoning-effort
         gptel-openai-codex-reasoning-effort))))

(defun gptel-openai-codex--reasoning-effort-description ()
  "Return the transient menu description for Codex reasoning effort."
  (format "Codex reasoning effort (%s)"
          (or (gptel-openai-codex--current-reasoning-effort)
              "default")))

;;;###autoload
(defun gptel-openai-codex-set-reasoning-effort (effort)
  "Set OpenAI Codex reasoning EFFORT for the current buffer.

The setting is stored in buffer-local `gptel--request-params', so it overrides
the package default and backend default for requests sent from this buffer.
Choose \"default\" to remove the override."
  (interactive
   (list
    (let ((choice (completing-read
                   "OpenAI Codex reasoning effort: "
                   (cons "default" gptel-openai-codex-reasoning-efforts)
                   nil t nil nil
                   (or (gptel-openai-codex--normalize-reasoning-effort
                        (map-nested-elt gptel--request-params
                                        '(:reasoning :effort)))
                       "default"))))
      (unless (string= choice "default") choice))))
  (setq-local gptel--request-params
              (gptel--merge-plists
               gptel--request-params
               (list :reasoning
                     (or (gptel-openai-codex--reasoning effort)
                         :json-false))))
  (message "OpenAI Codex reasoning effort: %s" (or effort "service default")))

(defun gptel-openai-codex-setup-transient ()
  "Add OpenAI Codex options to `gptel-menu'."
  (transient-define-suffix gptel-openai-codex--suffix-reasoning-effort ()
    "Set OpenAI Codex reasoning effort from `gptel-menu'."
    :key "-R"
    :description #'gptel-openai-codex--reasoning-effort-description
    :if (lambda ()
          (and (boundp 'gptel-backend)
               (gptel-openai-codex-p gptel-backend)))
    (interactive)
    (call-interactively #'gptel-openai-codex-set-reasoning-effort))
  (transient-append-suffix
    'gptel-menu
    "-v"
    '(gptel-openai-codex--suffix-reasoning-effort)))

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
  "Encode request data for the OpenAI Codex endpoint."
  (let ((data (cl-call-next-method)))
    (unless (plist-get data :instructions)
      (plist-put data :instructions gptel-openai-codex-default-instructions))
    (unless (plist-member data :reasoning)
      (when-let* ((reasoning
                   (gptel-openai-codex--reasoning
                    gptel-openai-codex-reasoning-effort)))
        (plist-put data :reasoning reasoning)))
    (when (plist-member gptel--request-params :reasoning)
      (plist-put data :reasoning (plist-get gptel--request-params :reasoning)))
    (when (eq (plist-get data :reasoning) :json-false)
      (cl-remf data :reasoning))
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
(cl-defun gptel-openai-codex-make-backend
    (name &key curl-args (models gptel-openai-codex-models)
          stream request-params reasoning-effort
          (host gptel-openai-codex-host)
          (protocol "https")
          (endpoint gptel-openai-codex-endpoint)
          (header
           (lambda (_info)
             `(("Authorization" . ,(concat "Bearer "
                                           (gptel-openai-codex-access-token)))
               ("OpenAI-Beta" . "responses=experimental")))))
  "Register an OpenAI Codex browser-login backend named NAME.

CURL-ARGS, MODELS, STREAM, REQUEST-PARAMS, HOST, PROTOCOL,
ENDPOINT and HEADER are passed to the backend.

REASONING-EFFORT may be nil, \"low\", \"medium\", \"high\" or
\"xhigh\".  It is added to REQUEST-PARAMS unless that already
contains :reasoning."
  (declare (indent 1))
  (let* ((reasoning (gptel-openai-codex--reasoning reasoning-effort))
         (request-params
          (if (or (null reasoning) (plist-member request-params :reasoning))
              request-params
            (gptel--merge-plists request-params (list :reasoning reasoning))))
         (backend (gptel--make-openai-codex
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

(define-obsolete-function-alias
  'gptel-make-openai-codex
  #'gptel-openai-codex-make-backend
  "0.2.0")

(provide 'gptel-openai-codex)
;;; gptel-openai-codex.el ends here
