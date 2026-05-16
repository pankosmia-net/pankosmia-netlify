# Client wrapper guide

How PWAs and other client apps integrate with `pankosmia_docker`, and
the recommended shape for a small shared "wrapper" component that
handles the common plumbing (auth, language code routing, save events).

This guide describes the **client side** of the integration. The
server-side contract lives in `CLIENT_INTEGRATION.md`.

Audience: developers building PWAs against this server, plus maintainers
who may publish a shared client library.

---

## 1. The role of a wrapper

A wrapper is a small reusable layer that consuming PWAs include in
their bundle. It does four jobs:

1. **Authentication state** — exposes "are we signed in, who is the
   user" via a React context, and the sign-in flow.
2. **Language code routing** — holds the current `languageCode`, and
   attaches `X-Language-Code` on writes.
3. **Save event surfacing** — exposes save responses (including PR
   URLs) to host PWAs so they can show "your edit is in PR #N
   awaiting review."
4. **Per-context shims for legacy clients** — small React contexts
   that older munchers (extracted from `core-client-workspace`)
   expect to find.

What a wrapper does **not** do:

- It does not compensate for missing server features that exist on
  the server. Audio is external (`impl/AUDIO_STRATEGY.md`), bulk ops
  are server-side (`impl/BULK_OPS.md`). What the wrapper DOES handle
  client-side, by design: per-user UI state via localStorage (see §5
  and `DECISIONS.md` D3) — this is the chosen architecture, not a
  workaround.
- It does not host a backend. No proxy, no middleware. Just
  in-browser React infrastructure.
- It does not do CORS / auth orchestration server-side. That's
  `pankosmia_docker`'s job.

The wrapper is **thin**. Estimated ~200 lines for the core, plus
per-muncher adapters where needed.

## 2. Single integration point

```tsx
import { PankosmiaProvider } from '@pankosmia/client-wrapper';

<PankosmiaProvider
  apiBase="https://pankosmia-web.up.railway.app"
  languageCode="es"
  onAuthRequired={() => window.location.href = `${apiBase}/auth/start?redirect=${encodeURIComponent(location.pathname)}`}
>
  <YourPWA />
</PankosmiaProvider>
```

Inside the provider, the wrapper installs:

- A scoped `fetch` interceptor that injects `credentials: 'include'`
  and `X-Language-Code` on non-GET requests whose URL matches
  `apiBase`.
- A `/me` cache with refresh on focus.
- A 401 handler that calls `onAuthRequired`.
- An event emitter for save responses (so host PWAs can react).

## 3. Public hooks

```ts
// Authentication
const { user, signedIn, signIn, signOut } = useAuth();
// user: { github_user_id, login, name, email, avatar_url } or null

// Language code
const langCode = useLanguageCode();
const setLangCode = useSetLanguageCode();

// Save events (PR URLs, etc.)
usePankosmiaEvents((event) => {
  switch (event.type) {
    case 'save-success':
      // event has: { repo, ipath, pr_url, pr_number, branch, status }
      toast(`Saved — PR #${event.pr_number}`);
      break;
    case 'auth-required':
      // wrapper already called onAuthRequired; host can react too
      break;
  }
});

// Convenience for raw API calls
const api = useApi();
const repo = await api.get('/burrito/metadata/raw/<source>/<org>/<repo>');
```

## 4. What the wrapper handles, what it doesn't

| Concern | Where it's handled |
|---|---|
| `/settings/*`, `/navigation/bcv/*`, `/app-state/*` per-user state | Wrapper's **localStorage interceptor** (§5 below). The server's endpoints are wire-compatible stubs; the wrapper short-circuits them to localStorage before they hit the network. |
| Audio bytes | External (Internet Archive); see `impl/AUDIO_STRATEGY.md`. Wrapper writes audio **references** (small JSON) via the standard ingredient endpoint. |
| Bulk multi-file commits | Server, via GitHub Git Data API; see `impl/BULK_OPS.md`. Wrapper just calls the endpoints. **Does not polyfill** via sequential single-file ops (would lose atomicity). |
| URL rewrites (e.g. OBS-images to door43 CDN) | Wrapper exposes a small rewrite-rules registry. Cheap to extend per-PWA. |

## 5. The localStorage interceptor — for state endpoints

Per `DECISIONS.md` D3, per-user UI state (BCV cursor, language
selection, typography, current project) lives in the host PWA's
`localStorage`, **not** in `pankosmia_docker`. The wrapper makes this
transparent to consuming code:

```ts
// Consuming code calls these as normal HTTP endpoints:
api.get('/navigation/bcv')          // reads from localStorage
api.post('/navigation/bcv/JAS/1/1') // writes to localStorage
api.get('/settings/languages')      // reads from localStorage
// ...etc.

// The wrapper's interceptor routes these to a small localStorage
// adapter (typically scoped by `pankosmia.${user.login}.${langCode}.<key>`).
// No HTTP request is sent for these paths. The server's stub
// endpoints are bypassed.
```

The interceptor logic:

```ts
// Pseudocode for the interceptor's matching rules.
const stateEndpoints = [
  /^\/navigation\/bcv(\/.*)?$/,
  /^\/settings\/languages(\/.*)?$/,
  /^\/settings\/typography(\/.*)?$/,
  /^\/settings\/typography-feature(\/.*)?$/,
  /^\/app-state\/current-project(\/.*)?$/,
  /^\/i18n\/used-languages$/,
];

function shouldShortCircuit(url) {
  const path = new URL(url, apiBase).pathname;
  return stateEndpoints.some((re) => re.test(path));
}
```

Why this pattern:

- **One-origin-many-munchers**: a host PWA embeds OBS, text
  translation, and other munchers under one origin. They naturally
  share `localStorage`. State flows across munchers without server
  round-trips.
- **No server-side dependency**: `pankosmia_docker` doesn't need
  sqlite, a state DB on the volume, or per-user persistence code.
  Server stays focused on the GitHub bridge.
- **Cleaner than the stub-endpoint approach**: server returns the
  same defaults / silent accept as before for any consumer that
  doesn't use the wrapper, so the wire surface is unchanged. The
  wrapper just avoids the dishonest round-trip.

When `localStorage` ISN'T enough:

- **Multi-device**: state doesn't sync between a user's laptop and
  phone. Tolerable for translation workflows; if it ever becomes a
  real complaint, revisit `impl/USER_STATE_FUTURE.md`.
- **Multi-origin**: if multiple PWAs on different origins consume the
  same `pankosmia_docker`, each origin's localStorage is isolated.
  Same revisit trigger.
- **Cleared browser data**: prefs reset to defaults. Same as any
  localStorage-backed feature.

## 6. Adapter pattern for legacy munchers

PWAs that embed components extracted from `core-client-workspace`
(notably the OBS muncher and the text-translation muncher) need a
small adapter layer that provides the React contexts those munchers
expect.

### 6.1 The contexts the OBS muncher reads

| Context | Source | Shape | Notes |
|---|---|---|---|
| `OBSContext` | `core-client-workspace/src/contexts/obsContext.js` (vendor it) | `{ obs: [chapter, paragraph], setObs: fn }` | Navigation state. |
| `DebugContext` | `pankosmia-rcl` | `{ debugRef: RefObject<any> }` | Debug logging plumbing. |
| `I18nContext` | `pankosmia-rcl` | `{ i18nRef: RefObject<I18nDict> }` | UI string lookups. |

### 6.2 OBSWrapper helper

The wrapper package exposes an `<OBSWrapper>` that provides these
contexts plus a no-op replacement for the workspace's
`RequireResources` (which today calls `/git/list-local-repos`, a
legacy FS-mode endpoint not present in `pankosmia_docker`).

```tsx
import { PankosmiaProvider } from '@pankosmia/client-wrapper';
import { OBSWrapper } from '@pankosmia/client-wrapper/obs';
import { OBSEditorMuncher } from 'core-client-workspace/munchers/OBS/OBSEditorMuncher';

<PankosmiaProvider ...>
  <OBSWrapper metadata={burritoMetadata}>
    <OBSEditorMuncher metadata={burritoMetadata} />
  </OBSWrapper>
</PankosmiaProvider>
```

The OBS muncher needs no code changes — just its dependencies
(`pankosmia-rcl`, `@wavesurfer/react`, `wavesurfer.js`, MUI) provided
via the host PWA's package.json.

### 6.3 OBS-specific endpoint usage

The OBS muncher's endpoints, against `pankosmia_docker`:

| Endpoint | Use | Status |
|---|---|---|
| `GET /burrito/ingredient/raw/<repo>?ipath=content/NN.md` | Read story markdown | ✅ |
| `POST /burrito/ingredient/raw/<repo>?ipath=content/NN.md` | Save story | ✅ |
| `GET /burrito/paths/<repo>` | List files | ✅ |
| `POST /burrito/ingredient/copy/<repo>?src_path=&target_path=&delete_src=` | Rename audio reference files | ✅ |
| `POST /burrito/ingredient/delete/<repo>?ipath=...` | Delete audio reference | ✅ |
| `POST /burrito/ingredient/revert/<repo>?ipath=...` | Revert (semantics differ — see warning) | ⚠ |

The muncher's historical audio recording code (`AudioRecorder.jsx`,
~1000 lines) is **not used as-is** against the new model. Audio in
`pankosmia_docker` is referenced externally; see §6.4.

### 6.4 Audio integration for OBS

The OBS muncher historically POSTed audio bytes to
`/burrito/ingredient/bytes/<repo>?ipath=audio_content/NN-PP/...wav`.
That flow does not apply with external audio.

Two integration paths for PWAs hosting the OBS muncher:

- **Replace the muncher's `AudioRecorder.jsx`** with a small audio
  reference component:
  - "Record" button → opens IA upload widget (Strategy A) → on
    success, writes `audio_content/NN-PP/ref.json` via the standard
    ingredient endpoint.
  - "Paste URL" input (Strategy B) → user provides existing audio
    URL → wrapper validates → writes `ref.json`.
  - Playback uses `<audio src={ref.url}>`.

- **Skip audio in the OBS PWA**: present text-only OBS. Audio is
  added later via a dedicated audio-management UI that operates on
  the same burrito.

The reference file shape is defined in `AUDIO_STRATEGY.md §4`.

### 6.5 Video endpoints — not available

The muncher's `OBSEditorMuncher:handleExportVideoParagraph` and
`handleExportVideoStory` call `POST /video/obs-para/<repo>` and
`POST /video/obs-story/<repo>`. These don't exist in `pankosmia_docker`
and there's no planned implementation.

Either:
- Hide / disable the "Export Video" menu items in the host PWA.
- Implement video export client-side (e.g., ffmpeg.wasm in the
  browser) — substantial effort, out of scope here.

## 7. Structural edits — what works

The OBS muncher (and other munchers) make these structural changes
to the burrito; all of them work through `pankosmia_docker` with no
wrapper involvement:

| Operation | Endpoint | Status |
|---|---|---|
| Edit existing ingredient | `POST /burrito/ingredient/raw/...` | ✅ |
| Create new ingredient | First `POST /burrito/ingredient/raw/...` creates the file | ✅ |
| Delete ingredient | `POST /burrito/ingredient/delete/...` | ✅ |
| Rename/move (copy + delete src) | `POST /burrito/ingredient/copy/...?delete_src=true` | ✅ |
| Revert (note: GitHub-mode semantics) | `POST /burrito/ingredient/revert/...` | ⚠ See note below |

The "revert" semantics differ from FS-mode `.bak` restoration. In
GitHub mode, revert restores from upstream HEAD. For an audio
reference file written in this session that's never been merged
upstream, revert deletes the file (because there's no upstream version
to revert to). Host PWA UI should communicate this when offering a
"revert" / "undo" action.

## 8. Bulk operations — handled server-side

For consumers that need bulk operations (e.g.,
`core-contenthandler_text_translation` deleting a book of many
chapters), `pankosmia_docker` implements four endpoints via GitHub's
Git Data API (see `impl/BULK_OPS.md`):

- `POST /burrito/ingredients/delete/<repo>?ipath=<prefix>` — bulk delete
- `POST /burrito/metadata/remake-ingredients/<repo>` — regenerate metadata
- `POST /burrito/ingredient/zipped/<repo>?ipath=<prefix>` — zip upload
- `POST /burrito/zipped/<repo>` — replace whole repo from zip

The wrapper does **not** polyfill these. Calls pass through. The host
PWA receives the same `{is_good, pr_url, pr_number, ...}` envelope
for bulk ops as for single-file saves.

## 9. Local development

Two backends to point at:

- **Local FS-mode** (legacy): `VITE_API_BASE=http://127.0.0.1:19119`.
  No sign-in. Best for fast iteration. Matches the historical
  `pankosmia-web` desktop experience.
- **Hosted GitHub-mode**: `VITE_API_BASE=https://your-pankosmia.example`.
  Requires GitHub App setup per `HOSTING.md`.

CORS: the hosted server must allow the dev origin (e.g.,
`http://localhost:5173`). Configure via `pankosmia_docker`'s CORS
allowlist env var.

## 10. Module layout for a shared wrapper package

If the wrapper is published as a shared npm package:

```
@pankosmia/client-wrapper/
├── package.json
├── README.md
├── src/
│   ├── index.ts                  — public exports
│   ├── provider.tsx              — <PankosmiaProvider>, context
│   ├── fetch-interceptor.ts      — auth + language header injection
│   ├── auth.ts                   — useAuth, /me caching
│   ├── events.ts                 — usePankosmiaEvents
│   ├── api-client.ts             — useApi (light wrapper around fetch)
│   ├── state-interceptor.ts      — short-circuits /settings/*, /navigation/bcv/*, /app-state/* to localStorage
│   ├── rewrite-rules.ts          — extensible URL rewrite registry
│   └── obs/
│       ├── index.ts              — public exports for OBS
│       ├── OBSContext.ts         — copied from workspace
│       ├── OBSWrapper.tsx        — provides OBSContext + RequireResources shim
│       ├── RequireResources.tsx  — no-op shim
│       └── MarkdownField.jsx     — vendored from core-client-workspace
└── test/
```

If this is built as a one-off in a single PWA repo rather than a
shared package, the structure is the same, just under that PWA's
`src/wrapper/`.

## 11. Implementation effort

For a fresh wrapper package implementing the surface in §3 and the
OBS adapter in §6:

| Component | Days |
|---|---|
| Repo scaffolding, TypeScript config, build/publish | 0.5 |
| `<PankosmiaProvider>` + context plumbing + fetch interceptor | 1 |
| `useAuth`, /me caching, 401 handling | 0.5 |
| `useLanguageCode`, `useApi`, `usePankosmiaEvents` | 0.5 |
| localStorage state interceptor (§5) | 0.5 |
| OBS adapter (`<OBSWrapper>`, vendored MarkdownField, etc.) | 0.5 |
| TypeScript types, README, tests | 0.5–1 |
| **Total** | **~3.5 days** |

Most of the work is contexts + interceptors; the localStorage state
interceptor is the only "compensation" the wrapper does, and it's a
deliberate architectural choice (D3) rather than a workaround.

## 12. Common pitfalls (carried over from the original integration doc)

- **P1: Forgetting `credentials: 'include'`** — the wrapper handles
  this for you, but only for fetches that go through `useApi` or hit
  URLs matching the configured `apiBase`. If you `fetch()` somewhere
  the interceptor doesn't see, you'll miss the session.

- **P2: Sign-in popup** — modern browsers' third-party cookie rules
  break OAuth-style flows in popups. The wrapper's `onAuthRequired`
  default is a top-level redirect; keep it that way.

- **P3: Mixing `localhost` and `127.0.0.1` in dev** — browsers treat
  them as different origins; session cookies don't cross. Pick one
  and stick to it through `PANKOSMIA_PUBLIC_ORIGIN`.

- **P4: `Accept: text/event-stream` on a regular fetch** — lands on
  the SSE handler; the request hangs. Don't set `Accept` on reads;
  the default is fine.

- **P5: Not closing `EventSource` on unmount** — accumulates orphan
  streams. Always close in `useEffect` cleanup.

- **P6: Assuming `pankosmia_docker` persists BCV / typography /
  settings.** It doesn't. The current design keeps per-user UI state
  in the host PWA's `localStorage` (§5). Don't write code that
  depends on the server retaining these writes — the wrapper's
  interceptor short-circuits them client-side. See `DECISIONS.md` D3
  for the trade-offs.

- **P7: Showing GitHub-side terms in the translator UI** — "PR",
  "branch", "fork" — keep these out. The translator only needs
  "save" + "this passage was updated by someone else."

- **P8: Showing the user's GitHub `login` as display name** — prefer
  `name` (real name), fall back to `login`. Login is server-internal
  identity, not display copy.

## 13. References

### In this set

- `impl/AUDIO_STRATEGY.md` — external audio model. The wrapper
  consumes audio references via standard ingredient endpoints; no
  special handling beyond what's in §6.4.
- `impl/BULK_OPS.md` — bulk operations on the server side. Wrapper
  passes through.
- `impl/USER_STATE_FUTURE.md` — **deferred.** Server-side state
  persistence; not part of the current design. See `DECISIONS.md`
  D3 for the localStorage choice.
- `DECISIONS.md` — explains why operational concerns live where
  they do (in `pankosmia_docker` for write/identity; in
  localStorage for UI state; externalized for audio).

### `pankosmia_docker`'s existing docs

- `CLIENT_INTEGRATION.md` — server-side contract.
- `HOSTING.md` — operator setup.
- `SECURITY.md` — auth model.
