# Pankosmia docker docs — index

This is the reading guide for the `pankosmia_docker` documentation.
The docs cover both **what the system is today** (architecture,
hosting, security, client integration) and **what's being built
next** (the implementation specs under `impl/`).

---

## What's here

### Operator + integrator docs (current system)

| File | For |
|---|---|
| `ARCHITECTURE.md` | Newcomer overview. Trust topology, edit flow, storage layout. |
| `HOSTING.md` | Operator running the server. Env vars, GitHub App setup, reverse proxy, webhooks, Railway-via-GHCR. |
| `CLIENT_INTEGRATION.md` | Server-side contract for JS/web client developers. Endpoint surface, save/read/SSE patterns, error semantics. |
| `CLIENT_WRAPPER_GUIDE.md` | Client-side patterns for PWA developers building a thin React wrapper. Per-context shims, localStorage state model. |
| `CATALOG_REPO_TEMPLATE.md` | Concrete setup for the language catalog repo. |
| `SECURITY.md` | Threat model + defenses. Auth, ACLs, path traversal, edit-spam mitigation. |
| `DATA_MODEL.md` | Entity catalog: who lives where, who owns what. |
| `SCALING.md` | Capacity planning, per-language locks, blocking pools, SSE fan-out. |

### Architecture decisions (the why)

| File | Captures |
|---|---|
| `DECISIONS.md` | The architectural decisions that shaped the codebase. D1 (in-house vs middleware), D2 (external audio), D3 (localStorage-canonical for current phase), D4 (no client-side polyfills), D5 (PR-flow hidden from translators), D6 (catalog-canonical languages), D7 (webhooks-optional). |

### Implementation specs

| File | Implements | Effort | Status |
|---|---|---|---|
| `impl/AUDIO_STRATEGY.md` | External audio model (Internet Archive primary, paste-URL fallback). Server-side: validate audio reference JSON, license allowlist. | ~2 days | **Shipped.** See `CLIENT_INTEGRATION.md` §7b. |
| `impl/BULK_OPS.md` | The four 501 endpoints via GitHub Git Data API for atomic multi-file commits. | ~5–8 days | **Shipped.** Includes metadata regeneration, which uses git blob sha1 as the checksum (documented behaviour delta from the FS-mode md5 — see `CLIENT_INTEGRATION.md` §7c). |

### Deferred (documented but not in current scope)

| File | Status |
|---|---|
| `impl/USER_STATE_FUTURE.md` | Server-side sqlite-backed per-user state. **Deferred.** The current "one origin, many munchers" design shares state via host-PWA localStorage — sufficient for the common case. Revisit only if multi-origin / multi-device drift becomes a real complaint. |

---

## Suggested reading order

For someone new to the codebase:

1. **`ARCHITECTURE.md`** — what the system is.
2. **`DECISIONS.md`** — why it's shaped that way.
3. **`CLIENT_INTEGRATION.md`** — what clients see.
4. **`CLIENT_WRAPPER_GUIDE.md`** — what client code looks like.
5. **`HOSTING.md`** — running it.
6. **`SECURITY.md`** — threat model.

For someone about to implement one of the upcoming features:

1. Skim `DECISIONS.md` (especially D1 and D2 if audio).
2. Read the relevant spec under `impl/`.
3. Check `CLIENT_INTEGRATION.md` and `HOSTING.md` for the doc-updates section that lands with the implementation.

---

## Edits to existing docs as each spec ships

### When `impl/AUDIO_STRATEGY.md` lands

| Doc | Change |
|---|---|
| `CLIENT_INTEGRATION.md` §14 | Remove the audio presign entries (`/burrito/audio/upload-url`, etc.). Audio is external; no server-side presign needed. |
| `CLIENT_INTEGRATION.md` | Add a section: "Audio references" — describe the reference JSON format (mirrors `impl/AUDIO_STRATEGY.md` §4). Add to §13 endpoint quick reference: writes to `audio_content/**/ref.json` go through the standard ingredient endpoint. |
| `HOSTING.md` §2 | Add `PANKOSMIA_ALLOWED_LICENSES`, `PANKOSMIA_AUDIO_URL_HOSTS_ALLOWLIST`, `PANKOSMIA_VALIDATE_AUDIO_URLS` env vars. |

### When `impl/BULK_OPS.md` lands

| Doc | Change |
|---|---|
| `CLIENT_INTEGRATION.md` §14 | Remove the four bulk-op 501 entries. |
| `CLIENT_INTEGRATION.md` | Add a section: "Bulk operations" — describe the four newly-implemented endpoints in the same shape as single-file save docs. Update §13 quick reference. |

### When `impl/USER_STATE_FUTURE.md` lands (if ever)

Only relevant if the deferred decision is reversed. See that file's
preamble for the revisit trigger and full spec.

---

## Cross-references between docs

```
INDEX.md (this file)
  ├─ orients new readers
  └─ catalogs everything

DECISIONS.md
  ├─ D1 → BULK_OPS, USER_STATE_FUTURE, CLIENT_WRAPPER_GUIDE
  ├─ D2 → AUDIO_STRATEGY
  ├─ D3 → CLIENT_WRAPPER_GUIDE (localStorage pattern); USER_STATE_FUTURE (the deferred path)
  └─ D4 → BULK_OPS

impl/AUDIO_STRATEGY.md
  └─ references CLIENT_WRAPPER_GUIDE / CLIENT_INTEGRATION for the
     consuming write endpoint

impl/BULK_OPS.md
  └─ no upstream dependencies (orthogonal to audio)

CLIENT_WRAPPER_GUIDE.md
  ├─ describes the wrapper pattern PWAs use
  ├─ documents the localStorage interceptor (D3, current phase)
  └─ references CLIENT_INTEGRATION.md for the server-side contract
```
