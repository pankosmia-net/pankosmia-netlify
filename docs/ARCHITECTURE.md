# Architecture

`pankosmia_docker` is a Rust HTTP server (Rocket 0.5) that fronts a
multi-language Bible-translation workflow. Content lives on GitHub;
the server is the user-facing layer translators interact with
through their browser.

## One-paragraph summary

One Docker-deployable Rust binary serves thousands of translators
across hundreds of language repos. Each language is a public
GitHub repository; the set of registered languages is enumerated in
a separate central GitHub repo (the **catalog**). Translators sign
in with GitHub for identity only; the server holds a **GitHub App**'s
private key and uses installation tokens to write directly to each
language's upstream repo — opening a per-user working branch and a
pull request on the upstream. A language admin (also signed in via
GitHub) reviews and merges. Audio bytes never transit the server —
clients PUT directly to object storage via short-lived presigned URLs.

## Trust topology

```
                     pankosmia-org/catalog
                            ▲
                   (PR adds a language)
                            │
                   ┌────────┴────────┐
                   │  catalog admin  │  vets each registration
                   │  (small group)  │  before merging
                   └─────────────────┘
                            │
                            │ catalog lists:
                            ▼
   ┌─────────────────┬─────────────────┬─────────────────┐
   │ org-a/fr        │ org-b/sw        │ pankosmia/en    │  per-language
   │                 │                 │                 │  GitHub repos
   │ language admin  │ language admin  │ language admin  │
   │ (set per repo,  │ (set per repo,  │ (set per repo,  │
   │  via GitHub     │  via GitHub     │  via GitHub     │
   │  collaborators) │  collaborators) │  collaborators) │
   │                 │                 │                 │
   │  translators…   │  translators…   │  translators…   │
   └─────────────────┴─────────────────┴─────────────────┘
```

Three roles, each scoped to its layer:

- **Catalog admin** — push access to `pankosmia-org/catalog`. The
  trust root: a merged PR there is what makes a language real to
  the server. A small, vetted group.
- **Language admin** — Maintain or Admin on a specific language's
  GitHub repo. Reviews and merges PRs from translators. Different
  per language.
- **Translator** — no GitHub-side write access; signs in to the
  app for identity only. The server's GitHub App is what creates
  branches and opens PRs on the upstream language repo.

A single GitHub user can fill multiple roles or just one.

## The catalog repo

`pankosmia-org/catalog` (or whatever org runs the deployment) holds
one file at the root: `languages.yaml`. Its schema is documented in
`docs/CATALOG_REPO_TEMPLATE.md` §4.

The server clones the catalog at startup, parses
`languages.yaml`, and materializes a `CatalogRegistry`. Refresh
happens on (a) `POST /webhook/catalog` (signed via
`GITHUB_WEBHOOK_SECRET`), (b) a periodic 15-minute timer.

A request for a language **not** in the catalog returns 404 before
any other lookup happens. The catalog is the gate.

## Authentication

Two distinct token types, both backed by a single **GitHub App**:

1. **User identity** — the App's user-authorization endpoint (same
   wire protocol as classic OAuth, but no scopes requested). On
   sign-in the server exchanges the code for a user-to-server
   token, calls `GET /user` to obtain the login, persists the token
   AES-GCM-encrypted under
   `<workspace_root>/.pankosmia/users/<github_user_id>/token.bin`
   (key from `PANKOSMIA_TOKEN_ENCRYPTION_KEY`), and sets a signed
   session cookie carrying only the GitHub user-id. The token never
   reaches the browser. Used only to identify who's calling.
2. **Server-side writes** — installation tokens minted on demand
   from the App's RSA private key (RS256 JWT → `POST /app/installations/<id>/access_tokens`).
   Cached per-installation for ~55 minutes. Used to write to
   upstream language repos (Contents API). Never reaches the
   browser.

The user grants the App no scopes — they just authenticate. Repo
writes happen with the App's identity (it must be installed on each
language repo / org that owns one).

Token revocation (user revokes their authorization on github.com)
is caught lazily: the next `GET /user` returns 401, the server
clears the session, the client re-signs-in.

## The edit flow

When user X saves an edit on language Y:

1. The server resolves Y's upstream repo from the catalog and the
   installation ID (per-language override → global default).
2. Mints an installation token for that installation.
3. Looks up X's existing open PR for the working branch
   `pankosmia-edit-<X-login>`. If one exists, the working branch is
   left as-is (this is a continuing session); otherwise the branch
   is created at — or reset to — upstream HEAD.
4. Fetches the file's current blob SHA on the working branch.
5. `PUT /repos/<upstream>/contents/<path>` with the new bytes, a
   commit message including a `Co-authored-by: <X-login>` trailer,
   and the blob SHA if updating an existing file.
6. If no open PR was found in step 3, opens one for the working
   branch. Returns `{ status: "saved", branch, pr_url, pr_number }`.

Each save is one commit on the branch. Across a session the PR
accumulates commits — the audit trail of edits. Reviewers can
"Squash and merge" at the end to keep `main`'s history tidy.

No forks. No per-user git clones. No git2 push. The App's
installation token is the only thing that can write to upstream
language repos.

If GitHub returns a merge conflict during `PUT /contents` (the
file's blob SHA on the working branch changed under us), the
response is 409 with diff data. The client renders a merge dialog;
the user resolves; a follow-up endpoint applies the resolution.
The translator never visits github.com.

When the language admin merges (either via the in-browser admin
panel or directly on github.com), GitHub fires a webhook to
`POST /webhook/language/<code>`. The server `git fetch`-es the
upstream cache; the SSE watcher registry detects file mtime changes
and broadcasts `change` events to subscribers.

## Storage layout

```
<workspace_root>/
├── .pankosmia/                                 ← reserved Pankosmia state
│   ├── catalog/                                ← clone of catalog repo
│   │   └── languages.yaml
│   ├── languages/<code>/                       ← upstream cache (read-side; one per registered lang)
│   │   ├── (.git/, ingredients/, metadata.json)
│   └── users/<github_user_id>/
│       └── token.bin                           ← AES-GCM encrypted user-to-server identity token
```

The reserved `.pankosmia/` prefix isolates server-managed state
from any other directory the operator might keep at the workspace
root.

No per-user git clones or fork records. Writes go through the
GitHub App's installation token via the Contents API; reads come
from the shared `languages/<code>/` cache, which is fetched at
startup and refreshed via the language webhooks (or the periodic
fallback fetch).

## Audio (and binary content in general)

Audio bytes never transit the server. The flow:

```
1. Browser POSTs /burrito/audio/upload-url → server returns a
   short-lived presigned PUT URL (signed by the configured object-
   storage provider — Supabase Storage, S3, R2, etc.).
2. Browser PUTs bytes directly to the object-storage URL.
3. Browser POSTs /burrito/audio/finalize → server confirms the
   object exists, records metadata in Postgres / a JSON file,
   marks the upload ready.
4. Reads work the same way: server returns a presigned GET URL,
   browser fetches direct.
```

This is the single biggest scaling lever (see `docs/SCALING.md`
§2). Without it, a 1 Gbps server is bandwidth-limited to ~10
concurrent audio sessions; with it, concurrency is bounded by
object-storage quotas, not server bandwidth. Audio metadata
(filename, hash, duration, who uploaded) lives server-side
alongside other text content; only the bytes are offloaded.

Future binary content (video, attached source files, etc.) follows
the same pattern.

## What stays out of git on purpose

- **User authentication state** — GitHub is authoritative.
- **Per-(user, language) memberships** — GitHub repo collaborators
  is authoritative.
- **Audit log** — git log on each language repo + the catalog
  repo is mostly enough; a JSONL side-channel is added only when
  more is needed.
- **Per-user app state** (BCV cursor, typography, font features)
  lives in client localStorage. The server is stateless for these.

## What stays in git on purpose

- **Translation text content** (`ingredients/*`). History matters:
  "what did this verse say at commit X" is a meaningful query.
- **Repo metadata** (`metadata.json`). History matters: "when was
  this book added."

The principle: version control is for content where history is the
product. Nothing else.

## Two backends, one trait

`ProjectStore` is the abstraction the endpoints call. Two
implementations:

- **`FsLanguageStore`** — single-tenant, single-user, no auth.
  For desktop deployments where the binary is bundled inside an
  app (Electron / Tauri / similar).
- **`GitHubLanguageStore`** — multi-tenant, GitHub-backed. User
  identity via the GitHub App's user-authorization flow; writes via
  the App's installation token. For hosted deployments.

Selected at startup via `STORAGE_BACKEND=fs|github`. Endpoint code
doesn't bifurcate; the trait method calls are identical regardless
of backend. New backends (e.g., a self-hosted Gitea variant) can
be added by writing a third trait impl.

## Concurrency primitives

- **`LanguageLocks`** — per-language `RwLock` map. Concurrent git
  ops on the same language serialize at the application layer;
  ops on different languages run concurrently. Memory cost: ~80
  bytes per language entry.
- **`BlockingPools`** — bounded `git_pool` (16 slots) and
  `cpu_pool` (num_cpus) wrapping `tokio::task::spawn_blocking`. A
  slow `git clone` on one language can't fill Tokio's default
  blocking pool and starve fast handlers on another.
- **`WatcherRegistry`** — shared inotify subscriptions for SSE.
  N subscribers on the same file share one inotify watch via a
  `tokio::sync::broadcast` channel. Tear-down on last drop.

## Deployment shape

```
                 Browser
                    │
                    │ HTTPS
                    ▼
         ┌────────────────────┐
         │   Reverse Proxy    │  TLS, no-buffer for SSE,
         │  (Caddy / nginx)   │  pass Authorization through
         └─────────┬──────────┘
                   │
                   ▼
         ┌────────────────────┐
         │  Rust binary       │  thousands of users
         │  (this crate)      │  bounded thread pools
         │                    │  per-language RwLocks
         │  presigned URL     │  SSE fan-out registry
         │  issuance for      │
         │  audio uploads /   │
         │  downloads         │
         └──┬───────────┬─────┘
            │           │
            ▼           ▼
      Local NVMe   Object Storage              GitHub
      (git caches) (audio bytes)              (source of truth
                                               for text content
                                               and identity)
```

## Out of scope (deliberately)

- **Real-time presence** ("user X is also viewing this passage").
  Presence is a separate concern; layer Supabase Realtime or
  similar on top if/when the feature is needed. Identity stays on
  GitHub.
- **Cross-language SQL queries** (admin reports, analytics).
  Iterate the catalog + GitHub API. If this becomes painful, dump
  to a local SQLite for ad-hoc querying — async, off the request
  path.
- **Per-ingredient ACLs.** GitHub repo-level permissions are the
  unit of access control. "User X can edit chapter 1 but not
  chapter 2" is not modeled.
- **Offline-first hosted access.** Hosted users need GitHub
  reachability. Communities in restricted networks (Iran, some
  corporate / sanctioned environments) use a desktop variant
  instead — the `FsLanguageStore` backend serves the same
  endpoint surface against a local working tree.

## See also

- `docs/CATALOG_REPO_TEMPLATE.md` — concrete catalog repo setup.
- `docs/CLIENT_INTEGRATION.md` — building a JS/web client.
- `docs/DATA_MODEL.md` — entities and where they live.
- `docs/SECURITY.md` — threat model and defenses.
- `docs/SCALING.md` — capacity planning.
- `docs/HOSTING.md` — operator-facing integration contract.
