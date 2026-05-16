# Architecture decisions

A record of the architectural choices that led to the current set of
implementation specs in `pankosmia_docker`. Captures the questions
considered, the alternatives evaluated, the reasoning, and the
trade-offs accepted.

This is a **decision log**, not an implementation spec. It exists so
future maintainers (and future-you in six months) understand *why*
the codebase is shaped the way it is, especially after upcoming
features (`AUDIO_STRATEGY.md`, `USER_STATE_SPEC.md`, `BULK_OPS_SPEC.md`)
land.

Audience: anyone reading the codebase or specs and asking "why this
shape and not another?"

---

## D1. Where do operational concerns live? Inside `pankosmia_docker`, not in a middleware service.

### Question

Several operational concerns sit awkwardly between the in-browser
client and the GitHub-bridge core:

- Authentication surface (single sign-on across PWAs).
- Per-user state persistence (replacing stub endpoints).
- Audio handling (the 700 KB cap problem).
- Bulk multi-file operations (atomic via Git Data API).
- Read caching, SSE fan-out, URL rewrites, deployment policy.

Where should these live? Three candidates:

- **A. In each client (PWA + wrapper)** — every client repo
  reimplements or wraps the relevant logic.
- **B. In a separate middleware container** — a new service between
  PWAs and `pankosmia_docker` that handles operational glue.
- **C. In `pankosmia_docker` itself** — extend the existing service
  to cover these concerns.

### Decision

**C, with two exceptions: audio (D2) and per-user state (D3).**

Operational concerns belong in `pankosmia_docker` when they need
GitHub's identity / write capability. Audio doesn't (it's externalised
entirely; D2). Per-user UI state doesn't either, under the current
single-origin-many-munchers deployment shape (it can live in the host
PWA's localStorage; D3). The wrapper (option A) stays thin. No
middleware container (option B).

### Reasoning

**Why not A (client-side workarounds)**:
- The client can't persist real per-user state — only per-device
  localStorage, which loses data across browser/device switches.
- The client can't make multi-file commits atomic — sequential
  single-file ops are not atomic.
- The client can't enforce server-side policy (CORS, rate limits,
  etc.) — clients can bypass.

**Why not B (middleware)**:
- Adds a deployable unit, doubles operational overhead.
- Adds a network hop.
- Creates an attractive nuisance — operational features stay there
  forever rather than going upstream where they belong.
- Forks the API surface (different deployments offer different
  features depending on whether middleware is configured).
- Most concerns are not deployment-specific (per-user state, audio
  pipeline, bulk ops all benefit every deployment) — they belong in
  the shared upstream.

**Why C (in `pankosmia_docker`)**:
- Single deployable, single auth surface, single source of truth.
- All deployments benefit from new features automatically.
- Existing GitHub OAuth, working-branch logic, PR opening can be
  reused for new features (bulk ops, audio reference validation).
- Code review enforces consistent API contract across deployments.

### Trade-offs accepted

- `pankosmia_docker` becomes less minimal. It grows from "GitHub
  bridge only" to "GitHub bridge + per-user state + bulk Git Data
  API ops + audio reference validation."
- The deliberate "minimal" identity of the codebase changes. This is
  acceptable; the new features are still narrow ("operational glue
  for hosted use cases") rather than business logic.

### What remains for deployment-specific configuration

Truly per-deployment concerns (CORS allowlist, rate limits, audit
destinations, IP/geo rules) are handled by either:
- `pankosmia_docker` env vars and Rocket fairings.
- A reverse proxy (Caddy or nginx) in front of `pankosmia_docker`.

Neither requires a custom middleware service.

### Implications for the implementation specs

This decision generates one in-scope implementation spec:

- `impl/BULK_OPS.md` — the four 501 endpoints via GitHub Git Data
  API.
- (Audio is the exception; see D2.)
- (Per-user state is also externalised, to the host PWA's
  localStorage; see D3. Server-side persistence is deferred —
  see `impl/USER_STATE_FUTURE.md`.)

And one client-side guide:

- `CLIENT_WRAPPER_GUIDE.md` — a thin React wrapper for PWAs.
  Includes the localStorage interceptor for state endpoints (D3).

---

## D2. Where does audio live? Externally, on Internet Archive (or another open content host).

### Question

Audio is the largest content type in the burrito ecosystem. Where
should audio bytes be stored?

- **A. Inside the burrito** (as plain audio files, e.g.,
  `audio_content/01-01_T.wav`) — the FS-mode pattern from
  `pankosmia-web`.
- **B. Inside `pankosmia_docker`'s storage**, separate from the
  burrito (e.g., volume-mounted audio cache) — the presign-URL
  pattern originally planned in `CLIENT_INTEGRATION.md §14`.
- **C. Outside the deployment entirely**, on an external CC-friendly
  host (Internet Archive, etc.) — burrito stores only references.

### Decision

**C — external audio, references only in the burrito.**

Primary host: Internet Archive (free, S3-compatible API, mission-aligned
with CC content, durable).
Fallback: paste any other CC-licensed URL (door43 CDN, etc.).

### Reasoning

**Why not A (audio in burrito as bytes)**:
- GitHub repos handle binary blobs poorly. A burrito with 50 OBS
  stories × 10 paragraphs × 3 takes × ~2 MB = ~3 GB of audio. Git's
  whole-repo-clone model breaks down.
- Even at smaller scales, every burrito-level operation (clone,
  pull, search) gets slow.
- GitHub's 100 MB single-file blob limit blocks any audio file
  larger than that.
- The 700 KB cap (for `pankosmia_docker`'s GitHub Contents API
  upload path) is unworkable for production audio.

**Why not B (audio in deployment storage)**:
- Couples `pankosmia_docker` to a storage backend choice (R2, B2,
  Supabase Storage, etc.) — each deployment must configure differently.
- Adds significant code (multipart, S3 client, presign signing,
  finalize endpoint).
- Audio bytes touch the server's network on upload.
- No discoverability — audio is locked inside the deployment.
- Server now has to think about backup, lifecycle, retention.

**Why C (external host)**:
- Zero audio infrastructure on the server. No storage, no bandwidth,
  no transcoding, no S3 SDK.
- The burrito stays small (reference files are ~200 bytes each).
- Internet Archive enforces CC licensing at upload time — automatic
  policy.
- IA's lifetime + non-profit status > most SaaS storage providers.
- Pre-existing CC-licensed audio (FaithComesByHearing, existing IA
  collections) can be referenced directly.
- Discoverability: audio is searchable on IA outside the Pankosmia
  stack.
- Uniform pattern for all audio use cases (OBS dub, scripture
  reading, alignment, etc.).

### Trade-offs accepted

- **Contributor onboarding adds a step**: users need an IA account
  (free signup) to use the primary upload flow (Strategy A in
  `AUDIO_STRATEGY.md`). Acceptable for translation work — contributors
  are typically willing to engage with open-content infrastructure.
- **Two auth contexts**: GitHub for content + IA for audio. Mitigated
  by storing IA credentials in localStorage after one-time entry.
- **External host longevity risk**: if IA disappears, links break.
  IA's 25-year track record makes this acceptable; paste-URL fallback
  lets users point at alternatives.
- **No transcoding control**: host serves whatever format users upload.
  Acceptable in exchange for the simplification.
- **No in-app recording without external auth**: users can't just
  click "record" and have it Just Work — they need IA credentials or
  must record elsewhere. The wrapper's `AudioRecorder.jsx` simplification
  reflects this (substantial code removed).

### Why this is the one exception to D1

Audio is the case where keeping things out of `pankosmia_docker`
is strictly better than putting them in. The other operational
concerns (per-user state, bulk ops) benefit from `pankosmia_docker`'s
GitHub integration and identity. Audio doesn't — it just needs to be
referenceable. Outsourcing the storage entirely is cleaner than
adding storage features to the server.

### Implications

- `AUDIO_STRATEGY.md` is the implementation spec.
- The historical roadmap entry for `/burrito/audio/upload-url`
  presign flow (in earlier versions of `CLIENT_INTEGRATION.md §14`)
  is removed.
- The client wrapper's audio cap workaround is removed.
- The `core-client-workspace/munchers/OBS/AudioRecorder.jsx` muncher
  component is largely replaced by a thin "IA upload" widget in
  client PWAs (Strategy A) and/or a paste-URL input (Strategy B).

---

## D3. Per-user UI state lives in the host PWA's localStorage. Server-side persistence is deferred.

### Question

`pankosmia_docker` exposes endpoints for per-user UI state
(`/navigation/bcv/*`, `/settings/*`, `/app-state/*`) inherited from
the FS-mode `pankosmia-web` ancestor. In FS-mode they wrote to disk.
In GitHub mode they're stubs — they accept writes silently and
return defaults on reads. Where should this state actually live?

Three candidates:

- **A. Server-side, persisted** (e.g., sqlite-on-volume). Survives
  device/browser changes. Sharable across origins.
- **B. Host PWA's localStorage**. Per-browser-per-device. Shared
  across munchers loaded into one host PWA (same origin).
- **C. Drop these endpoints**. Munchers track their own state, no
  attempt at cross-muncher sharing.

### Decision

**B — host PWA's localStorage, for the current single-origin-
many-munchers deployment shape.**

`pankosmia_docker` does not persist per-user UI state. The host
PWA owns its `localStorage` and shares it across the munchers it
embeds (OBS muncher, text-translation muncher, etc.).

### Reasoning

The deployment we're building toward is **one host PWA per
operator**, with several munchers embedded into it. All munchers
under one origin → one shared localStorage → state naturally
flows across munchers without any server round-trip.

For this shape, server-side persistence (option A) is over-engineering:
- ~3.5 days of implementation work (sqlite + endpoint refactor +
  schema + tests).
- A new dependency (`rusqlite` / `sqlx`).
- A new operator concern (state DB path, backup, etc.).
- A DB round-trip on the request path for state reads/writes.

For zero user-visible UX benefit over what localStorage already
provides in this deployment shape.

The cost of B (per-browser-per-device persistence) is acceptable:
- Translators usually work on one device per session.
- Clearing browser data wipes prefs — rare; users tolerate this.
- No cross-origin sharing problem when munchers live in one host
  PWA.

Option C (drop the endpoints) is discarded because existing
`pankosmia-web` clients rely on the wire surface being there.

### Trade-offs accepted

- **Multi-device drift**: a user's phone has its own state, separate
  from their laptop. Tolerable for translation workflows.
- **Multi-origin drift** (the bigger latent issue): if multiple PWAs
  on different origins ever consume the same `pankosmia_docker`
  server, they each have isolated localStorage and a user's prefs
  diverge across them. Acceptable today because we're not deploying
  that shape. **If we ever do, revisit and adopt the server-state
  spec (see `impl/USER_STATE_FUTURE.md`).**
- **The stub endpoints are dishonest**: they accept writes that go
  nowhere. Mitigated client-side by the wrapper's localStorage
  interceptor (see `CLIENT_WRAPPER_GUIDE.md` §5) — calls don't even
  hit the server. Cleaner alternative would be to return 501 from
  the endpoints; revisit if dishonest-stub semantics confuse any
  consumer.

### Implications

- `CLIENT_WRAPPER_GUIDE.md` keeps the **localStorage interceptor**
  pattern as the recommended client-side handling for these
  endpoints. The wrapper transparently routes reads/writes to
  `localStorage`, so consuming code calls the endpoints as if they
  were persistent.
- `CLIENT_INTEGRATION.md` pitfall P6 ("Persisting BCV / typography
  in pankosmia-docker storage") **stays** as advice — it's accurate
  under the current design.
- The server keeps the stub endpoints (silent accept + return
  defaults). No new env vars. No new dependencies. No DB.
- `impl/USER_STATE_FUTURE.md` is preserved as a forward-looking
  spec for the revisit trigger (multi-origin / multi-device drift
  becoming a real problem).

---

## D4. Polyfills are not the right answer for missing server features.

### Question

When a server feature is missing or returns 501 (e.g., the four bulk
ops), should clients (in browsers or in a middleware layer) polyfill
by orchestrating single-file ops?

### Decision

**No.** Wait for the server-side implementation. Surface clean 501s
in the interim.

### Reasoning

Polyfilling bulk ops in the client:
- Loses atomicity. Partial failure leaves inconsistent state.
- Generates N commits per logical bulk op (cluttering PRs).
- Brittle (e.g., metadata regen polyfill needs to read the tree,
  diff against current metadata, decide which entries to update —
  each step a potential failure point).
- Forks the effective API: deployments with polyfill vs without
  behave differently.

The right place for these features is upstream (`BULK_OPS_SPEC.md`).
Until that lands, the affected client UI surfaces 501 with a clear
message.

### Trade-offs accepted

- Affected features (`core-contenthandler_text_translation`'s "delete
  a book", USFM bulk import) are unavailable until the upstream
  endpoints ship.
- This is a deliberate prioritization: better to have honest 501s
  than fragile polyfills.

---

## D5. GitHub mode embeds a PR review workflow; this is a feature, not a workaround.

### Question

In FS mode, saves were direct fs writes — immediate, no review. In
GitHub mode, saves go through a per-user working branch and open a
PR.

Should this PR flow be hidden from translators (treat it as a save +
async sync), or surfaced (translators see "your edit is in PR #N
awaiting review")?

### Decision

**Hide GitHub mechanics from translators**; **surface PR status as
optional context** for those who want it.

### Reasoning

- Translators don't need to know about Git, branches, PRs. The UI
  should say "Saved — awaiting review by language admin" not "your
  edit is on branch `pankosmia-edit-<login>` in PR #42."
- BUT: for diagnostic / progress-tracking purposes, the wrapper's
  `usePankosmiaEvents` exposes `pr_url` to host PWAs that want to
  show "view your edits in progress" or admin/reviewer UIs.

### Implications

- Save responses include `pr_url`, `pr_number`, `branch`, `status`.
- The wrapper surfaces these via `save-success` events.
- Translator UI uses `status` and `is_good`; admin UI can use
  `pr_url` and `pr_number`.
- `CLIENT_INTEGRATION.md` pitfall P7 ("Showing GitHub-side terms in
  the translator UI") is preserved as a UX guideline.

---

## D6. The catalog is the source of truth for "what languages exist."

### Question

When the server needs to know "is this language registered?", where
does it look?

- **A. The catalog repo on GitHub** (the design in
  `CATALOG_REPO_TEMPLATE.md`).
- **B. A server-side database**.
- **C. The set of language repos the GitHub App is installed on**.

### Decision

**A — the catalog is canonical.**

### Reasoning

- The catalog is text in a public GitHub repo, with a normal PR
  workflow for additions. Vetting is human + automated.
- Server-side DB would need a sync mechanism with the catalog repo
  anyway; just read the catalog directly.
- The set of App-installed repos is a permission signal, not a
  registration signal; some installations may exist for testing /
  preparation before catalog admission.

### Implications

- `pankosmia_docker` clones the catalog repo locally; refreshes on
  webhook + 15-min poll.
- Endpoints route on `<source>/<org>/<repo>` from the catalog.
- A language not in the catalog returns 404 regardless of App
  permissions.

---

## D7. Webhooks are optional; polling is the safety net.

### Question

Should the server require webhooks for live propagation of upstream
changes?

### Decision

**No.** Webhooks are recommended for sub-second propagation, but the
server falls back to a 15-minute periodic fetch if webhooks aren't
configured.

### Reasoning

- Lower onboarding friction: language admins don't have to wire up
  webhooks before their repo works in the deployment.
- The 15-minute lag is acceptable for translation review workflows
  (admins merge once per session, not once per second).
- Webhook reliability varies (GitHub is generally reliable, but
  network/config issues can cause missed events). A polling safety
  net catches anything missed.

### Implications

- `HOSTING.md §6` (webhook setup) is documented as recommended, not
  required.
- Operators can defer webhook setup until needed.
- The 15-min poll cadence is configurable via env var.

---

## Open decisions (deferred, not yet decided)

These came up during planning but were explicitly deferred:

### O1. Server-side IA credential provisioning (audio Strategy A v2)

Currently, contributors need their own IA accounts. A future
enhancement would let `pankosmia_docker` mint short-lived IA upload
credentials from a deployment-owned IA account, eliminating per-user
signups.

**Status**: deferred. v1 prioritizes the simpler per-user pattern.
Revisit if onboarding friction becomes a real obstacle.

### O2. Audio file reachability validation

The audio spec has an opt-in `PANKOSMIA_VALIDATE_AUDIO_URLS` config
that HEAD-checks audio URLs at write time. Cost: ~200ms per write.
Benefit: rejects broken references immediately.

**Status**: opt-in, default off. Operators decide per deployment.

### O3. Persistent cache layer

A read cache for `/burrito/ingredient/raw/*` could reduce GitHub API
load. Phase 2 territory — useful only at higher concurrency than the
current deployment sees.

**Status**: deferred. Add when metrics justify.

### O4. Conflict resolution UI

When two users edit the same file simultaneously, the second save
sees a merge conflict from GitHub's PUT. Currently surfaces as a 502.
A proper `/burrito/resolve-conflict/<repo>` endpoint + client UI is
designed but not built.

**Status**: deferred. Revisit when concurrent editing on the same
ingredient becomes common.

### O5. Multi-take audio reference shape

The audio reference schema (`AUDIO_STRATEGY.md §4`) supports either a
single take or an array of takes with a "main" pointer. Which shape
becomes idiomatic?

**Status**: schema supports both. Convention emerges from PWA usage.

### O6. Migration tooling for existing FS-mode audio data

If existing burritos contain audio bytes (from FS-mode deployments),
a migration CLI could upload them to IA and replace the byte files
with reference JSONs.

**Status**: out of scope for v1. Documented in `AUDIO_STRATEGY.md §11`
as a future tool.

---

## What this set of docs replaces from earlier planning

Earlier planning rounds produced:

- An "OBS wrapper" spec that compensated for many server-side gaps
  client-side.
- A "middleware container" plan that proposed a separate service in
  front of `pankosmia_docker`.
- An "upstream bulk ops" spec arguing for server-side bulk operations.
- An earlier draft of D3 that proposed server-side sqlite persistence.

After review:

- Server-side **bulk ops** are still the right answer (`impl/BULK_OPS.md`).
- Server-side **audio storage** is the wrong answer; audio is
  externalised (`impl/AUDIO_STRATEGY.md`).
- Server-side **per-user UI state** is over-engineering for the
  single-origin-many-munchers deployment shape; localStorage in the
  host PWA covers it (D3 above). The sqlite spec is preserved as
  `impl/USER_STATE_FUTURE.md` for revisit if the deployment shape
  changes.
- The middleware plan was retired — per-deployment policy is handled
  by env vars and a reverse proxy.

The current spec set:

| Doc | Status |
|---|---|
| `impl/BULK_OPS.md` | Implementation spec. Active. |
| `impl/AUDIO_STRATEGY.md` | Implementation spec. Active. Reflects D2. |
| `impl/USER_STATE_FUTURE.md` | **Deferred.** Preserved for revisit. Reflects the case if D3 inverts. |
| `CLIENT_WRAPPER_GUIDE.md` | Active. Slim wrapper + localStorage interceptor pattern. |
| `DECISIONS.md` | This doc. |

---

## References

### Specs in this set

- `impl/BULK_OPS.md`
- `impl/AUDIO_STRATEGY.md`
- `impl/USER_STATE_FUTURE.md` (deferred)
- `CLIENT_WRAPPER_GUIDE.md`
- `INDEX.md` (orientation for the set)

### `pankosmia_docker`'s existing docs

- `CLIENT_INTEGRATION.md` — minor updates when AUDIO and BULK_OPS
  ship (remove their entries from the 501 list, add their sections).
  The BCV-localStorage pitfall (P6) **stays** — it's accurate under
  D3.
- `HOSTING.md` — adds audio env vars when AUDIO ships.
- `SECURITY.md` — unchanged.
- `CATALOG_REPO_TEMPLATE.md` — unchanged.
- `ARCHITECTURE.md` — unchanged in the immediate term; refer to
  `DECISIONS.md` for the why behind the current shape.
