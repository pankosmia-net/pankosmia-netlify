# Bulk operations: implement the four 501 endpoints

Spec for the four endpoints that currently return 501 in GitHub mode,
why they matter, and how to implement each using GitHub's Git Data API
for atomic multi-file commits.

Audience: someone familiar with the `pankosmia_docker` codebase and
the existing single-file save flow (which already handles per-user
branch creation, identity, and PR opening).

This doc lives alongside two parallel implementation specs in the
same set:

- `AUDIO_STRATEGY.md` — audio is external (Internet Archive),
  references only land in burritos.
- `USER_STATE_SPEC.md` — replace the stub `/settings/*`,
  `/navigation/*`, `/app-state/*` endpoints with real per-user
  persistence.

All three land independently and unblock different client features.
None depend on the others.

---

## 1. Why these matter

Four bulk-mutation endpoints exist in FS-mode `pankosmia-web` and are
called by existing Pankosmia content handlers. In GitHub mode
`pankosmia_docker` returns 501 (per
`temp/CLIENT_INTEGRATION.md §14`).

| Endpoint | Used by | Consequence of 501 |
|---|---|---|
| `POST /burrito/ingredients/delete/<repo>?ipath=...` | `core-contenthandler_text_translation` (delete a Bible book) | "Delete book" UI half-deletes (sub-files via single-file delete) and then errors trying to clean up metadata. User left with stale metadata pointing at deleted chapters. |
| `POST /burrito/metadata/remake-ingredients/<repo>` | `core-contenthandler_text_translation` (post-delete cleanup) | Same — stale ingredients listing in `metadata.json`. |
| `POST /burrito/ingredient/zipped/<repo>?ipath=...` | `core-contenthandler_text_translation` (USFM import: upload a zip of book files at once) | USFM bulk-import UI fails. Users have to import books one at a time via the single-file ingredient endpoint. |
| `POST /burrito/zipped/<repo>` | (Backup-restore flows; less commonly called) | "Restore a burrito from a zip" doesn't work. |

Client-side polyfilling (sequential single-file ops in the PWA or in
a middleware layer) is explicitly NOT the right answer:

- Sequential single-file ops are not atomic (partial-failure leaves
  inconsistent state).
- They generate N commits per bulk op (cluttering PRs).
- The polyfill is brittle (e.g., metadata regen needs to read the tree
  before knowing what to write).

The right place is server-side via GitHub's Git Data API, which lets a
multi-file commit land as one atomic ref update. See
`ARCHITECTURE_DECISIONS.md` for the broader reasoning on why
operational concerns belong in `pankosmia_docker` rather than in a
middleware layer.

---

## 2. The Git Data API pattern (shared infrastructure)

All four endpoints follow the same six-step sequence. Implementing it
once as a helper module makes each endpoint a thin wrapper.

### 2.1 The sequence

```
1. Resolve the user's working branch ref
   GET /repos/{owner}/{repo}/git/refs/heads/{branch}
   → { object: { sha: <current_commit_sha> } }
   (If the branch doesn't exist yet, create it from main's tip first —
    same logic that already exists in the single-file save path.)

2. Read the current tree (recursive)
   GET /repos/{owner}/{repo}/git/trees/{current_commit_sha}?recursive=1
   → { sha: <tree_sha>, tree: [{path, type, mode, sha, ...}] }

3. For each NEW or MODIFIED file: create a blob
   POST /repos/{owner}/{repo}/git/blobs
   { content: <base64-encoded-bytes>, encoding: "base64" }
   → { sha: <blob_sha> }

4. Build the new tree
   POST /repos/{owner}/{repo}/git/trees
   {
     base_tree: <current_tree_sha>,
     tree: [
       // Additions / modifications:
       { path, mode: "100644", type: "blob", sha: <blob_sha> },
       // Deletions:
       { path, mode: "100644", type: "blob", sha: null }
     ]
   }
   → { sha: <new_tree_sha> }

5. Create the commit
   POST /repos/{owner}/{repo}/git/commits
   {
     message: <human-readable commit message>,
     tree: <new_tree_sha>,
     parents: [<current_commit_sha>],
     author: { name, email, date },     // optional but recommended
     committer: { name, email, date }   // optional but recommended
   }
   → { sha: <new_commit_sha> }

6. Update the branch ref atomically
   PATCH /repos/{owner}/{repo}/git/refs/heads/{branch}
   { sha: <new_commit_sha> }
   → 200 if applied; 422 if a concurrent push moved the ref.
```

### 2.2 Atomicity guarantees

- Steps 3–5 create new immutable objects. They don't change the user
  visible state.
- **Only step 6 makes the change visible.** Either it succeeds and
  all N files appear as one commit, or it fails and nothing changed.
- On 422 (someone else pushed to the same branch — unlikely since the
  branch is per-user, but possible with concurrent sessions): retry
  the whole sequence from step 1, or surface a conflict.

### 2.3 Limits to enforce upfront

Hardcode these limits, return clean errors when exceeded:

- **Max files per bulk op**: 100. (GitHub's tree size limit is higher
  but this protects against unbounded request bodies.)
- **Max single-file size in a bulk op**: 10 MB. (GitHub's blob limit is
  100 MB but we don't want huge files going through this path; if
  needed, audio/binary should use the future `/burrito/audio/upload-url`
  presigned flow.)
- **Max total bulk-op body size**: 25 MB. (Memory pressure; sized for
  USFM imports.)
- **Max bulk-op duration**: 60 s server-side timeout. (Beyond that,
  surface "operation too large, please split.")

### 2.4 Identity and PR plumbing

After step 6 succeeds, the working branch is one commit further. The
existing PR-opening logic (which already handles single-file saves)
should continue to work — opens a PR on first commit, accumulates on
existing PR for subsequent commits.

The response shape **must** mirror single-file save responses so the
existing client error/success handling works:

```json
{
  "is_good": true,
  "status": "deleted" | "regenerated" | "uploaded" | "replaced",
  "branch": "pankosmia-edit-<login>",
  "pr_url": "https://github.com/<owner>/<repo>/pull/N",
  "pr_number": 42,
  // Endpoint-specific extras:
  "deleted_count" | "ingredient_count" | "file_count" | "total_bytes": ...
}
```

---

## 3. Per-endpoint specifications

### 3.1 `POST /burrito/ingredients/delete/<repo>?ipath=<prefix>`

**Purpose**: recursively delete every ingredient whose path starts
with the given prefix. Atomic single-commit removal.

**FS-mode reference**: `pankosmia-web/src/endpoints/burrito2/post_delete_ingredients.rs`

**Consumers**: `core-contenthandler_text_translation`
(`DeleteTextTranslationBook.jsx:81`) calls this after a per-file
delete sequence to clean up empty directories.

**Request**:
- URL: `/burrito/ingredients/delete/<source>/<org>/<repo>?ipath=<prefix>`
- Method: `POST`
- Auth: session cookie + `X-Language-Code` header (same as single-file).
- Body: none.

**Behaviour**:
1. Run the Git Data API sequence from §2.1.
2. In step 2 (tree read), enumerate all entries whose `path` starts
   with `<prefix>` (treat `<prefix>` as a path prefix, ensuring it ends
   with `/` if it's meant to be a directory).
3. In step 4 (tree build), pass `{path, mode: "100644", type: "blob",
   sha: null}` for each enumerated entry.
4. Commit message:
   `chore(pankosmia): delete <N> ingredients under <prefix>`

**Response** (200):
```json
{
  "is_good": true,
  "status": "deleted",
  "deleted_count": 7,
  "deleted_paths": ["ingredients/MAT/1.usfm", "ingredients/MAT/2.usfm", ...],
  "branch": "pankosmia-edit-<login>",
  "pr_url": "...",
  "pr_number": 42
}
```

**Errors**:
- `400` if `ipath` is empty / malformed / contains `..`.
- `404` if no entries match the prefix (or return 200 with
  `deleted_count: 0`? — recommend 200, idempotent).
- `429` if too many files (>100 per §2.3).
- `502` if a GitHub API call fails midway (retryable; tree+blob+commit
  objects are GC'd later if unused).

### 3.2 `POST /burrito/metadata/remake-ingredients/<repo>`

**Purpose**: walk the burrito's `ingredients/` tree and regenerate the
`ingredients` array in `metadata.json` to reflect actually-present
files. Used as cleanup after a bulk delete, or when ingredients are
added/removed via the GitHub web UI directly.

**FS-mode reference**: `pankosmia-web/src/endpoints/burrito2/post_remake_ingredients_metadata.rs`

**Consumers**: `core-contenthandler_text_translation`
(`DeleteTextTranslationBook.jsx:81`).

**Request**:
- URL: `/burrito/metadata/remake-ingredients/<source>/<org>/<repo>`
- Method: `POST`
- Auth: session cookie + `X-Language-Code` header.
- Body: none.

**Behaviour**:
1. Get the working branch's current tree (step 2 of §2.1).
2. Filter to entries under `ingredients/`.
3. For each, compute the burrito-spec ingredient entry (checksum,
   mimeType, size, role, etc. — see Scripture Burrito spec). The
   server should reuse whatever logic FS-mode already has; the
   computations are the same.
4. Read the current `metadata.json` (find it in the tree, fetch the
   blob via `GET /repos/.../git/blobs/<sha>`, base64-decode).
5. Parse, replace the `ingredients` object, re-serialize as
   canonical JSON.
6. Create a blob for the new `metadata.json` (step 3 of §2.1).
7. Build a tree replacing `metadata.json`'s blob (step 4).
8. Commit + ref update (steps 5–6). Single-file commit.
9. Commit message:
   `chore(pankosmia): regenerate metadata.json ingredients (<N> entries)`

**Response** (200):
```json
{
  "is_good": true,
  "status": "regenerated",
  "ingredient_count": 24,
  "removed_count": 3,
  "added_count": 0,
  "branch": "pankosmia-edit-<login>",
  "pr_url": "...",
  "pr_number": 42
}
```

**Errors**:
- `400` if metadata.json is missing or unparseable.
- `502` on GitHub failure.

**Note**: this is the simplest of the four (single-file write); a
good starting point for the Git Data API integration.

### 3.3 `POST /burrito/ingredient/zipped/<repo>?ipath=<prefix>`

**Purpose**: bulk-add ingredients from a client-uploaded zip. Used
for USFM import (user uploads a zip of book files), OBS image
imports (less common), and similar bulk-ingest flows.

**FS-mode reference**: `pankosmia-web/src/endpoints/burrito2/post_zipped_ingredient.rs`

**Consumers**: `core-contenthandler_text_translation`
(`UsfmImport.jsx` etc.).

**Request**:
- URL: `/burrito/ingredient/zipped/<source>/<org>/<repo>?ipath=<prefix>`
  - `<prefix>` is the directory inside the burrito where unzipped
    files land (e.g. `ingredients/MAT/`).
- Method: `POST`
- Content-Type: `multipart/form-data`
- Form field: `file` (the zip).
- Auth: session cookie + `X-Language-Code` header.

**Behaviour**:
1. Receive the multipart upload, hold the zip in memory.
2. Validate the zip (see §3.5 zip-bomb / symlink concerns).
3. Enumerate files inside the zip.
4. For each: create a blob (step 3 of §2.1) with the file's bytes.
5. Build a tree adding each blob at `<prefix> + <file's zip-relative-path>`.
6. Commit + ref update.
7. Commit message:
   `feat(pankosmia): import <N> ingredients via zip into <prefix>`

**Response** (200):
```json
{
  "is_good": true,
  "status": "uploaded",
  "file_count": 27,
  "total_bytes": 1843264,
  "imported_paths": ["ingredients/MAT/1.usfm", ...],
  "branch": "pankosmia-edit-<login>",
  "pr_url": "...",
  "pr_number": 42
}
```

**Errors**:
- `400` if the body isn't a valid zip, or contains
  symlinks/path-traversal entries (`..` in zip paths) — reject the
  whole upload.
- `413` if total size > 25 MB, or any single file > 10 MB, or file
  count > 100 (§2.3 limits).
- `502` on GitHub failure.

### 3.4 `POST /burrito/zipped/<repo>`

**Purpose**: replace the entire burrito (except git history) with
the contents of a client-uploaded zip. Used for restore-from-backup
and similar full-import flows.

**FS-mode reference**: `pankosmia-web/src/endpoints/burrito2/post_zipped_repo.rs`

**Consumers**: rare. Backup/restore tooling; future "burrito
exchange" workflows. **Lowest priority of the four.**

**Request**:
- URL: `/burrito/zipped/<source>/<org>/<repo>`
- Method: `POST`
- Content-Type: `multipart/form-data`
- Form field: `file` (the zip — expected to contain a full burrito:
  `metadata.json` at root, `ingredients/` directory, audit/, etc.).
- Auth: session cookie + `X-Language-Code` header.

**Behaviour**:
1. Receive + validate zip (same checks as §3.3 plus presence of
   `metadata.json` at the zip root).
2. **Read the existing working-branch tree** (step 2 of §2.1) and
   build a delete list for every file NOT in the zip (or
   alternatively: skip step 4's base_tree and build the new tree
   from scratch — see below).
3. For each file in the zip, create a blob.
4. Build the new tree. Two implementation options:
   - **Option A — base_tree + deletions**: start from `base_tree:
     <current_tree_sha>`, add the new blobs, and add `sha: null`
     entries for every file in the current tree that's NOT in the
     zip. Preserves any git history conventions.
   - **Option B — fresh tree**: omit `base_tree`, list only the
     entries from the zip. Cleaner but loses any tree-level
     attributes (e.g., submodules — unlikely but possible).
   Recommend Option A for safety.
5. Commit + ref update.
6. Commit message:
   `chore(pankosmia): replace burrito contents from upload (<N> files)`

**Response** (200):
```json
{
  "is_good": true,
  "status": "replaced",
  "file_count": 64,
  "total_bytes": 4892331,
  "branch": "pankosmia-edit-<login>",
  "pr_url": "...",
  "pr_number": 42
}
```

**Errors**:
- Same as §3.3 plus:
- `400` if the zip doesn't contain `metadata.json` at root.
- `409` if the zip's `metadata.json` describes a different
  `<source>/<org>/<repo>` than the URL implies (mismatch — refuse
  rather than silently relocate).

### 3.5 Zip security (applies to §3.3 and §3.4)

The existing FS-mode endpoints have known weaknesses flagged in our
earlier security scan (`temp/SECURITY.md` if it documents this — at
minimum these are observed in the FS code):

- `..` in zip paths → path traversal (mitigated in FS code by
  `enclosed_name()`; preserve this).
- Symlink entries inside zip → not handled; reject anything that
  isn't a regular file or directory.
- Zip bombs → very high compression ratio entries. Enforce the
  25 MB total / 10 MB per-file / 100 files / 60 s limits before
  trusting decompression output.
- Empty zip → reject as 400 (probably user error).

The GitHub Git Data API path is inherently safer than FS-mode
unzip-to-disk: there's no on-disk write to escape. The remaining
risks are memory pressure and GitHub-side quota burn, both bounded
by the limits in §2.3.

---

## 4. Suggested implementation order

| Order | Endpoint | Rationale |
|---|---|---|
| 1 | `/burrito/metadata/remake-ingredients` (§3.2) | Single-file write. Smallest scope. Lets you build and validate the Git Data API helper module in isolation. |
| 2 | `/burrito/ingredients/delete` (§3.1) | Multi-file write (deletions only, no blobs to create). Exercises tree-build with `sha: null` entries. |
| 3 | `/burrito/ingredient/zipped` (§3.3) | Multi-file write with blob creation. Builds on #1 and #2's infrastructure. |
| 4 | `/burrito/zipped` (§3.4) | Largest scope; uses everything above. Genuine demand is lowest, so OK to defer. |

Each builds on the previous. After §3.2, the helper module is real;
§3.1 just adds deletion tree entries; §3.3 adds blob creation and
zip parsing; §3.4 adds whole-tree replacement.

Estimated effort: **5–8 days total** for all four, assuming the
existing single-file save path is well-factored. Most of the work is
the Git Data API helper module; the per-endpoint code is small once
that's in place.

---

## 5. Open design decisions for the maintainer

These should be settled before implementation begins.

### 5.1 Use the per-user branch, or a special bulk branch?

Today's single-file saves accumulate on `pankosmia-edit-<login>`. Bulk
ops could:
- **Use the same branch** — bulk op shows as one big commit alongside
  per-file commits in the user's PR. Reviewer sees a mixed PR.
- **Use a dedicated branch** — e.g.
  `pankosmia-bulk-<login>-<timestamp>`, separate PR per bulk op.
  Cleaner separation but more PRs to merge.

**Recommendation**: same branch (per-user). Reviewer experience is
fine — squash-merge collapses everything anyway, and a mixed PR is
the natural representation of "a user's editing session."

### 5.2 Idempotency keys?

A bulk delete or zip upload that times out client-side may be retried.
Without dedup, the second call could double-commit (re-add the same
files, or attempt to re-delete already-deleted ones — which would
result in 0 deletions, OK).

For the zip cases (§3.3, §3.4), an idempotency key (request header
`Idempotency-Key: <client-uuid>`) would let the server detect retries
and return the cached result of the first attempt.

**Recommendation**: implement for §3.3 and §3.4 (where re-doing the
work is wasteful — re-uploading and re-blobbing 25 MB). Skip for
§3.1, §3.2 where idempotency is naturally close (re-deleting yields
the same state).

### 5.3 Concurrent-edit conflict handling

If `pankosmia-edit-<login>` was advanced by a concurrent
single-file save between steps 1 and 6 of §2.1, step 6 returns 422.
Two options:
- **Auto-retry** the bulk op from step 1. Risk: infinite loops if
  the user has many concurrent sessions.
- **Surface conflict** as a 409 to the client. The client decides
  whether to retry.

**Recommendation**: 1 auto-retry; if still 422 after retry, surface
409. Matches GitHub's own semantics.

### 5.4 Audit-trail granularity

Per-file commits make the audit trail very fine-grained ("translator
edited verse 3 at 14:02, edited verse 4 at 14:03, ..."). Bulk-op
commits collapse this to coarse-grained ("deleted 27 files").

For reviewers this is fine; for forensic tracing it loses information.

**Recommendation**: bulk ops include a `details` JSON object in the
commit message body (after the title line). Reviewers can ignore;
auditors can extract:

```
chore(pankosmia): delete 7 ingredients under ingredients/MAT/

deleted_paths:
- ingredients/MAT/1.usfm
- ingredients/MAT/2.usfm
- ...
```

GitHub's commit-message body field has no practical size limit (10 KB
is fine in practice; can encode 100-file deletions comfortably).

---

## 6. What clients (and wrappers) expect

Existing client integration patterns (see `CLIENT_WRAPPER_GUIDE.md`)
expect these endpoints to:

- Return the same `{is_good, status, branch, pr_url, pr_number, ...}`
  envelope as single-file saves. The wrapper's `save-success` event
  surfacing works automatically for bulk ops if the response shape
  matches.
- 401 on unauthenticated requests. Caught by the standard auth
  interceptor.
- 413 on size-limit violations. Passed through.
- 502 on GitHub upstream failure. Exposed to host PWA for retry/UX
  decisions.

No client-side changes are needed when these endpoints land; existing
write paths route them like any other write.

**Note on scope after audio externalization**: the bulk-zip endpoints
(§3.3 and §3.4) historically were used heavily for audio import. With
audio externalized per `AUDIO_STRATEGY.md`, bulk zip uploads of audio
files are no longer relevant. The zip endpoints still matter for text
content (USFM bulk-import for text translation, etc.), but the per-file
size and total-payload limits in §2.3 can be tight since audio is the
biggest historical use case that pushed against them.

---

## 7. References

### In this set

- `AUDIO_STRATEGY.md` — audio is external; reference-only writes are
  single-file saves and don't need bulk ops.
- `USER_STATE_SPEC.md` — replaces stub state endpoints; orthogonal
  to bulk ops.
- `CLIENT_WRAPPER_GUIDE.md` — what clients expect; this doc's
  response envelope matches.
- `ARCHITECTURE_DECISIONS.md` — records why we chose to implement
  these here rather than in a middleware layer or via client-side
  polyfill.

### `pankosmia_docker`'s existing docs

- `CLIENT_INTEGRATION.md §14` — lists these as 501 (to be removed
  from the "not implemented" list once §3.1–3.4 here ship).
- `HOSTING.md` — operator setup of `pankosmia_docker` (where
  GitHub App + working branch logic lives).

### External

- GitHub Git Data API: https://docs.github.com/en/rest/git
  - blobs: `/git/blobs`
  - trees: `/git/trees`
  - commits: `/git/commits`
  - refs: `/git/refs`
- Scripture Burrito spec (for §3.2's ingredient-entry shape):
  https://docs.burrito.bible/

### FS-mode references

The four endpoints exist in FS-mode `pankosmia-web` (predecessor of
`pankosmia_docker`'s GitHub mode). The FS implementations are the
behavioural contract to match; only the I/O layer changes (`std::fs`
→ GitHub Git Data API).

If a `pankosmia-web` checkout is available:

- `src/endpoints/burrito2/post_delete_ingredients.rs`
- `src/endpoints/burrito2/post_remake_ingredients_metadata.rs`
- `src/endpoints/burrito2/post_zipped_ingredient.rs`
- `src/endpoints/burrito2/post_zipped_repo.rs`
