# Questions about pankosmia-docker's auth model for Netlify proxy setup

Context: we are deploying the Pankosmia client apps as static files on
Netlify, with all API calls proxied back to the pankosmia-docker
backend on Railway (`pankosmia-web.up.railway.app`). The proxy is
transparent — the browser sees only the Netlify origin, never the
Railway origin directly.

This means the backend is accessed through a reverse proxy on a
different domain than where it actually runs.

We need to understand how the backend handles authentication and
session state so we can make this work.

---

## Questions

### Q1. How does the OAuth callback URL get constructed?

When the backend redirects the user to GitHub for OAuth
(`/auth/start` or equivalent), it includes a `redirect_uri`
parameter in the GitHub URL. How is this URL determined?

- Is it derived from the incoming request's `Host` header?
- Is it from an env var (which one)?
- Is it hardcoded or configured in the GitHub App settings only?

We need to know this because with a Netlify proxy in front, the
`redirect_uri` must point back to the Netlify domain (e.g.,
`https://your-site.netlify.app/auth/callback`), not to the Railway
domain directly. Otherwise, after GitHub auth, the browser lands on
Railway's domain and the session cookie is scoped to the wrong
origin.

### Q2. How are sessions stored and scoped?

After successful OAuth, how does the backend track "this user is
logged in"?

- Cookie-based session? If so:
  - What is the cookie name?
  - Does it set an explicit `Domain=` attribute?
  - Does it set `SameSite`? (`Lax`, `Strict`, or `None`?)
  - Is `Secure` set?
  - Is `HttpOnly` set?
- Token in a header? (e.g., the client stores a token and sends it
  via `Authorization: Bearer ...`)
- Something else?

This matters because with a proxy, cookies set by the backend
arrive at the browser via Netlify. The browser associates them with
the Netlify domain (good), but only if the backend doesn't
explicitly scope them to its own Railway domain (bad). If there's
an explicit `Domain=pankosmia-web.up.railway.app`, the browser
will reject the cookie.

### Q3. Is there a "public origin" env var?

Is there an env var like `PANKOSMIA_PUBLIC_ORIGIN` or
`PANKOSMIA_BASE_URL` or `PUBLIC_URL` that controls:

- The OAuth redirect_uri construction
- The cookie domain
- Any absolute URLs in responses (e.g., `pr_url` in save responses
  is fine — those point to GitHub, not the backend)

If so, what is the var name and what does it affect?

### Q4. What is the GitHub App's callback URL configuration?

In the GitHub App settings on github.com, there is a "Callback URL"
field. What is it currently set to? It needs to match wherever the
OAuth redirect_uri points.

If we change the redirect_uri to point to the Netlify domain, the
GitHub App's callback URL must also allow the Netlify domain.
GitHub Apps support multiple callback URLs — we may need to add the
Netlify one alongside the existing Railway one.

### Q5. Can the backend serve multiple origins?

Will we need the backend to work behind both:

- Direct access at `https://pankosmia-web.up.railway.app`
  (for the Docker-bundled clients already there)
- Proxied access via `https://your-site.netlify.app`
  (for the Netlify-hosted clients)

If yes, how should the backend decide which origin to use for the
OAuth redirect_uri? Options:

- Use the `Origin` or `Referer` header from the request
- Use a `X-Forwarded-Host` header that the proxy sets
- Have separate `/auth/start?redirect_origin=...` parameter
- Have one fixed public origin and accept that only one works

### Q6. Alternative: stateless auth via query parameter

If cookie-based sessions through a proxy turn out to be
complicated, would the backend support (or could it be extended to
support) a simpler model:

- After OAuth, the backend returns a short-lived token (JWT or
  opaque) in the redirect URL
- The client stores it in localStorage
- The client sends it on every request as a query parameter
  (`?token=...`) or header (`Authorization: Bearer ...`)

This would sidestep all cookie/domain/proxy issues entirely. The
clients would need a small change to attach the token, but no
server-side cookie scoping problems.

---

## What we need to decide

The ideal outcome is one of:

**A. Cookie sessions work through the proxy with minimal config.**
The backend sets cookies without an explicit `Domain=`, and has an
env var to control the OAuth redirect_uri. We set that var to the
Netlify URL, add the Netlify URL to the GitHub App's callback URLs,
and everything works.

**B. Token-based auth.** The backend issues a token after OAuth, the
client includes it on requests. No cookies, no domain scoping
issues, works through any proxy.

**C. Hybrid.** Cookie sessions for the Railway-direct path,
token-based for the proxy path. More complex but supports both
access patterns.

Option A is simplest if the backend already works that way. Option
B is most robust for the proxy case. Please describe what the
backend does today and we can figure out the best path.

---

## Answers (from reading pankosmia-docker source)

### A1. OAuth callback URL construction

Controlled by the env var **`PANKOSMIA_PUBLIC_ORIGIN`**
(`src/auth/oauth_flow.rs:34-39`):

```rust
fn server_origin() -> String {
    std::env::var("PANKOSMIA_PUBLIC_ORIGIN")
        .unwrap_or_else(|_| "http://127.0.0.1:19119".into())
}

fn callback_url() -> String {
    format!("{}/auth/callback", server_origin())
}
```

The `redirect_uri` sent to GitHub is
`{PANKOSMIA_PUBLIC_ORIGIN}/auth/callback`. It is **not** derived from
the incoming request's `Host` header. Set this env var to the Netlify
domain and the redirect will point there.

### A2. Sessions: cookie-based, no explicit Domain

Cookie-based, using Rocket's private (encrypted+signed) cookies
(`src/auth/session.rs`):

| Attribute   | Value |
|-------------|-------|
| Cookie name | `pankosmia_session` (encrypted by Rocket, so the browser sees a different wire name) |
| Value       | GitHub user-id (integer), encrypted server-side via `ROCKET_SECRET_KEY` |
| `Domain=`   | **Not set** — the browser scopes it to the origin that set it |
| `SameSite`  | `Lax` |
| `Secure`    | `true` when `PANKOSMIA_PUBLIC_ORIGIN` starts with `https://`, else `false` |
| `HttpOnly`  | `true` |
| `Path`      | `/` |

There is also a transient `pankosmia_oauth_state` cookie (same
attributes) used only during the OAuth CSRF round-trip.

The OAuth access token is **never sent to the browser**. It is stored
server-side in an AES-GCM encrypted file at
`<workspace>/.pankosmia/users/<github_user_id>/token.bin`, keyed by
`PANKOSMIA_TOKEN_ENCRYPTION_KEY` (base64-encoded 32-byte key).

**Good news for the proxy setup:** because no explicit `Domain=` is
set, cookies will be scoped to whichever origin the browser sees —
i.e. the Netlify domain when proxied.

### A3. Public origin env var

Yes: **`PANKOSMIA_PUBLIC_ORIGIN`**. It controls:

1. The OAuth `redirect_uri` construction (the callback URL sent to
   GitHub).
2. Whether cookies get the `Secure` flag (checks if the origin starts
   with `https://`).
3. **It does not set a cookie `Domain=`** — that is left to the
   browser's default scoping.

No other env var controls absolute URL generation. Response bodies
like `pr_url` point to GitHub, not the backend.

### A4. GitHub App callback URL configuration

The callback URL is configured in the GitHub OAuth App settings (the
OAuth portion of the GitHub App). The callback URL there must match or
allow the `redirect_uri` the server sends. Steps:

1. Add the Netlify URL (e.g.
   `https://your-site.netlify.app/auth/callback`) as an allowed
   callback URL in the GitHub App settings.
2. Set `PANKOSMIA_PUBLIC_ORIGIN=https://your-site.netlify.app` on
   Railway.

GitHub Apps support multiple callback URLs, so you can keep the
Railway one alongside the Netlify one if needed.

### A5. Multiple origins: implemented

The backend now supports multiple origins via
`PANKOSMIA_ALLOWED_ORIGINS` (comma-separated). The `ResolvedOrigin`
request guard reads `X-Forwarded-Host` (+ `X-Forwarded-Proto`) or
`Origin` from each request, validates against the allowlist, and
uses the matched origin to construct the OAuth callback URL.
`PANKOSMIA_PUBLIC_ORIGIN` is always included as a fallback.

Each allowed origin must be registered as a callback URL in the
GitHub App settings (`https://<origin>/auth/callback`).

### A6. Stateless token-based auth: possible but probably unnecessary

The current model already keeps the OAuth token server-side — the
session cookie is just a signed pointer to the GitHub user-id. Adding
a `Bearer` token fallback to `AuthUser` would be ~15 lines of code,
but cookie-based auth should work through the proxy without issues
because:

- No explicit `Domain=` is set.
- `SameSite=Lax` allows the GitHub OAuth redirect back.
- `Secure` is auto-derived from `PANKOSMIA_PUBLIC_ORIGIN`.

---

## Conclusion: Option A works, with multi-origin support

The backend supports Option A with full multi-origin OAuth. All
code changes are implemented. What remains is configuration.

---

## Backend setup checklist (for the operator)

The following env vars must be set on Railway. Items marked
**verify** may already be set from the initial deployment.

### Required env vars on Railway

| Env var | Action | How to generate |
|---------|--------|-----------------|
| `PANKOSMIA_PUBLIC_ORIGIN` | Set to the primary public URL (Railway or Netlify) | e.g. `https://pankosmia-web.up.railway.app` |
| `PANKOSMIA_ALLOWED_ORIGINS` | **New.** Comma-separated list of all origins that need OAuth | e.g. `https://your-site.netlify.app,https://pankosmia-web.up.railway.app` |
| `ROCKET_SECRET_KEY` | **Verify** it is set and stable across deploys | `openssl rand -base64 32` (generate once, never change) |
| `PANKOSMIA_TOKEN_ENCRYPTION_KEY` | **Verify** it is set and stable across deploys | `openssl rand -base64 32` (generate once, never change) |
| `GITHUB_CLIENT_ID` | **Verify** — from the GitHub App's OAuth section | Copy from GitHub App settings |
| `GITHUB_CLIENT_SECRET` | **Verify** — from the GitHub App's OAuth section | Copy from GitHub App settings |
| `STORAGE_BACKEND` | **Verify** it is `github` | — |

### GitHub App settings (github.com)

Add a callback URL for each origin that needs OAuth:

```
https://your-site.netlify.app/auth/callback
https://pankosmia-web.up.railway.app/auth/callback
```

GitHub Apps support multiple callback URLs. Go to the App's
settings page → "Callback URL" and add one line per origin.

### pankosmia-docker repo

Commit and push the multi-origin OAuth change (2 files:
`src/auth/oauth_flow.rs`, `src/auth/session.rs`) so it gets into
the next Docker image build. CI will rebuild and Railway will
redeploy automatically.

### Netlify side (desktop-app-template)

The `netlify.toml` proxy rules are already configured — no changes
needed. All API paths (`/auth/*`, `/me`, `/burrito/*`,
`/settings/*`, `/navigation/*`, `/app-state/*`, `/git/*`,
`/notifications`) are proxied to the Railway backend.

### Verification steps

After deploying:

1. Visit `https://your-site.netlify.app/auth/start` — should
   redirect to GitHub for authorization.
2. After authorizing, you should land back on the Netlify domain
   (not Railway).
3. Visit `https://your-site.netlify.app/me` — should return your
   GitHub profile JSON.
4. If also testing Railway direct: visit
   `https://pankosmia-web.up.railway.app/auth/start` — should
   also complete the OAuth flow and land back on Railway.

---

## Complete backend API route reference

Every route the pankosmia-docker backend exposes, grouped by mount
prefix. Use this to verify `netlify.toml` proxy rules are complete.

### Root-mounted (`/`)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Redirect to dashboard |
| GET | `/favicon.ico` | Favicon |
| GET | `/list-clients` | List registered clients |
| GET | `/client-interfaces` | Client interface definitions |
| GET | `/client-config` | Client configuration |
| GET | `/version` | Server version |
| GET | `/health` | Healthcheck (200 when ready, 503 otherwise) |
| GET | `/auth/start?redirect=...` | Start GitHub OAuth flow |
| GET | `/auth/callback?code=...&state=...` | OAuth callback (GitHub redirects here) |
| POST | `/auth/logout` | Clear session |
| GET | `/me` | Current user's GitHub profile |
| POST | `/webhook/catalog` | Catalog webhook (GitHub → server) |
| POST | `/webhook/language/<code>` | Per-language webhook (GitHub → server) |

### `/notifications`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/notifications` | SSE event stream (content changes) |

### `/settings`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/settings/languages` | Get user's selected languages |
| POST | `/settings/languages/<languages..>` | Set selected languages |
| GET | `/settings/auth-token/<token_key>/<code>/<client_code>` | Exchange auth token |
| GET | `/settings/typography` | Get typography settings |
| POST | `/settings/typography/<font_set>/<size>/<direction>` | Set typography |
| POST | `/settings/typography-feature/<font_name>/<feature>/<new_value>` | Set a typography feature |

### `/navigation`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/navigation/bcv` | Get current BCV cursor |
| POST | `/navigation/bcv/<book_code>/<chapter>/<verse>` | Set BCV cursor |

### `/app-state`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/app-state/current-project` | Get current project |
| POST | `/app-state/current-project/<source>/<org>/<project>` | Set current project |
| POST | `/app-state/current-project` | Clear current project |

### `/i18n`

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/i18n/` | Post i18n data (JSON body) |
| GET | `/i18n/raw` | Raw i18n strings |
| GET | `/i18n/negotiated/<filter..>` | Negotiated i18n |
| GET | `/i18n/flat/<filter..>` | Flat i18n |
| GET | `/i18n/untranslated/<lang>` | Untranslated strings for a language |
| GET | `/i18n/used-languages` | Languages used in i18n |

### `/burrito`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/burrito/ingredient/raw/<repo_path..>?ipath=...` | Read text ingredient (+ SSE watch variant) |
| GET | `/burrito/ingredients/raw/<repo_path..>?ipath=...` | Read multiple text ingredients |
| GET | `/burrito/ingredient/bytes/<repo_path..>?ipath=...` | Read binary ingredient |
| GET | `/burrito/ingredient/zipped/<repo_path..>?ipath=...` | Read ingredient(s) as zip |
| POST | `/burrito/ingredient/raw/<repo_path..>?ipath=...&update_ingredients&no_bak` | Write text ingredient |
| POST | `/burrito/ingredient/bytes/<repo_path..>?ipath=...` | Write binary ingredient (multipart) |
| POST | `/burrito/ingredient/zipped/<repo_path..>?ipath=...` | Write ingredient(s) from zip (multipart) |
| POST | `/burrito/ingredient/delete/<repo_path..>?ipath=...` | Delete one ingredient |
| POST | `/burrito/ingredients/delete/<repo_path..>?ipath=...` | Delete multiple ingredients |
| POST | `/burrito/ingredient/copy/<repo_path..>?src_path&target_path&delete_src` | Copy/move ingredient |
| POST | `/burrito/ingredient/revert/<repo_path..>?ipath=...` | Revert ingredient to HEAD |
| GET | `/burrito/metadata/raw/<repo_path..>` | Raw metadata.json |
| GET | `/burrito/metadata/summary/<repo_path..>` | Summary metadata |
| GET | `/burrito/metadata/summaries?org=...` | All metadata summaries |
| POST | `/burrito/metadata/remake-ingredients/<repo_path..>` | Rebuild ingredients metadata |
| GET | `/burrito/paths/<repo_path..>` | List file paths in repo |
| GET | `/burrito/audit/<repo_path..>` | Audit a burrito repo |
| GET | `/burrito/zipped/<repo_path..>` | Download repo as zip |
| POST | `/burrito/zipped/<repo_path..>` | Upload repo from zip (multipart) |
| POST | `/burrito/remake_burrito_from_zip/<temp_id>/<repo_path..>` | Rebuild burrito from temp zip |

### `/git`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/git/list-local-repos` | List local repos |
| GET | `/git/status/<repo_path..>` | Git status |
| GET | `/git/log/<repo_path..>` | Git log |
| GET | `/git/branches/<repo_path..>` | List branches |
| GET | `/git/remotes/<repo_path..>` | List remotes |
| POST | `/git/clone-repo/<repo_path..>?branch=...` | Clone a repo |
| POST | `/git/delete/<repo_path..>` | Delete a local repo |
| POST | `/git/add-and-commit/<repo_path..>` | Add + commit (JSON body) |
| POST | `/git/push/<repo_path..>` | Push (JSON body) |
| POST | `/git/pull-repo/<remote_name>/<repo_path..>` | Pull from remote |
| POST | `/git/branch/<branch_ref>/<repo_path..>` | Switch branch |
| POST | `/git/new-branch/<branch_ref>/<repo_path..>` | Create + switch branch |
| POST | `/git/remote/add/<repo_path..>?remote_name&remote_url` | Add remote |
| POST | `/git/remote/delete/<repo_path..>?remote_name` | Delete remote |
| POST | `/git/copy/<repo_path..>?target_path&delete_src&add_ignore` | Copy/move repo |
| POST | `/git/new-text-translation` | Create text translation repo (JSON) |
| POST | `/git/new-bcv-resource` | Create BCV resource repo (JSON) |
| POST | `/git/new-bcv-resource-book/<repo_path..>` | Add scripture book (JSON) |
| POST | `/git/new-obs-resource` | Create OBS resource repo (JSON) |
| POST | `/git/new-scripture-book/<repo_path..>` | Add scripture book (JSON) |
| POST | `/git/new-tcore-resource` | Create tCore resource repo (JSON) |
| POST | `/git/new-translation-plan-resource` | Create translation plan repo (JSON) |

### `/gitea`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/gitea/remote-repos/<server>/<org>` | List org repos on a Gitea server |
| GET | `/gitea/user-remote-repos/<server>/<user>` | List user repos on Gitea |
| GET | `/gitea/endpoints` | Get configured Gitea endpoints |
| GET | `/gitea/login/<token_key>/<redir_path..>` | Gitea proxy login |
| GET | `/gitea/logout/<token_key>` | Gitea proxy logout |
| GET | `/gitea/my-collaborators/<proxy>/<org>/<project>` | List collaborators |

### `/content-utils`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/content-utils/templates` | List content templates |
| GET | `/content-utils/metadata-template/<name>` | Get a metadata template |
| GET | `/content-utils/template-filenames/<template>` | List template filenames |
| GET | `/content-utils/template/<name>/<filename>` | Get a template file |
| GET | `/content-utils/versifications` | List versifications |
| GET | `/content-utils/versification/<name>` | Get a versification |
| GET | `/content-utils/product?resource_path=...` | Product content catalog |

### `/admin`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/admin/pending-prs?language=...` | List pending PRs for review |
| GET | `/admin/pr-files?language&pr` | List files in a PR |
| POST | `/admin/approve?language&pr&method` | Approve + merge a PR |
| POST | `/admin/reject?language&pr&reason` | Reject (close) a PR |

### `/temp`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/temp/bytes/<temp_id>` | Read a temp file |
| POST | `/temp/bytes` | Write a temp file (multipart) |

### `/llm`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/llm/model` | List available LLM models |
| POST | `/llm/rag-prompt` | RAG prompt (JSON body) |

### `/video`

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/video/obs-para/<repo_path..>` | Generate OBS para video (JSON) |
| POST | `/video/obs-story/<repo_path..>` | Generate OBS story video (JSON) |

### `/net`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/net/status` | Network mode status |
| POST | `/net/enable` | Enable network |
| POST | `/net/disable` | Disable network |

### `/debug`

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/debug/status` | Debug mode status |
| GET | `/debug/enable` | Enable debug |
| GET | `/debug/disable` | Disable debug |

### Static file mounts

| Path prefix | Source |
|-------------|--------|
| `/webfonts/` | Webfont CSS + font files |
| `/app-resources/` | App resources (themes, product config) |
| `/clients/<name>/` | Per-client static build output |

### Webhooks (server-to-server, not proxied)

The `/webhook/catalog` and `/webhook/language/<code>` endpoints
are called by GitHub, not by the browser. They do NOT need proxy
rules — GitHub calls the Railway URL directly.

---

## Missing proxy rules in netlify.toml

Comparing the route list above against the current `netlify.toml`,
these prefixes are **not yet proxied** and should be added if the
corresponding features are needed:

| Prefix | Needed? | Notes |
|--------|---------|-------|
| `/gitea/*` | Only if using Gitea integration | Desktop/legacy feature; may not apply to hosted mode |
| `/content-utils/*` | **Yes** | Content templates and versifications, used by editors |
| `/admin/*` | **Yes** | PR review panel (approve/reject PRs) |
| `/temp/*` | **Yes** | Temp file upload/download, used during zip import |
| `/llm/*` | Only if LLM features are enabled | RAG prompts |
| `/video/*` | Only if OBS video features are used | OBS video generation |
| `/debug/*` | Optional | Debug toggle; may want to omit in production |
| `/version` | Nice to have | Server version endpoint |
| `/health` | Nice to have | Healthcheck; useful for monitoring |

Add these to `netlify.toml` as needed:

```toml
# Content utilities (templates, versifications)
[[redirects]]
  from = "/content-utils/*"
  to = "https://pankosmia-web.up.railway.app/content-utils/:splat"
  status = 200

# Admin panel (PR review)
[[redirects]]
  from = "/admin/*"
  to = "https://pankosmia-web.up.railway.app/admin/:splat"
  status = 200

# Temp file storage
[[redirects]]
  from = "/temp/*"
  to = "https://pankosmia-web.up.railway.app/temp/:splat"
  status = 200

# Version + health
[[redirects]]
  from = "/version"
  to = "https://pankosmia-web.up.railway.app/version"
  status = 200

[[redirects]]
  from = "/health"
  to = "https://pankosmia-web.up.railway.app/health"
  status = 200
```
