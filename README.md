# gptel-openai-codex

OpenAI Codex browser-login backend for [gptel](https://github.com/karthink/gptel).

This package lets gptel talk to the ChatGPT Codex responses endpoint with a
browser OAuth login. It stores its own token file and does not reuse
`~/.codex/auth.json` by default.

## Requirements

- Emacs 29.1 or newer
- gptel 0.9.8 or newer
- An OpenAI account with access to Codex models

## Installation

With `use-package` and `straight.el`:

```elisp
(use-package gptel-openai-codex
  :straight (:host github :repo "md3f4ltm/gptel-openai-codex")
  :after gptel
  :config
  (setq gptel-backend (gptel-make-openai-codex "OpenAI Codex" :stream t)
        gptel-model 'gpt-5.5
        gptel-default-model "gpt-5.5"
        gptel-stream t))
```

With `package-vc-install`:

```elisp
(package-vc-install
 '(gptel-openai-codex
   :url "https://github.com/md3f4ltm/gptel-openai-codex.git"))
```

Then configure gptel:

```elisp
(require 'gptel-openai-codex)

(setq gptel-backend (gptel-make-openai-codex "OpenAI Codex" :stream t)
      gptel-model 'gpt-5.5
      gptel-default-model "gpt-5.5"
      gptel-stream t)
```

To set a default reasoning effort for the backend:

```elisp
(setq gptel-backend
      (gptel-make-openai-codex "OpenAI Codex"
        :stream t
        :reasoning-effort "medium"))
```

You can also set it globally:

```elisp
(setq gptel-openai-codex-reasoning-effort "medium")
```

For one buffer, use `gptel-menu` and press `-R`, or run:

```text
M-x gptel-openai-codex-set-reasoning-effort
```

Valid values are `low`, `medium`, `high`, and `xhigh`.

## Login

Run:

```text
M-x gptel-openai-codex-login
```

The command starts a local callback server on `127.0.0.1:1455`, opens your
browser, and stores credentials in:

```text
~/.local/state/gptel/openai-codex-auth.json
```

Available auth commands:

- `M-x gptel-openai-codex-login`
- `M-x gptel-openai-codex-refresh`
- `M-x gptel-openai-codex-logout`

## Customization

```elisp
(setq gptel-openai-codex-auth-file
      (expand-file-name "gptel/openai-codex-auth.json"
                        (or (getenv "XDG_STATE_HOME") "~/.local/state")))

(setq gptel-openai-codex-callback-host "127.0.0.1")
(setq gptel-openai-codex-callback-port 1455)
```

By default the package does not fall back to Codex CLI auth. If you really want
that behavior:

```elisp
(setq gptel-openai-codex-use-codex-cli-auth t)
```

## Notes

This uses the OpenAI Codex browser-login flow and the ChatGPT Codex endpoint,
not the OpenAI API key flow.
