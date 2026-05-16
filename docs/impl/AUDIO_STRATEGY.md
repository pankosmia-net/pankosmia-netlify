# Audio strategy: external storage with burrito-side references

How `pankosmia_docker` handles audio content. **Short version**: audio
bytes live outside the server — primarily on Internet Archive — and
the burrito stores only small JSON reference files pointing at them.

Audience: maintainer of `pankosmia_docker`, contributors building
PWAs against it.

---

## 1. The decision

Audio is treated as **external content referenced by URL**, not as
bytes stored on the server. The server never holds audio bytes.

The two supported flows:

- **Strategy A (primary)** — PWA uploads audio directly from the
  browser to Internet Archive (IA) via IA's S3-compatible API. PWA
  receives the resulting URL and writes a small JSON reference into
  the burrito.
- **Strategy B (fallback)** — User records or uploads audio in a tool
  of their choice (Audacity, phone, an existing IA item, any
  CC-licensed source), copies the resulting URL, pastes it into the
  PWA's reference input. PWA writes the same JSON reference into the
  burrito.

Both flows produce the same in-burrito artifact: a tiny JSON file
that fits comfortably inside any single-file save endpoint, no
700 KB cap concerns.

## 2. Why external

| | |
|---|---|
| **No audio infrastructure on the server** | No storage, no bandwidth, no transcoding, no S3 SDK, no presigned-URL flow. Server stays focused on the GitHub bridge. |
| **Solves the 700 KB cap problem completely** | The reference is ~200 bytes. Cap is irrelevant. |
| **Burrito stays tiny** | Audio at scale would dominate burrito size. References don't. |
| **CC-licensing alignment** | IA enforces CC at upload time — automatic policy. |
| **Pre-existing content** | Vast CC-licensed translation/OBS audio already on IA. Reference it directly. |
| **Discoverability** | IA-hosted audio is searchable, citeable, linkable outside the Pankosmia stack. |
| **Durability** | IA is a non-profit with 25+ years of operation. More durable than typical SaaS storage. |
| **No backup concern** | Audio's lifecycle belongs to its host. Server backup stays small. |
| **Uniform model for all audio use cases** | OBS dubs, scripture readings, alignment data, sermon recordings — all use the same reference pattern. |

## 3. Why not "audio in the server"

Considered and rejected: building an audio pipeline upstream
(`/burrito/audio/upload-url` presign flow per the historical
`CLIENT_INTEGRATION.md §14` roadmap entry). Reasons:

- Adds a lot of code (multipart, S3 client, presign signing,
  finalize endpoint).
- Couples server to an S3-compatible storage choice (R2, B2,
  Supabase Storage, etc.).
- Each deployment has to configure storage backend.
- License enforcement is operator-bespoke instead of host-enforced.
- Bytes still touch the server's network on upload (presign avoids
  this, but only if signed-URL targets clients directly).
- No discoverability — audio is locked inside the deployment.

The historical roadmap entry can be removed.

## 4. Reference file format

Stored as a regular burrito ingredient at a conventional path
(typically `audio_content/<chapter>-<paragraph>/ref.json`, but any
path the producing client chooses is fine).

### 4.1 Required fields

```json
{
  "schema_version": 1,
  "url": "https://archive.org/download/<id>/<filename>.mp3",
  "type": "audio/mp3",
  "license": "CC-BY-SA-4.0"
}
```

| Field | Notes |
|---|---|
| `schema_version` | Integer. Lets the schema evolve without breaking old burritos. v1 is this document. |
| `url` | Stable URL that returns audio bytes directly (HEAD must succeed, GET must return audio content-type). |
| `type` | MIME type. Common values: `audio/mp3`, `audio/mp4`, `audio/ogg`, `audio/wav`, `audio/webm`. Browser-playable formats only. |
| `license` | SPDX-style license identifier. Allowed values: see §4.3. |

### 4.2 Optional fields

```json
{
  "duration_sec": 47,
  "size_bytes": 752394,
  "checksum_sha256": "a3f5b1c2...",
  "uploaded_by": "<github-login>",
  "uploaded_at": "2026-05-13T14:22:00Z",
  "source": "archive.org",
  "source_id": "obs-es-mx-01",
  "attribution": "Recorded by María García, 2026"
}
```

| Field | Use |
|---|---|
| `duration_sec` | UI: show length before clicking play. |
| `size_bytes` | UI: data-cost warning on mobile. |
| `checksum_sha256` | Detect upstream tampering. PWA verifies on first play. |
| `uploaded_by` | GitHub login of the contributor who added the reference. |
| `uploaded_at` | ISO 8601 timestamp. |
| `source` | Human-readable host name. `archive.org`, `cdn.door43.org`, etc. |
| `source_id` | Host-internal ID for the audio item. |
| `attribution` | Free-text credit line. Surfaces in PWA player UI. |

### 4.3 Allowed license values

By policy, the server validates `license` against an allowlist of
open licenses. Default allowlist (config-overridable):

- `CC0-1.0`
- `CC-BY-4.0`
- `CC-BY-SA-4.0`
- `CC-BY-NC-4.0`
- `CC-BY-ND-4.0`
- `CC-BY-NC-SA-4.0`
- `CC-BY-NC-ND-4.0`
- `Public-Domain` (alias for CC0)

Requests with `license` outside this list return 400 with
`reason: "license <value> not in allowed-licenses list"`.

Operators can override via env var `PANKOSMIA_ALLOWED_LICENSES`
(comma-separated SPDX IDs). Setting it to `*` disables validation
(not recommended).

### 4.4 Schema validation on the server

When `pankosmia_docker` receives a write to a path matching
`audio_content/**/ref.json` (or any path whose ingredient type
indicates audio reference — see §4.5 for type detection), it should:

1. Parse the body as JSON. 400 on parse error.
2. Validate against the v1 schema (required fields present, types
   correct). 400 with field-specific reason on validation failure.
3. Validate `license` against the allowlist. 400 if disallowed.
4. **Optionally** issue a HEAD request to `url` with short timeout
   (2 s). Behavior:
   - HEAD succeeds (2xx) and Content-Type starts with `audio/`: accept.
   - HEAD succeeds but Content-Type isn't audio: 400 with
     `reason: "URL does not return audio content"`.
   - HEAD fails or times out: accept with a warning header
     `X-Audio-URL-Unreachable: true` in the response. The PWA can
     surface this. Don't fail the save — URL may be temporarily down,
     or behind a redirect that disallows HEAD.

Step 4 is opt-in via `PANKOSMIA_VALIDATE_AUDIO_URLS=true` (default
off — extra latency, optional safety net).

### 4.5 Detecting "this is an audio reference, not a regular ingredient"

Two options:

- **By path**: anything matching `audio_content/**/ref.json`. Simple,
  but assumes a path convention.
- **By content-type signal**: clients send
  `Content-Type: application/vnd.pankosmia.audio-ref+json` instead
  of `application/json` when writing audio references. Explicit, doesn't
  rely on path.

Recommend supporting both, with the content-type taking precedence
when present. Path is the fallback for legacy clients.

## 5. Upload flow — Strategy A (direct browser to Internet Archive)

```
┌─────────────────────────────────────────────┐
│ User in PWA                                  │
└─────────────────────────────────────────────┘
                  │
                  │ 1. clicks "Record" or "Upload audio"
                  ▼
┌─────────────────────────────────────────────┐
│ PWA — IA upload widget                       │
│ - if no IA creds: prompts user for their     │
│   IA S3 access key + secret (one-time)       │
│ - stores creds in localStorage (HttpOnly NA  │
│   in plain JS — see §7.1 for trust model)    │
└─────────────────────────────────────────────┘
                  │
                  │ 2. PUTs audio to IA's S3 endpoint
                  │    Endpoint: s3.us.archive.org/<item>/<filename>
                  │    Headers:
                  │      Authorization: LOW <access_key>:<secret>
                  │      x-archive-meta-mediatype: audio
                  │      x-archive-meta-licenseurl: https://creativecommons.org/...
                  │      x-archive-meta-collection: opensource_audio
                  ▼
┌─────────────────────────────────────────────┐
│ Internet Archive                             │
│ - accepts the upload                         │
│ - returns 200 with the canonical URL         │
└─────────────────────────────────────────────┘
                  │
                  │ 3. URL returned to PWA
                  ▼
┌─────────────────────────────────────────────┐
│ PWA constructs reference JSON                │
│ {url, type, license, duration_sec, ...}      │
└─────────────────────────────────────────────┘
                  │
                  │ 4. POST /burrito/ingredient/raw/<repo>?ipath=audio_content/01-01/ref.json
                  │    body: {"payload": "<the JSON above>"}
                  │    + cookie + X-Language-Code
                  ▼
┌─────────────────────────────────────────────┐
│ pankosmia_docker                             │
│ - validates schema + license (§4.4)          │
│ - optionally HEAD-validates URL              │
│ - writes ref.json to user's working branch   │
│ - opens or updates PR                        │
│ - returns {is_good: true, pr_url, ...}       │
└─────────────────────────────────────────────┘
```

### 5.1 IA credentials onboarding

First-time uploader's flow inside the PWA:

1. PWA detects no IA credentials in localStorage.
2. PWA shows modal: "Audio is stored on Internet Archive (a free,
   open content archive). To upload, you need an IA account and an
   S3 access key."
3. Two buttons:
   - "Create an account" → opens https://archive.org/account/signup in
     new tab.
   - "I have an account, get my keys" → opens
     https://archive.org/account/s3.php in new tab (where users see
     their existing access key + secret).
4. User pastes `access_key:secret` (or two fields) back into the PWA.
5. PWA stores in `localStorage` under `pankosmia.ia.credentials` (see
   §7.1 for the trust model).
6. Subsequent uploads are silent.

### 5.2 IA item naming convention

Each audio file lives inside an "item" on IA. Items can hold multiple
files. The PWA should pick item names predictably:

- Per language repo: one item per language repo, all audio in it.
- Item name: `pankosmia-<source>-<org>-<repo>` (URL-safe slug of the
  source/org/repo path).
- File names within the item: `<chapter>-<paragraph>_<take>.mp3` or
  similar; mirror the burrito's path convention.

This pattern lets one IA item act as the canonical store for one
language's audio. The catalog admin can curate item-level metadata
on IA (title, description, languages, tags) once per repo.

### 5.3 What IA returns

After a successful PUT, the file is available at:
```
https://archive.org/download/<item>/<filename>
```

This URL is what goes into the reference's `url` field. It's stable,
direct, and supports range requests for streaming playback.

### 5.4 Optional: server-side IA credential provisioning

A future enhancement (not required for v1): a deployment-level IA
account ("pankosmia-org") that contributors get to use via short-lived
upload tokens issued by `pankosmia_docker`. Endpoint shape:

```
GET /audio/ia-credentials
→ { access_key, secret, item_prefix, expires_at }
```

Server holds the deployment's IA root keys, mints scoped credentials
per-user-per-session. Avoids individual contributor signups.

**Defer to v2.** Add only if individual-account friction becomes a
real obstacle. The v1 model (each contributor has their own IA
account) is closer to "open content commons" values.

## 6. Upload flow — Strategy B (paste URL)

Simpler. No PWA-side upload logic at all.

```
1. User obtains audio URL elsewhere (uploads to IA via web UI,
   uses existing CC audio, etc.).
2. In PWA: clicks "Add audio reference"; pastes the URL.
3. PWA prompts for the required fields (type, license) if it can't
   detect from URL.
4. PWA POSTs the reference JSON to pankosmia_docker (same endpoint
   as Strategy A's step 4).
```

This is the fallback for:
- Users who don't want to give the PWA their IA credentials.
- Already-recorded audio that exists somewhere else (e.g.,
  cdn.door43.org has many OBS recordings).
- Audio hosts other than IA (any CC-licensed source).

A well-designed PWA exposes both Strategy A's "record / upload" button
AND Strategy B's "paste URL" input. Users pick.

## 7. Trust and security

### 7.1 IA credentials in localStorage

The PWA stores the user's IA access key and secret in plain
localStorage. **This is a real trust decision.**

Risks:
- Cross-site scripting in the PWA leaks credentials.
- Malicious browser extension reads localStorage.
- Shared computer: next user can find them.

Why this is acceptable for this use case:
- The IA credentials only grant upload to the user's IA items
  (scoped by IA's own permission model — users can't escalate to
  other accounts).
- The audio is CC-licensed (public) anyway; "leaking" the credentials
  doesn't reveal private content, only allows the attacker to
  impersonate the user for IA uploads.
- IA users can rotate keys at https://archive.org/account/s3.php
  if compromise is suspected.

What the PWA SHOULD do regardless:
- Warn users on first-key-entry: "These keys grant upload access to
  your IA account. Don't use on shared computers."
- Offer "Remove keys" button that clears localStorage.
- Prefer indexedDB with the credentials encrypted at rest if the
  PWA wants to be extra cautious (small UX cost, marginal real-world
  benefit given XSS still wins).

### 7.2 Server-side audio reference validation

`pankosmia_docker` does not store audio bytes, but it does
gatekeep what URLs land in burritos. Validation rules (per §4.4):

- Schema check (required fields present).
- License allowlist (configurable).
- Optional URL reachability + content-type check.

Operators who want stricter policy can additionally enforce:
- URL allowlist by host (e.g., only `archive.org`, `cdn.door43.org`).
  Config var: `PANKOSMIA_AUDIO_URL_HOSTS_ALLOWLIST=archive.org,cdn.door43.org`.
- License: stricter allowlist (e.g., only CC0 + CC-BY for
  redistribution-friendly content).

### 7.3 No proxying

`pankosmia_docker` does NOT proxy audio bytes. Playback goes
browser-to-host directly. This means:

- Server bandwidth stays minimal.
- Range requests work natively (host handles them).
- CORS comes from the host's policy. IA supports `Access-Control-Allow-Origin: *`
  for downloads; raw `archive.org/download/...` URLs play in any
  origin's PWA.

If a host doesn't allow cross-origin audio playback, that audio
host is unusable. The reference-validation step (§4.4) should HEAD-
check for `Access-Control-Allow-Origin` when `PANKOSMIA_VALIDATE_AUDIO_URLS`
is on.

## 8. Playback

PWAs play audio directly. No server involvement.

```jsx
function AudioPlayer({ refJson }) {
  return (
    <audio
      src={refJson.url}
      controls
      preload="metadata"
    />
  );
}
```

Mobile note: `preload="metadata"` is right for OBS-style use cases
(many short files; user picks one). For long-form playback, switch
to `preload="auto"` or implement progressive load.

## 9. Server-side implementation scope

Implementation inside `pankosmia_docker` for v1:

| Component | Effort |
|---|---|
| JSON schema validation for audio refs (§4) | 0.5 day |
| License allowlist check + env-var config | 0.25 day |
| Path/content-type detection (§4.5) | 0.25 day |
| Opt-in URL HEAD validation (§4.4 step 4) | 0.5 day |
| Tests | 0.5 day |
| Documentation in CLIENT_INTEGRATION.md (audio section) | 0.25 day |
| **Server-side total** | **~2 days** |

Notably absent: S3 client, multipart parsing, presigned URLs,
transcoding, storage management, audio bytes anywhere. This is
intentionally tiny.

## 10. PWA-side implementation scope (informational)

Lives in client apps, not in `pankosmia_docker`. Listed here for the
maintainer's awareness of what consumers need:

| Component | Where | Effort |
|---|---|---|
| IA S3 upload widget (Strategy A) | PWA | 2 days |
| Credential onboarding modal | PWA | 0.5 day |
| Paste-URL input (Strategy B) | PWA | 0.5 day |
| `<audio>` playback | PWA | 0.25 day |
| Reference JSON construction | PWA | 0.25 day |

Each PWA repo handles this independently. A shared library
(`pankosmia-audio-ref`?) could consolidate, but isn't required.

## 11. Migration from any prior "audio in burrito" data

If existing burritos contain audio bytes (e.g., from FS-mode
deployments where `audio_content/NN-PP_T.wav` was a real WAV file),
migrate by:

1. For each audio byte file: upload to IA (one-time script).
2. Replace the byte file with a `ref.json` pointing at the IA URL.
3. Commit the migration as a single PR per burrito.

Tooling: a small CLI (`pankosmia migrate audio --repo <path>`) that
walks `audio_content/**`, recognizes byte files (any `audio/*`
content-type), uploads to IA, writes ref.json siblings, deletes the
byte files. Out of scope for v1 implementation; document the path.

## 12. Open design decisions

### 12.1 Path convention: `ref.json` or no extension?

`audio_content/01-01/ref.json` is explicit but creates a parallel
structure to legacy `01-01_T.wav` paths.

Alternative: `audio_content/01-01.audioref` (custom extension).
Cleaner if you don't want the `.json` suffix; muddier if existing
tooling expects extensions to indicate file format.

**Recommend `ref.json`** — uses standard JSON, plays well with any
linter, and the path itself signals "this is metadata, not audio."

### 12.2 Multiple takes per slot?

OBS recording workflows often want N takes per paragraph, with one
marked "main." Two patterns:

- Single ref.json with an array: `{takes: [{...}, {...}], main_take_index: 0}`.
- Multiple ref.json files: `01-01/take_1.json`, `01-01/take_2.json`,
  `01-01/main.json` symlinks or duplicates the chosen one.

The single-file pattern is simpler and works fine in git. Recommend
single-file with takes array. Schema becomes:

```json
{
  "schema_version": 1,
  "takes": [
    { "url": "...", "type": "...", "license": "...", "duration_sec": 47, "label": "take 1" },
    { "url": "...", "type": "...", "license": "...", "duration_sec": 49, "label": "take 2" }
  ],
  "main_take_index": 1
}
```

If only one take, `takes` has one entry. The PWA always plays
`takes[main_take_index]`.

**Decision**: support both shapes in the schema. The "flat" v1 shape
(§4) is a degenerate case of the takes-array shape (one entry, main
index 0). Server validation accepts both.

### 12.3 Reference expiry / availability tracking

IA URLs are stable, but third-party URLs may rot. Should the server
periodically re-validate references?

**Recommend**: out of scope for v1. A separate "link checker"
service can crawl and surface dead references via the catalog's
PR mechanism. Don't bake this into `pankosmia_docker`.

### 12.4 Mirror-to-deployment-storage option?

Some operators may want a deployment-owned mirror of referenced
audio (e.g., to ensure availability even if IA disappears). Out of
scope for v1; could be added later as an optional middleware layer
or a periodic mirror job.

## 13. What this replaces in the prior planning

- `temp/CLIENT_INTEGRATION.md §14` — the `/burrito/audio/upload-url`
  / `/audio/finalize` / `/audio/download-url` presign roadmap entry.
  Remove from the roadmap; this doc supersedes.
- `temp/OBS_WRAPPER_SPEC.md §3.4` — the wrapper's audio cap
  workaround. Replaced by external-host playback (no cap concern).
- `temp/MIDDLEWARE_PLAN.md §3.4` — the middleware's audio pipeline.
  Deleted entirely; middleware is no longer needed for audio.

## 14. References

### Internet Archive

- IA S3 API: https://archive.org/services/docs/api/items.html
- IA account keys: https://archive.org/account/s3.php
- IA item metadata fields: https://archive.org/services/docs/api/metadata-schema/

### Adjacent CC audio hosts (for Strategy B users)

- door43.org CDN: https://cdn.door43.org/ (existing OBS audio in many languages)
- FaithComesByHearing: existing scripture audio
- Vimeo / SoundCloud: less ideal (proprietary, less stable), but
  Strategy B allows them if their URLs are direct.

### Spec docs in this set

- `BULK_OPS_SPEC.md` — Git Data API multi-file commits (parallel
  effort; audio is unrelated).
- `USER_STATE_SPEC.md` — replaces stub endpoints with real per-user
  state (parallel effort).
- `CLIENT_WRAPPER_GUIDE.md` — how PWA wrappers integrate (consumes
  this audio spec).
- `ARCHITECTURE_DECISIONS.md` — records why audio is external.
