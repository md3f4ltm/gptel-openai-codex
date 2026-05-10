#!/usr/bin/env node
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { dirname } from "node:path";
import { spawn } from "node:child_process";

const CALLBACK_HOST = process.env.GPTEL_OPENAI_CODEX_CALLBACK_HOST || "127.0.0.1";
const CALLBACK_PORT = Number(process.env.GPTEL_OPENAI_CODEX_CALLBACK_PORT || 1455);
const REDIRECT_URI = `http://localhost:${CALLBACK_PORT}/auth/callback`;
const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL = "https://auth.openai.com/oauth/token";
const SCOPE = "openid profile email offline_access";
const JWT_CLAIM_PATH = "https://api.openai.com/auth";

function authFile() {
  const file = process.env.GPTEL_OPENAI_CODEX_AUTH_FILE;
  if (!file) throw new Error("GPTEL_OPENAI_CODEX_AUTH_FILE is not set");
  return file;
}

function base64url(buffer) {
  return Buffer.from(buffer)
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function makePkce() {
  const verifier = base64url(randomBytes(32));
  const challenge = base64url(createHash("sha256").update(verifier).digest());
  return { verifier, challenge };
}

function decodeJwtPayload(token) {
  try {
    const payload = token.split(".")[1];
    if (!payload) return null;
    return JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

function accountIdFromAccessToken(access) {
  const payload = decodeJwtPayload(access);
  const accountId = payload?.[JWT_CLAIM_PATH]?.chatgpt_account_id;
  if (typeof accountId !== "string" || accountId.length === 0) {
    throw new Error("Could not extract ChatGPT account id from access token");
  }
  return accountId;
}

function buildAuthUrl(state, challenge, originator = "gptel") {
  const url = new URL(AUTHORIZE_URL);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", CLIENT_ID);
  url.searchParams.set("redirect_uri", REDIRECT_URI);
  url.searchParams.set("scope", SCOPE);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  url.searchParams.set("id_token_add_organizations", "true");
  url.searchParams.set("codex_cli_simplified_flow", "true");
  url.searchParams.set("originator", originator);
  return url.toString();
}

function parseAuthorizationInput(input) {
  const value = input.trim();
  if (!value) return {};
  try {
    const url = new URL(value);
    return {
      code: url.searchParams.get("code") ?? undefined,
      state: url.searchParams.get("state") ?? undefined,
    };
  } catch {
    // Not a URL.
  }
  if (value.includes("#")) {
    const [code, state] = value.split("#", 2);
    return { code, state };
  }
  if (value.includes("code=")) {
    const params = new URLSearchParams(value);
    return {
      code: params.get("code") ?? undefined,
      state: params.get("state") ?? undefined,
    };
  }
  return { code: value };
}

function promptLine(message) {
  process.stdout.write(`${message} `);
  process.stdin.setEncoding("utf8");
  return new Promise((resolve) => {
    process.stdin.once("data", (chunk) => resolve(String(chunk).trim()));
  });
}

function openUrl(url) {
  const opener =
    process.env.BROWSER ? [process.env.BROWSER, [url]] :
    process.platform === "darwin" ? ["open", [url]] :
    process.platform === "win32" ? ["cmd", ["/c", "start", "", url]] :
    ["xdg-open", [url]];

  const child = spawn(opener[0], opener[1], { detached: true, stdio: "ignore" });
  child.unref();
}

function html(title, body) {
  return `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title></head><body><h2>${title}</h2><p>${body}</p></body></html>`;
}

function waitForCallback(expectedState) {
  let settle;
  const done = new Promise((resolve) => {
    settle = resolve;
  });

  const server = createServer((req, res) => {
    try {
      const url = new URL(req.url || "", REDIRECT_URI);
      if (url.pathname !== "/auth/callback") {
        res.writeHead(404, { "content-type": "text/html; charset=utf-8" });
        res.end(html("OpenAI Codex login failed", "Callback route not found."));
        return;
      }
      const state = url.searchParams.get("state");
      const code = url.searchParams.get("code");
      if (state !== expectedState) {
        res.writeHead(400, { "content-type": "text/html; charset=utf-8" });
        res.end(html("OpenAI Codex login failed", "OAuth state mismatch."));
        settle(null);
        return;
      }
      if (!code) {
        res.writeHead(400, { "content-type": "text/html; charset=utf-8" });
        res.end(html("OpenAI Codex login failed", "Missing authorization code."));
        settle(null);
        return;
      }
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(html("OpenAI Codex login complete", "You can close this window and return to Emacs."));
      settle({ code, state });
    } catch {
      res.writeHead(500, { "content-type": "text/html; charset=utf-8" });
      res.end(html("OpenAI Codex login failed", "Internal callback error."));
      settle(null);
    }
  });

  return new Promise((resolve) => {
    server
      .listen(CALLBACK_PORT, CALLBACK_HOST, () => {
        console.log(`Waiting for browser callback on http://${CALLBACK_HOST}:${CALLBACK_PORT}/auth/callback`);
        resolve({
          close: () => server.close(),
          wait: () => done,
        });
      })
      .on("error", (error) => {
        console.error(`Could not listen on ${CALLBACK_HOST}:${CALLBACK_PORT}: ${error.message}`);
        resolve({
          close: () => server.closeAllConnections?.(),
          wait: async () => null,
        });
      });
  });
}

async function exchangeToken(params) {
  const response = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params),
  });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`Token request failed (${response.status}): ${text}`);
  }
  const json = await response.json();
  if (!json.access_token || !json.refresh_token || typeof json.expires_in !== "number") {
    throw new Error(`Token response missing expected fields: ${JSON.stringify(json)}`);
  }
  const access = json.access_token;
  return {
    access,
    refresh: json.refresh_token,
    expires: Date.now() + json.expires_in * 1000,
    accountId: accountIdFromAccessToken(access),
  };
}

async function writeAuth(file, credentials) {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  await writeFile(
    file,
    `${JSON.stringify({ ...credentials, updatedAt: Date.now() }, null, 2)}\n`,
    { mode: 0o600 },
  );
  await chmod(file, 0o600).catch(() => {});
}

async function login() {
  const file = authFile();
  const { verifier, challenge } = makePkce();
  const state = randomBytes(16).toString("hex");
  const server = await waitForCallback(state);
  const url = buildAuthUrl(state, challenge);

  console.log("Starting OpenAI Codex browser login for gptel.");
  console.log("This writes a separate token file, not ~/.codex/auth.json.");
  console.log(url);
  openUrl(url);

  let callback = await server.wait();
  if (!callback?.code) {
    const input = await promptLine("Paste the authorization code or full redirect URL:");
    const parsed = parseAuthorizationInput(input);
    if (parsed.state && parsed.state !== state) throw new Error("OAuth state mismatch");
    callback = { code: parsed.code, state: parsed.state };
  }
  server.close();

  if (!callback?.code) throw new Error("Missing authorization code");

  const credentials = await exchangeToken({
    grant_type: "authorization_code",
    client_id: CLIENT_ID,
    code: callback.code,
    code_verifier: verifier,
    redirect_uri: REDIRECT_URI,
  });
  await writeAuth(file, credentials);
  console.log(`OpenAI Codex auth saved to ${file}`);
}

async function refresh() {
  const file = authFile();
  const existing = JSON.parse(await readFile(file, "utf8"));
  if (!existing.refresh) throw new Error(`No refresh token in ${file}`);
  const credentials = await exchangeToken({
    grant_type: "refresh_token",
    refresh_token: existing.refresh,
    client_id: CLIENT_ID,
  });
  await writeAuth(file, credentials);
  console.log(`OpenAI Codex auth refreshed at ${file}`);
}

const command = process.argv[2];

try {
  if (command === "login") await login();
  else if (command === "refresh") await refresh();
  else {
    console.error("Usage: gptel-openai-codex-auth.mjs <login|refresh>");
    process.exitCode = 64;
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
