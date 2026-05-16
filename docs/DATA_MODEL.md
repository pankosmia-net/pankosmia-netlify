# Data model

What entities exist in `pankosmia_docker`, where they live, what
their lifecycle is. Source of truth for migrations and schema
discussions.

For the architecture rationale, see `docs/ARCHITECTURE.md`. For
threat model, see `docs/SECURITY.md`.

---

## 1. Naming and ID conventions

| Type | Form | Examples |
|---|---|---|
| `UserId` | UUIDv5 derived from a GitHub user-id (i64) | `4a2c…` |
| `LanguageCode` | BCP 47 string (alpha/digit/hyphen, max 16 chars) | `en`, `fr-CA`, `zh-Hans` |
| `RepoId` | UUIDv5 derived from `<github-owner>/<github-name>` | `1f3b…` |
| `IngredientPath` | URL-safe path under `ingredients/` | `tn/jas/01.tsv` |
| `BlobKey` | Object-storage key | `audio/fr/jas/1/01.opus` |
| `RequestId` | UUIDv4, per-request | `9e8a…` |

UUIDs are validated by `FromParam` at routing time. Free-text
identifiers (`LanguageCode`, `IngredientPath`) go through dedicated
validators (see `docs/SECURITY.md` §4).

`UserId` is deterministically derived from the GitHub user-id so
that the same user maps to the same `UserId` across server
restarts. Same goes for `RepoId` from `owner/name`.

---

## 2. Where each entity lives

The ownership rule: **GitHub is authoritative for identity, ACLs,
and content. Object storage is authoritative for audio bytes.
The local workspace is a cache and a per-user scratch area.**

### 2.1 User

A GitHub account.

- **Authoritative**: `auth.users` on GitHub (effectively the
  GitHub user-id and login).
- **Server-side**: `<workspace>/.pankosmia/users/<github_user_id>/`
  holds an AES-GCM-encrypted OAuth token (`token.bin`). No mirror
  of profile data — fetched from GitHub on demand and cached
  briefly.
- **Lifecycle**: account exists from first OAuth sign-in; deleted
  when user revokes the OAuth app on github.com (server detects
  on next API call) or when explicitly purged by ops.
- **Retention**: user_id appears in audit log entries past
  account deletion, with the OAuth token discarded.

### 2.2 Language

A working unit (e.g., "French", "Arabic", "Spanish").

- **Authoritative**: registered in `pankosmia-org/catalog`'s
  `languages.yaml`. Content lives in the per-language GitHub
  repo (one repo per language).
- **Server-side**: a clone of the catalog repo at
  `<workspace>/.pankosmia/catalog/`. A clone of each registered
  language repo at `<workspace>/.pankosmia/languages/<code>/`,
  cached per request and `git fetch`-ed on webhook.
- **Lifecycle**: created by a PR to the catalog repo, vetted by
  the catalog admin, merged. The Rust server picks it up within
  ~15 minutes (or immediately on webhook).
- **Retention**: removing a language is a PR removing the entry.
  The GitHub repo is unaffected; only the registration is removed.
  The local clone gets evicted on the next sweep (configurable
  grace period).

### 2.3 LanguageMembership (ACL)

Who has what role on a language.

- **Authoritative**: GitHub's repo collaborators on the language
  repo. GitHub's permission strings map to `Role`:

  | GitHub permission | `Role` |
  |---|---|
  | `read` (or non-collaborator on a public repo) | `Viewer` |
  | `write` / `triage` | `Editor` |
  | `maintain` / `admin` | `Owner` |

- **Server-side**: `MembershipCache` memoizes lookups for 30s. No
  durable mirror.
- **Lifecycle**: granted by a current language admin via GitHub's
  Settings → Collaborators page. Revoked the same way.
- **Retention**: instant; cache TTL is the propagation latency.

### 2.4 Repo

A git repository within a language.

- **Authoritative**: GitHub. One repo per language by design;
  this 1:1 mapping is the strict registry model.
- **Server-side**: clone at
  `<workspace>/.pankosmia/languages/<code>/`. The `RepoRecord` for
  a given language is derived directly from the catalog entry; no
  separate repo registry file.
- **Lifecycle**: created by humans on GitHub; registered by a PR
  to the catalog. Removed by a catalog PR + (optional, separate)
  GitHub repo deletion.

### 2.5 Ingredient

A file inside a repo (a unit of translatable text).

- **Authoritative**: the language's GitHub repo, at
  `ingredients/<ipath>`.
- **Server-side**: read from the local clone of the upstream;
  writes go through the user's fork.
- **Lifecycle**: created/updated/deleted by translator edits
  through the server (which forks → branches → pushes → PRs) or
  by direct GitHub commits.
- **Retention**: git history on GitHub preserves prior versions
  indefinitely.

### 2.6 BurritoMetadata

The `metadata.json` sidecar at the language repo root.

- **Authoritative**: the language's GitHub repo, at
  `metadata.json`.
- **Server-side**: read from the local clone; updated as part of
  the same PR flow as ingredient edits (server runs the
  metadata-regeneration when it commits).
- **Invariants**: the `ingredients` map in metadata.json is in
  1:1 sync with files under `ingredients/`. An audit endpoint
  surfaces any drift.

### 2.7 AudioBlob

The raw audio bytes for a recording.

- **Authoritative**: object storage (Supabase Storage / S3 / R2),
  at key `audio/<language_code>/<ingredient_path>`. Bytes never
  transit the server.
- **Server-side**: metadata only — filename, hash, size, content-
  type, duration, uploaded_by, uploaded_at — recorded in JSON
  files at `<workspace>/.pankosmia/audio_metadata/<language_code>/`
  or in a SQLite index for faster listing.
- **Lifecycle**:
  1. Browser requests presigned PUT URL.
  2. Server records intent with `status='pending'`.
  3. Browser uploads directly to storage.
  4. Browser POSTs to `/burrito/audio/finalize`.
  5. Server confirms upload (HEAD on the object), updates
     `status='ready'`, records hash + size.
  6. Reads use a presigned GET URL (short TTL).
- **Retention**: soft delete on metadata (`deleted_at` set);
  object marked for deletion. Background job hard-deletes objects
  after 90 days.

### 2.8 UserSettings (per-user UI preferences)

Per-strategy decision: per-user UI state (typography, font
features, BCV cursor) lives in **client localStorage**, not on the
server. The server is stateless for these. Endpoints that returned
typography / BCV in older single-tenant clients return defaults
on the GitHub backend; clients should treat them as defaults and
override with localStorage.

### 2.9 AppState (per-language)

Same story as UserSettings: client localStorage on hosted; server
returns defaults. The single-tenant FS backend continues to honor
the older server-side per-language `app_state.json` for
compatibility with desktop clients.

### 2.10 GitAuthToken (Gitea OAuth, desktop-only)

Used by the desktop / FS backend for Gitea integration. Not used
on hosted (GitHub OAuth replaces it).

- **Authoritative on FS**: per-user JSON at
  `<workspace>/.pankosmia/users/<user-id>/gitea_tokens.json`.
- **Authoritative on GitHub**: not used.

### 2.11 OAuthToken (GitHub OAuth, hosted-only)

The GitHub access token for a signed-in user.

- **Authoritative**: server-side at
  `<workspace>/.pankosmia/users/<github_user_id>/token.bin`.
  AES-GCM-encrypted with `PANKOSMIA_TOKEN_ENCRYPTION_KEY`.
- **Lifecycle**: written on OAuth callback success; deleted on
  logout, on detected revocation (next call returns 401), or on
  account purge.
- **Retention**: forced re-issue on key rotation.

### 2.12 AuditLogEntry

Record of state-changing operations.

- **Server-side**: JSONL at
  `<workspace>/.pankosmia/audit/<yyyy-mm-dd>.jsonl`.
- **Invariants**: append-only; old files aged out after 1 year.
- For richer queries, ship JSONL to a side-channel log aggregator.

### 2.13 ClientRecord / ClientConfig

Static configuration for the JS clients served by the server.
Read from disk at startup (`<app_resources>/setup/app_setup.json`
and per-client `pankosmia_metadata.json`). Not user-mutable.

---

## 3. On-disk storage layout

Hosted (GitHub backend):

```
<workspace_root>/
├── .pankosmia/                                       ← reserved Pankosmia state
│   ├── catalog/                                      ← clone of catalog repo
│   │   └── languages.yaml
│   ├── languages/<code>/                             ← upstream cache (one per registered lang)
│   │   ├── (.git/, ingredients/, metadata.json)
│   ├── user-trees/<github_user_id>/<code>/           ← per-user fork clones
│   │   └── (.git/, ingredients/, metadata.json)
│   ├── users/<github_user_id>/
│   │   └── token.bin                                 ← AES-GCM encrypted OAuth token
│   ├── audio_metadata/<code>/                        ← per-language audio metadata
│   │   └── *.json
│   └── audit/<yyyy-mm-dd>.jsonl                      ← append-only audit log
└── (no other tenant subtrees; everything Pankosmia-managed is under .pankosmia/)
```

The `.pankosmia/` prefix isolates Pankosmia-managed data. Legacy
desktop / FS deployments read from a flatter layout where
ingredient-bearing repos live directly under `<workspace_root>/`;
the FS backend honors that for backwards compatibility.

Object storage layout (hosted, audio):

```
<bucket>/
└── audio/<language_code>/<ingredient_path>           ← bytes only
```

---

## 4. Cross-references and integrity rules

### Hard invariants

- A request for a language NOT in the catalog returns 404. The
  catalog is the gate.
- A user accessing a language repo through this server has at
  most the role GitHub grants them. The server cannot grant more.
- `<workspace>/.pankosmia/` is reserved; user-supplied path
  segments cannot land there (path validators reject the prefix).
- An `audio_blobs` record with `status='ready'` requires a
  corresponding object in storage; checked lazily, drift logged
  to `/audit/drift`.
- An `audit_log` entry never gets edited or deleted by the server
  itself; rotation is at the file level.

### Sync between local cache and GitHub

The local clone of a language repo is a **read-through cache** of
the GitHub-hosted upstream. It is never the source of truth.
Recovery from any local-cache corruption is `rm -rf` plus
re-clone — no data loss.

The user-tree clone of a fork is similarly a cache; the fork
itself on GitHub is authoritative for that user's in-flight work.

---

## 5. Atomicity

Multi-step writes (e.g., creating a repo via the catalog flow)
span systems that can't share a transaction:

- A catalog PR merge on GitHub.
- A subsequent server-side observation of that merge.
- A subsequent fetch into the local cache.

There is no global "all-or-nothing" guarantee. The recovery model
is **idempotent retry**: every step is designed to be safe to
re-run. The webhook receiver, the periodic fetch, and `ensure_language_clone`
all converge on the same end state.

For per-language atomicity (e.g., editing ingredient text + updating
metadata.json), the application-layer per-language `RwLock`
serializes concurrent writers and the resulting commits + push
ride on git's commit-level atomicity.

---

## 6. Caching strategy by entity

| Entity | Cache lifetime | Invalidation |
|---|---|---|
| `LanguageMembership` | 30 s | TTL only |
| GitHub user profile (`/me`) | 5 min | Forced on token revocation |
| `BurritoMetadata` | local clone | Webhook / periodic fetch |
| Languages catalog | local clone | Webhook / 15-min sweep |
| `ClientConfig` | server lifetime | Server restart |

All caches are bounded; `MembershipCache` uses a `HashMap` (small;
30s TTL prevents unbounded growth in practice).

---

## 7. What the codebase enforces vs. what GitHub enforces

| Constraint | Enforced where | Why |
|---|---|---|
| Path traversal blocked | App layer (`validate_segment`) | GitHub can't see paths |
| Role hierarchy (Viewer < Editor < Owner) | App layer (`RequireRole`) | Cheap, hot path |
| Membership existence | GitHub (collaborator API) + cache | GitHub is authoritative |
| Branch protection on `main` | GitHub | Lasting correctness |
| BCP 47 syntax | App layer (`FromParam` + catalog validator) | Earliest possible rejection |
| Audit log append-only | App layer + filesystem permissions | Immutability matters |
| OAuth token encryption | App layer + key in env | Disk leak alone yields ciphertext |
| Catalog membership | Catalog repo branch protection + reviewer requirements | Trust root |

The principle: app layer is the **fast** path (cache, validation,
role check); GitHub is the **lasting** path (collaborator
truth, branch protection, history). Both run; either alone is
insufficient.

---

## 8. Migration shape from a desktop / FS deployment

Operators of an existing single-tenant deployment moving to
hosted:

1. Push each existing language working tree to a fresh public
   GitHub repo:
   ```
   cd <workspace>/<some>/<org>/<lang-name>
   git remote add github https://github.com/<your-org>/<lang>.git
   git push github main
   ```
2. Open a PR on `pankosmia-org/catalog` adding the language entry.
3. Once merged, restart the hosted server (or wait for the
   periodic refresh).

Detailed tooling for this is on the roadmap (`pankosmia-migrate`
binary).

---

## See also

- `docs/ARCHITECTURE.md` — the design that uses this data model.
- `docs/SECURITY.md` — what each integrity rule defends against.
- `docs/SCALING.md` — capacity-planning consequences.
- `docs/CATALOG_REPO_TEMPLATE.md` — the catalog-side schema.
