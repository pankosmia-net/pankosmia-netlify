# Security

Threat model and defenses for `pankosmia_docker`. Read before
working on auth, ACLs, file paths, audio uploads, or any endpoint
that touches user input.

---

## 1. Trust model

### Trusted

- **The hosting layer's reverse proxy.** TLS terminates here.
  CORS, basic rate limiting, IP-based ACLs live here.
- **GitHub** as the source of truth for identity (OAuth) and
  per-language ACLs (repo collaborators). Compromise of GitHub is
  a catastrophic event for any GitHub-backed product; we don't
  defend against that.
- **The configured object-storage provider** (Supabase Storage /
  S3 / R2 / etc.) for audio bytes.
- **The catalog repo's admin set.** A merged PR there is what
  makes a language real to this server. The catalog repo's branch
  protection (required reviews, required validation action) is
  the trust root.
- **The server-side OAuth-token encryption key**
  (`PANKOSMIA_TOKEN_ENCRYPTION_KEY`). Rotated by ops; loss forces
  every user to re-sign-in.
- **The GitHub App's RSA private key.** The keys to the kingdom for
  every repo the App is installed on. Stored under
  `GITHUB_APP_PRIVATE_KEY_PATH` with `chmod 600`, or in an env var
  via `GITHUB_APP_PRIVATE_KEY`. Rotated on the App settings page
  (upload new → delete old).

### Untrusted

- **Every byte of user input.** URL path segments, query params,
  request bodies, headers. Validated at the boundary.
- **The browser.** Compromised extensions, XSS in third-party
  CDN'd JS, etc., can run in the user's session.
- **Stale or revoked OAuth tokens.** Detected lazily on the next
  GitHub API call returning 401.
- **The local filesystem outside `<workspace_root>`.** Path
  resolutions are validated to stay within the tenant's subtree.
- **External Gitea or GitHub repos that haven't been catalog-vetted.**
  Treat as adversarial; the catalog gate prevents serving them at
  all.
- **AI / LLM responses** if used in templates or prompts. May
  include prompt injection.

### Out of scope (deliberately)

- DDoS at the network layer — the proxy or platform handles it.
- TLS certificate management — proxy / platform.
- Insider threats / malicious operators — addressed by ops-side
  audit logging and access controls, not by this crate.
- Compromised GitHub itself. If GitHub is owned, every GitHub-
  backed product including this one is owned with it.

---

## 2. Authentication

### How it works

GitHub App user-authorization (OAuth-compatible wire protocol, no
scopes). Implemented in `src/auth/oauth_flow.rs`. Repo-side writes
use a separate App installation token, implemented in
`src/auth/github_app.rs`.

**Identity flow (per user, on sign-in):**

1. Browser → `GET /auth/start` → server generates a CSRF state
   token (UUID + intended-redirect path), stashes it in a private
   cookie, redirects to GitHub's authorize URL (App's Client ID;
   no `scope=` parameter).
2. User approves on github.com (or it's auto-approved if they've
   authorized this App before); GitHub redirects back with
   `?code=...&state=...`.
3. Server validates state matches the cookie, exchanges code for a
   user-to-server token at
   `https://github.com/login/oauth/access_token`.
4. Server calls `GET /user`, persists the user-to-server token
   AES-GCM encrypted (key from `PANKOSMIA_TOKEN_ENCRYPTION_KEY`),
   sets a private session cookie carrying only the GitHub user-id.
5. The browser holds the session cookie; the user-to-server token
   never crosses the wire to the browser. The user-to-server token
   is used only for identity verification on subsequent requests
   (`GET /user`); it carries no repo permissions.

**Write flow (per save, server-side only):**

1. Server mints a short-lived JWT signed RS256 with the App's
   private key (cheap; not cached).
2. Server POSTs `/app/installations/<id>/access_tokens` with that
   JWT to obtain an **installation token** (~1 h TTL).
   Installation tokens are cached per installation ID in memory,
   refreshed when nearing expiry.
3. Server uses the installation token to call write endpoints on
   the upstream language repo (Contents API, Pulls API).

### Threats and mitigations

**T1: Forged tokens / OAuth code replay.**
*Mitigation*: GitHub's OAuth flow uses one-time codes. CSRF state
cookie binds the callback to the original sign-in attempt. State
mismatch → 400.

**T2: Stolen session cookie.**
*Mitigation*: HttpOnly, Secure, SameSite=Lax. Signed via Rocket's
`secrets` feature (key from `ROCKET_SECRET_KEY`). HttpOnly blocks
JS access; `Secure` blocks HTTP transmission; SameSite=Lax blocks
most CSRF surfaces.

**T3: User-to-server token at rest.**
*Mitigation*: AES-GCM with a 256-bit key from
`PANKOSMIA_TOKEN_ENCRYPTION_KEY`. Each token gets a fresh random
nonce. Disk leak of `token.bin` files alone (without the key)
yields ciphertext. The user-to-server token grants only what the
App's user-authorization endpoint scopes (none, for our App), so
the blast radius is limited even if a token leaks: an attacker
could call `GET /user` as the victim, nothing else.

**T4: Token revocation propagation.**
*Mitigation*: when the user revokes their authorization on
github.com, the next GitHub API call returns 401. The server
clears the session cookie and discards the stored token. Worst
case: a stale in-flight request continues for the few seconds
before the next GitHub call.

**T7: App private-key compromise.**
*Mitigation*: stored at `GITHUB_APP_PRIVATE_KEY_PATH` with
`chmod 600`, or in an env var injected by the platform's secrets
manager. Never written to disk via the application code. On
suspected compromise, rotate via the App settings page (upload
new key → delete old). Note: a leaked private key gives the
attacker write access to every repo the App is installed on
until rotation. Treat the same way as a database master key.

**T5: SSE outliving authentication.**
*Mitigation*: SSE streams identify the user via the session cookie.
If the cookie expires or the OAuth app is revoked, subsequent
content reads (separate `GET` requests) require fresh auth. The
SSE stream itself only emits SHA-256 hashes — it does not stream
content. So a stale SSE leaks "this file's hash changed", not the
content. Acceptable for the translation-collaboration domain. If
stricter behavior is needed later, an in-process broadcast channel
keyed by `UserId` can force-close streams on revocation.

**T6: Permission creep.**
*Mitigation*: the user-authorization flow requests no scopes —
identity only. Repo writes are bounded by the App's declared
permissions (Contents: read+write, Pull requests: read+write,
Metadata: read). Adding a new permission requires an App settings
change AND a per-installation re-approval prompt on github.com;
silent escalation isn't possible.

---

## 3. Authorization (ACLs)

### How it works

`LanguageContext` request guard:

1. User from `AuthUser` (session cookie).
2. Language from `X-Language-Code` header (or default for
   single-language users).
3. Role from `ProjectStore::project_role(user, language)`. The
   GitHub backend implementation calls
   `GET /repos/{repo}/collaborators/{user}/permission` and maps
   GitHub's permission strings to the `Viewer / Editor / Owner`
   hierarchy:

   | GitHub permission | `Role` |
   |---|---|
   | `read` (or non-collaborator on a public repo) | `Viewer` |
   | `write` / `triage` | `Editor` |
   | `maintain` / `admin` | `Owner` |

4. `RequireRole<L>` guards check `role.is_at_least(L::required())`.

`MembershipCache` memoizes `(user, language) → role` for 30s. Hit
rate ~99% in steady state.

### Threats and mitigations

**T7: Privilege escalation by spoofing `X-Language-Code`.**
*Mitigation*: the language-code header is always validated against
the user's actual GitHub permissions on that language's repo. A
user spoofing `X-Language-Code: fr` who isn't a collaborator on
the French repo gets at most `Viewer` (or `None` if the repo is
private and they have no access).

**T8: Stale ACL cache after admin removes a collaborator.**
*Mitigation*: 30-second cache TTL. Within 30s of revocation, the
revoked user can still pass `RequireRole<Editor>` checks on
endpoints they had access to. For immediate revocation, the cache
exposes an `invalidate(user, lang)` method that an admin endpoint
can call.

**T9: Cross-language data leakage in admin endpoints.**
*Mitigation*: `/admin/*` endpoints require `Owner` role on the
target language and call the GitHub API with the admin's token —
GitHub itself enforces the per-repo permission. There is no
"global admin" role that crosses languages.

**T10: TOCTOU between role check and operation.**
*Mitigation*: the `LanguageContext` resolved at request entry is
used for the entire request. A user removed mid-request still
completes that one request; the next is denied. Acceptable.

---

## 4. Edit spam and content abuse

Because the GitHub backend exposes save endpoints to anyone who can
authenticate against the App, the system has to assume some
fraction of edits will be hostile, low-quality, or low-effort
vandalism. The design choices below limit the blast radius before
software mitigations even apply; the rest is defense in depth.

### Properties of the design that already limit blast radius

- **Per-user PR isolation.** Each user's edits land on a
  user-specific working branch (`pankosmia-edit-<login>`) and a
  user-specific PR. A bad actor's spam stays in *their* PR;
  legitimate contributors' PRs are separate and untouched. The
  reviewer can close one bad user's PR without disrupting anyone
  else.
- **Identity-bound contribution.** Translation work is not
  anonymous by its nature — language communities are small and
  contributors are known by name. A GitHub-login-bound PR makes
  social trust the front-line defense and software the backup.
- **No write capability granted to users.** The user's
  user-to-server token has no scopes. Even if it leaked, the
  attacker could only call `GET /user` as the victim — not write
  to any repo.
- **GitHub-native admin tools.** Language admins can block
  abusive users from contributing via GitHub's collaborator UI;
  the App's installation token honours the resulting 403s.

### Threats and mitigations

**T19: Single-account high-volume spam.** A signed-in user runs a
script that POSTs thousands of saves.
*Mitigation*: per-user save rate limit (60 saves / 15 min sliding
window) at `src/server/rate_limit.rs::RateLimiter`. Wired into
`endpoints/burrito2/github_save.rs::handle_github_op` BEFORE any
GitHub API call, so the 429 is fast and the App's installation-
token quota is not consumed. In-memory only; restarts reset the
counter, which is acceptable for the anti-spam role.

**T20: Oversized payload exhausting bandwidth or hitting GitHub
Contents API limits.** A save with a >1 MB body would also be
rejected by GitHub with a less-clear error.
*Mitigation*: `MAX_INGREDIENT_BYTES = 700_000` cap on `SaveOp::Put`
in the github_save helper. Conservatively below GitHub's 1 MB
Contents-API ceiling to leave headroom for base64 expansion and the
JSON envelope. Returns 413 with a clear message before any GitHub
call. Larger files need the Git Data API path (deferred future
work).

**T21: Coordinated multi-account attack.** Several GitHub accounts
each open a PR with junk. The per-user rate limit doesn't help —
each account stays under its own threshold.
*Mitigation (planned, not yet implemented)*: per-language **block
list** living in the language repo as
`pankosmia/blocked.json` (or similar). The App reads it via its
installation token, caches in memory with a short TTL, and
rejects saves with 403 for any user-id in the list. Admin
maintains it via PR or a small `/admin/block` endpoint. Cheap to
read, instant to take effect, lives with the content it gates.

**T22: Reviewer overload from too many low-quality PRs.** Even
non-malicious noise (well-meaning but unskilled edits) can swamp
small admin teams.
*Mitigation (planned)*: per-language **trusted-contributors list**
(also living in the language repo as `pankosmia/trusted.json`).
Trusted users' PRs are flagged for the auto-merge-on-CI-pass path
once that ships; untrusted users' PRs surface in the admin queue
with an `[unvetted]` marker. Combined with `/review` admin
endpoints, this triages humans toward the PRs most likely to need
careful review.

### Server limits to set in production

Operators should tighten Rocket's default form-data limits in
production. The defaults (128 MiB across most categories) are too
generous for the hosted use case; **set
`ROCKET_LIMITS='{json="64KiB",data-form="2MiB",file="2MiB",string="64KiB"}'`**
or similar via env, sized to your real per-endpoint needs. The
700-KB per-ingredient cap inside the App flow is independent of
this Rocket-side limit — both should be set tight.

### Deferred mitigations

These were considered for v1 and deliberately not built because
the cheaper measures above are sufficient for the expected attack
profile:

- **Per-PR commit-count cap** (refuse new saves when the open PR
  has >N commits): would require an extra GitHub API call per
  save (`compare` or `pulls/{n}`) for marginal value, given T19's
  rate limit already caps saves per user.
- **Server-side moderation queue** (first save from a new user
  lands in a pending queue, admin promotes to PR): heavy
  implementation, only justified under active coordinated attack.
  Revisit if the threat materialises.
- **CAPTCHA on first save from a new account**: friction for
  legitimate translators; only justified if T21 mitigations prove
  insufficient.

### Roles in the response

| Situation | Who acts | What action |
|---|---|---|
| One user spams a single PR | reviewer | Close PR; block user on the language repo via GitHub UI |
| One user keeps signing in and creating new branches | reviewer + ops | Add user-id to language's `blocked.json` |
| Many bot-driven accounts spam | reviewer + ops | Block at GitHub-org level; investigate via audit log; raise to GitHub if abusive |
| Sustained vandalism that survives blocking | ops | Tighten App permissions; consider temporary read-only mode on the language repo |

---

## 5. Path traversal

### The risk

Endpoints accept user-supplied path segments (`<repo_path..>`,
`?ipath=...`, audio filenames). A naive impl could be tricked
into reading or writing outside the workspace:

- `?ipath=../../../etc/passwd`
- `?ipath=/etc/passwd`
- `<repo_path>=../another_tenant/secrets`
- `<repo_path>=foo%00.txt` (NUL injection)
- `<repo_path>=foo/./bar/../baz` (relative segments)

### Defense

**Centralized validators** in `src/store/fs/paths.rs`:

```rust
pub fn validate_segment(s: &str) -> StoreResult<()> {
    if s.is_empty() { return Err(...); }
    if s == "." || s == ".." { return Err(...); }
    if s.contains('\0') || s.contains('/') || s.contains('\\') {
        return Err(...);
    }
    if s.starts_with('/') || s.starts_with('\\') {
        return Err(...);
    }
    Ok(())
}
```

Plus `check_path_components` for `PathBuf` walks and
`check_path_string_components` for slash-delimited `ipath`
strings.

Every endpoint that accepts user-supplied path data calls one of
these before joining with the workspace root. UUIDs (`UserId`,
`RepoId`) need no validation — `FromParam` rejects non-UUIDs at
routing. Language codes go through `LanguageCode::FromParam`,
limiting to the BCP 47 alpha/digit/hyphen alphabet.

The reserved `.pankosmia/` prefix is rejected as a top-level
component of any user-supplied path. Pankosmia-internal data is
confined to that prefix; user content never touches it.

### Defense-in-depth

- **The legacy `legacy_repo_workspace_path` helper** explicitly
  rejects the reserved prefix as a component.
- **Path canonicalization** (`fs::canonicalize` + ancestor check)
  is available as a belt-and-braces second pass; not always used
  on the hot path (perf cost).
- **No symlinks inside `<workspace_root>`** by deployment policy.

---

## 6. Audio / object-storage uploads

### Threats and mitigations

**T11: Presigned URL with overbroad scope.**
*Mitigation*: each presigned PUT URL is scoped to a single object
key (language + ingredient + timestamp + random suffix). Never
reused; never wildcards.

**T12: Presigned URL replay or sharing.**
*Mitigation*: short TTL (10 min for PUT, 5 min for GET). Server
records the issued URL in an audit table; re-issuance is
rate-limited per user.

**T13: Audio file masquerading as another type (XSS via SVG, etc.).**
*Mitigation*:
- The presigned PUT URL specifies an exact `Content-Type` header
  the upload must use.
- After upload, the server validates magic bytes asynchronously
  before marking the metadata published.
- Browser playback uses the `<audio>` element with explicit
  `type=`; never `innerHTML` or eval'd from upload content.

**T14: Quota exhaustion / fill the bucket.**
*Mitigation*: per-user upload rate limits. Per-language total-
storage caps. Object lifecycle rules to delete unfinalized
uploads after 24 hours.

**T15: Direct download URL leaking via referer / logs.**
*Mitigation*: presigned URLs sent in response bodies, not URLs.
`Referrer-Policy` set on the hosting page. CDN access logs scrub
presigned tokens before long-term retention.

---

## 7. Webhook security

GitHub webhook receivers verify the HMAC-SHA256 signature in
`X-Hub-Signature-256` against `GITHUB_WEBHOOK_SECRET` before
acting on the payload. Constant-time comparison.

**T16: Forged webhook calls.**
*Mitigation*: missing or mismatched signature → 401, no action.

**T17: Replay of a captured legitimate webhook.**
*Mitigation*: webhook handlers are idempotent — they trigger a
`git fetch`, which is a no-op when there's nothing new. A replay
costs at most one extra fetch.

**T18: Webhook payload too large.**
*Mitigation*: 2 MiB limit on the webhook body.

---

## 8. Secrets management

The crate reads secrets from environment variables, not config
files:

```
GITHUB_CLIENT_ID                # public-ish, OK in dashboards
GITHUB_CLIENT_SECRET            # SECRET — never log, never expose
GITHUB_WEBHOOK_SECRET           # SECRET
PANKOSMIA_TOKEN_ENCRYPTION_KEY  # SECRET — 32 bytes base64
ROCKET_SECRET_KEY               # SECRET — cookie signing
S3_ACCESS_KEY / S3_SECRET       # SECRET — object storage
```

**Rules**:

- Secrets via env, not config files in the repo.
- The crate must never log secret values. Any path that logs
  request data must redact `Authorization`, `Set-Cookie`, fields
  matching `*token*|*secret*|*password*|*key*`.
- `tracing` filter config redacts at the formatter layer, not at
  each call site.

**Audit before release**:

```bash
grep -rIn "println!\|tracing::" src/ \
  | grep -iE "token|secret|password|authorization"
```

---

## 9. Audit logging

### What's logged

Every state-changing request:

- `request_id` (per-request UUID).
- `user_id` (GitHub user-id).
- `language_code`.
- `endpoint`, `method`.
- `target` (e.g., ingredient path, repo, audio key).
- `outcome` (HTTP status, error class).
- `timestamp`.

### What's not logged

- Request bodies (may contain sensitive content).
- Response bodies.
- `Authorization` headers, OAuth tokens, session cookies.
- Audio bytes (the server doesn't see them).

### Storage

A JSONL file at `<workspace>/.pankosmia/audit/<yyyy-mm-dd>.jsonl`,
rotated daily. For richer querying, ship the JSONL to a side-channel
log aggregator. Audit is append-only; the file's permissions on
disk should allow append but not modify by the server's user.

### Retention

- Audit logs: 1 year minimum, longer if regulatory.
- Server-side application logs: 30 days hot, 1 year cold.
- Reverse-proxy access logs: 30 days hot; scrub presigned-URL
  query strings before long-term retention.

---

## 10. Defense-in-depth layer summary

A request to a per-language endpoint passes through:

1. **TLS termination + CORS** at the reverse proxy.
2. **Rate limiting** at the proxy or in a Rocket fairing.
3. **Session cookie validation** (signed, decrypted) → `AuthUser`
   guard.
4. **`LanguageContext` guard** — language-code header validated;
   role looked up via cached GitHub API call.
5. **`RequireRole<L>` guard** — role threshold check.
6. **Path validation** (`validate_segment`,
   `check_path_components`).
7. **Per-language `RwLock`** for write contention serialization.
8. **`ProjectStore` / `BlobStore`** — actual data access; the
   GitHub backend further verifies via the GitHub API for write
   operations.
9. **GitHub-side branch protection** on the upstream repo —
   protects `main` from direct push (translators always go through
   PRs).

Any single layer being compromised does not by itself yield broad
access. Token verification + path validation + GitHub permissions
+ branch protection are the most load-bearing layers.

---

## 10. Recommended reviews

- **Quarterly**: `cargo audit` for crate-level CVEs.
- **Per major release**: re-read this document, update for new
  endpoints / new threats.
- **Before production launch**: external pen test focused on
  multi-tenant isolation, path traversal, presigned-URL scope,
  OAuth flow.
- **On dependency upgrades** (Rocket, sqlx, jsonwebtoken,
  notify, reqwest, aes-gcm): review changelogs for security-
  relevant behavior changes.

---

## 11. Reporting vulnerabilities

Open a private security advisory on GitHub
(`Security` tab → `Report a vulnerability`). Do not file a public
issue. Expected response: triage within 7 days; patch timeline
depends on severity.
