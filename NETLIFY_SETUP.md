# Netlify client deployment

This repo (`desktop-app-netlify`) hosts the Pankosmia client apps as
static sites on Netlify, pointing at a `pankosmia-docker` backend
running on Railway.

---

## Relationship to `desktop-app-template`

This repo is **not** a fork of `pankosmia/desktop-app-template`. It
was created by copying that repo and removing the `.git` directory.
The git history starts fresh. There is no upstream tracking
relationship — changes in `desktop-app-template` are not
automatically pulled here.

What was kept: the build scripts (`macos/scripts/`), `app_config.env`,
`buildSpec.json`, `globalBuildResources/`, and configuration files
that drive client assembly.

What was removed or is irrelevant: the `local_server/` Rust crate
(no server runs on Netlify), the `docker/` directory (no Docker
image is built), and Electron/macOS packaging (`buildResources/electron/`).

---

## Architecture

```
Browser
  │
  │  GET /clients/main/...          → Netlify CDN (static files)
  │  GET /webfonts/...              → Netlify CDN (static files)
  │  GET /burrito/metadata/...      → Netlify proxy → Railway backend
  │  POST /burrito/ingredient/...   → Netlify proxy → Railway backend
  │  GET /notifications             → Netlify proxy → Railway backend
  │  GET /auth/...                  → Netlify proxy → Railway backend
  │
  ▼
Netlify site
  ├── Static client builds under /clients/<name>/
  ├── Static assets under /webfonts/, /app_resources/, /templates/
  └── Proxy rewrites (netlify.toml) for all API paths → Railway
```

The clients use relative URLs (`fetch("/burrito/...")`) so they
resolve against the Netlify origin. Netlify's proxy rewrites
forward API calls to the Railway backend transparently. From
the browser's perspective everything is same-origin — no CORS
issues, no cross-origin cookie problems.

---

## Prerequisites

- Node.js 18+ and npm
- zsh (the build scripts use zsh)
- A Netlify account (free tier works)
- The Netlify CLI: `npm install -g netlify-cli`
- The Railway backend running at a known URL (e.g.,
  `https://pankosmia-web.up.railway.app`)

---

## Initial setup

### 1. Remove git history (if not already done)

```bash
cd desktop-app-netlify
rm -rf .git
git init
```

### 2. Clone sibling repos (assets + clients)

The build scripts expect the pankosmia client and asset repos as
siblings of this directory:

```
dev/bw/
├── desktop-app-netlify/     ← this repo
├── resource-core/           ← asset (cloned by clone.zsh)
├── webfonts-core/           ← asset (cloned by clone.zsh)
├── core-client-dashboard/   ← client (cloned by clone.zsh)
├── core-client-content/     ← client
├── core-client-i18n-editor/ ← client
├── core-client-remote-repos/← client
├── core-client-settings/    ← client
├── core-client-workspace/   ← client
├── core-contenthandler_obs/ ← client
├── core-contenthandler_version_manager/ ← client
└── core-contenthandler-generic/         ← client
```

Run the clone script:

```bash
cd macos/scripts
./clone.zsh
```

### 3. Build the clients

```bash
cd macos/scripts
./build_clients.zsh dev -d
```

This checks out the `dev` branch (falling back to `main`), runs
`npm ci && npm run build` for each client, and leaves the built
output inside each sibling repo's `build/` directory.

### 4. Assemble the Netlify publish directory

Run the assembly script (see §Assembly script below):

```bash
cd macos/scripts
./build_for_netlify.sh
```

This copies built clients + assets into `netlify_dist/` at the
repo root with the layout Netlify expects.

### 5. Configure the backend URL

Edit `netlify.toml` and set the Railway backend URL. The default
is `https://pankosmia-web.up.railway.app`. If your backend is at
a different URL, update every `to = "https://..."` line.

### 6. Configure authentication

The backend uses cookie-based sessions via GitHub OAuth. Three
things must be configured for auth to work through the Netlify
proxy:

**a) Set `PANKOSMIA_PUBLIC_ORIGIN` on Railway**

On the Railway service, set the env var:

```
PANKOSMIA_PUBLIC_ORIGIN=https://your-site.netlify.app
```

This controls the OAuth `redirect_uri` — after GitHub
authorization, the browser is redirected back to this origin.
It also controls whether cookies get the `Secure` flag (yes
when the origin starts with `https://`).

**b) Add the Netlify callback URL to the GitHub App**

In the GitHub App settings on github.com, add the Netlify
callback URL as an allowed redirect:

```
https://your-site.netlify.app/auth/callback
```

GitHub Apps support multiple callback URLs, so you can keep the
Railway one alongside the Netlify one if you want direct Railway
access to still work for OAuth (but see note below).

**c) Ensure `ROCKET_SECRET_KEY` is set on Railway**

Rocket uses this key to encrypt session cookies. It must be set
and stable across deploys — if it changes, all existing sessions
are invalidated.

If it's already set (it should be from the initial deployment),
no action needed.

**Multi-origin support:**

The backend supports multiple public origins via
`PANKOSMIA_ALLOWED_ORIGINS`. Set it to a comma-separated list:

```
PANKOSMIA_ALLOWED_ORIGINS=https://your-site.netlify.app,https://pankosmia-web.up.railway.app
```

The backend reads `X-Forwarded-Host` / `Origin` headers from each
request and validates them against this allowlist to construct the
correct OAuth callback URL. `PANKOSMIA_PUBLIC_ORIGIN` is always
included as a fallback. Each origin must also be registered as a
callback URL in the GitHub App settings.

### 7. Deploy to Netlify

First time:

```bash
cd ../..   # repo root
netlify init        # link to a Netlify site (or create one)
netlify deploy --dir=netlify_dist --prod
```

Subsequent deploys:

```bash
netlify deploy --dir=netlify_dist --prod
```

Or connect the repo to Netlify for automatic deploys on push. In
that case set the build command and publish directory in
`netlify.toml` (already configured — see the `[build]` section).

---

## netlify.toml

The `netlify.toml` at the repo root configures:

1. **Build settings** — command and publish directory.
2. **Proxy rewrites** — every server API path is proxied to the
   Railway backend. This is what makes the unmodified clients work.
3. **SPA fallback** — each client gets a fallback rule so that
   client-side routing works (refreshing a deep URL serves the
   client's `index.html`).

### Backend URL

The backend URL appears in every `[[redirects]]` block. To change
it, update the `BACKEND` placeholder or do a find-and-replace.

### Proxy paths

These API path prefixes are proxied:

| Path prefix | Purpose |
|---|---|
| `/burrito/*` | Content read/write (ingredients, metadata, paths) |
| `/notifications` | SSE change notifications |
| `/settings/*` | User settings (typography, etc.) |
| `/navigation/*` | Navigation state (BCV cursor) |
| `/app-state/*` | App state |
| `/auth/*` | GitHub OAuth flow |
| `/git/*` | Git operations (list repos, etc.) |
| `/me` | Current user identity |

All are `status = 200` (proxy), not `status = 301` (redirect).
This keeps the browser on the Netlify origin.

### SSE (Server-Sent Events)

The `/notifications` proxy passes through SSE streams. Netlify's
proxy supports streaming responses, so SSE works without special
configuration.

### Auth flow

The GitHub OAuth flow works through the proxy as follows:

1. Browser visits `https://your-site.netlify.app/auth/start`
2. Netlify proxies to Railway; the backend responds with a 302 to
   GitHub, with `redirect_uri=https://your-site.netlify.app/auth/callback`
   (resolved from the request's `Origin` header against `PANKOSMIA_ALLOWED_ORIGINS`)
3. Netlify passes the 302 through; browser goes to GitHub
4. User authorizes; GitHub redirects browser to
   `https://your-site.netlify.app/auth/callback?code=...`
5. Netlify proxies that to Railway; backend exchanges the code for
   an access token, stores the token server-side (encrypted on
   disk), and sets an encrypted session cookie
6. The cookie has no explicit `Domain=`, so the browser scopes it
   to the Netlify domain. `SameSite=Lax` allows the redirect.
   `Secure=true` because the origin is `https://`.
7. Subsequent API requests from the browser include the cookie;
   Netlify forwards it to Railway; the backend decrypts it to
   identify the user.

No client code changes are needed. The cookie flows through the
proxy transparently because it has no explicit domain.

---

## Assembly script

The assembly script (`macos/scripts/build_for_netlify.sh`) copies
built artifacts into the `netlify_dist/` directory:

```
netlify_dist/
├── clients/
│   ├── main/                ← core-client-dashboard build output
│   │   ├── index.html
│   │   ├── assets/
│   │   ├── favicon.ico
│   │   └── manifest.json
│   ├── content/             ← core-client-content
│   ├── i18n-editor/         ← core-client-i18n-editor
│   ├── download/            ← core-client-remote-repos
│   ├── settings/            ← core-client-settings
│   ├── core-local-workspace/← core-client-workspace
│   ├── core-contenthandler_obs/
│   ├── core-contenthandler_version_manager/
│   └── core-contenthandler-generic/
├── webfonts/
│   └── _webfonts.css + font files
├── app_resources/
│   ├── themes/default.json
│   ├── product/product.json
│   └── ...
├── templates/
│   └── i18n.json (patched)
└── _redirects               ← (optional, netlify.toml is preferred)
```

The directory names under `clients/` must match the `homepage`
field in each client's `package.json`:

| Client repo | `homepage` | Directory |
|---|---|---|
| `core-client-dashboard` | `/clients/main` | `clients/main/` |
| `core-client-content` | `/clients/content` | `clients/content/` |
| `core-client-i18n-editor` | `/clients/i18n-editor` | `clients/i18n-editor/` |
| `core-client-remote-repos` | `/clients/download` | `clients/download/` |
| `core-client-settings` | `/clients/settings` | `clients/settings/` |
| `core-client-workspace` | `/clients/core-local-workspace` | `clients/core-local-workspace/` |
| `core-contenthandler_obs` | `/clients/core-contenthandler_obs` | `clients/core-contenthandler_obs/` |
| `core-contenthandler_version_manager` | `/clients/core-contenthandler_version_manager` | `clients/core-contenthandler_version_manager/` |
| `core-contenthandler-generic` | `/clients/core-contenthandler-generic` | `clients/core-contenthandler-generic/` |

---

## Landing page

The Netlify site needs a root `index.html` at `/`. The pankosmia
server normally serves its own dashboard at `/`. Two options:

1. **Redirect `/` to `/clients/main/`** — add a redirect rule in
   `netlify.toml`. Simplest.
2. **Create a minimal landing page** — a static `index.html` that
   links to the available clients or auto-redirects to the
   dashboard.

The `netlify.toml` provided below uses option 1.

---

## Updating clients

To pick up new client versions:

```bash
cd macos/scripts
./build_clients.zsh dev -d    # pull + rebuild all clients
./build_for_netlify.sh        # reassemble netlify_dist/
cd ../..
netlify deploy --dir=netlify_dist --prod
```

Or if Netlify auto-deploys from this repo: commit the updated
`netlify_dist/` and push (if committing build output), or let the
Netlify build command run the scripts (if using Netlify CI).

---

## Files to keep from `desktop-app-template`

Essential:

- `app_config.env` — lists which clients and assets to build
- `buildSpec.json` — paths for the assembly step
- `globalBuildResources/` — favicon, theme, i18n patch, product config
- `macos/scripts/clone.zsh` — clones sibling repos
- `macos/scripts/build_clients.zsh` — builds all clients
- `macos/scripts/build_for_netlify.sh` — assembles `netlify_dist/` (new)
- `macos/scripts/build.js` — used by assembly to copy assets + patch i18n
- `netlify.toml` — Netlify configuration (new)
- `package.json` + `node_modules/` — npm deps for `build.js`
- `Rocket.toml` — not used by Netlify, but referenced by build.js

Can be removed (but not harmful to keep):

- `local_server/` — Rust server, not needed
- `docker/` — Docker build pipeline, not needed
- `buildResources/electron/` — Electron packaging, not needed
- `linux/`, `windows/` — other platform targets, not needed
- `docs/` — pankosmia-docker planning docs, not needed here

---

## Troubleshooting

### 401 on API calls after deploy

The `PANKOSMIA_PUBLIC_ORIGIN` on the Railway backend must match the
Netlify site URL. If it doesn't, the OAuth callback redirects to
the wrong origin and the session cookie isn't set for the Netlify
domain.

### SSE `/notifications` not streaming

Netlify's proxy has a 26-second timeout for the initial response.
SSE connections that don't send an event within 26 seconds may be
closed. The pankosmia backend sends a heartbeat comment every 15
seconds, which should keep the connection alive.

### Client shows blank page after refresh on a deep URL

Each client is a single-page app. The `netlify.toml` includes SPA
fallback rules that serve each client's `index.html` for any path
under its prefix. If a new client is added, add a corresponding
SPA fallback rule.

### `build_clients.zsh` fails on a client

Check that the sibling repo exists and is cloned. Run
`./clone.zsh` first. Check the build log printed at the end of the
script for details.
