# Per-user state: make the stub endpoints real (DEFERRED)

> **Status: DEFERRED. Not in current scope.**
>
> The current design (one origin, many munchers) shares state across
> munchers via the host PWA's `localStorage`. Per-user state lives
> in the browser and survives across sessions on the same device.
> `pankosmia_docker` doesn't persist this state server-side.
>
> **When to revisit this spec**: if you start running multiple PWAs
> against the same `pankosmia_docker` server on **different origins**
> (so each origin has its own isolated `localStorage` and users
> notice cross-PWA state drift), then server-side persistence
> becomes worth the implementation cost. Same trigger applies if
> multi-device sync becomes a recurring user complaint.
>
> Until then, the stub endpoints documented below are kept for
> wire-compatibility with `pankosmia-web` clients. The wrapper's
> `localStorage` interceptor (see `CLIENT_WRAPPER_GUIDE.md`) routes
> reads and writes locally without server round-trips. See
> `DECISIONS.md` D3 for the current design choice and trade-offs.

---

`pankosmia_docker` currently keeps a set of endpoints mounted for
back-compat with FS-mode `pankosmia-web` clients but treats them as
stubs in GitHub mode (silently drop writes, return defaults on read).
This doc specifies making them real — persisting per-user state in
the server's own storage. **Kept as future reference; not part of
the current implementation plan.**

Audience: maintainer of `pankosmia_docker` (future).

---

## 1. The problem with stubs

Per `CLIENT_INTEGRATION.md §6 P6`, the following endpoints exist for
compat but don't persist anything in GitHub mode:

- `/navigation/bcv/<book>/<chapter>/<verse>` (GET, POST)
- `/settings/languages` (GET, POST)
- `/settings/typography/<spec>` (POST)
- `/settings/typography-feature/<font>/<feature>` (POST)
- `/i18n/used-languages` (GET)
- `/app-state/current-project` (GET, POST)

The recommendation in `CLIENT_INTEGRATION.md` is "keep this in
`localStorage`." That solves the "the app doesn't crash" problem but
introduces a worse one:

- Per-browser-per-device persistence is fragile. Switch browsers,
  switch devices, clear cache, lose state.
- No cross-session continuity for the same user.
- Client code has to handle "I'm signed in but my preferences just
  disappeared because I'm on a different machine."
- The endpoints lie: they accept writes that go nowhere. Honest
  failure (501 / 405) would be better than silent drop.

The right fix: **persist per-user state on the server**, keyed by
`(github_user_id, language_code)`. Same URL surface as today (so
existing clients work). New backing store: a small embedded database
on the server's volume.

## 2. Scope

In scope: persist the 6 endpoint families listed in §1.

Out of scope:
- App-wide state shared across users (the catalog covers this).
- Per-burrito user notes (different feature, future).
- Cross-deployment sync (Phase 3+ topic).

## 3. Storage

### 3.1 Backend choice

- **sqlite** for v1. Embedded, zero ops cost, fast enough for
  thousands of concurrent users, easy backup (the volume snapshot
  captures it).
- **postgres** later if scale demands. Plug-replaceable: only the
  connection string changes. Don't pre-pay for postgres in v1.

The sqlite file lives on the same `/data` volume that holds language
clones. Path: `/data/pankosmia.state.db`.

### 3.2 Schema

One table covers all six endpoint families. Generic key-value with
a `(user, language, scope)` composite key:

```sql
CREATE TABLE user_state (
  github_user_id   INTEGER  NOT NULL,
  language_code    TEXT     NOT NULL,    -- '' (empty) for global (cross-language)
  scope            TEXT     NOT NULL,    -- 'navigation.bcv', 'settings.languages', etc.
  value            TEXT     NOT NULL,    -- JSON-serialized value
  updated_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (github_user_id, language_code, scope)
);

CREATE INDEX idx_user_state_user ON user_state(github_user_id);
```

### 3.3 Scope conventions

The `scope` column distinguishes the various state families. Reserved
scopes:

| Scope | Endpoint(s) | Value shape | Per-language? |
|---|---|---|---|
| `navigation.bcv` | `/navigation/bcv/...` | `{book: "GEN", chapter: 1, verse: 1}` | Yes |
| `settings.languages` | `/settings/languages` | `["en", "es"]` | No (global) |
| `settings.typography` | `/settings/typography/<spec>` | `{font_set, font_size, direction}` | No (global) |
| `settings.typography_feature` | `/settings/typography-feature/...` | `{<font>: {<feature>: bool}}` | No (global) |
| `i18n.used_languages` | `/i18n/used-languages` (GET) | `["en", "es", "fr"]` (read-only — derived from settings.languages + locale fallback) | No |
| `app_state.current_project` | `/app-state/current-project` | `"<source>/<org>/<repo>"` | Yes |

Per-language scopes use the language code as a partitioning dimension
so a user editing `es` and `fr` has independent state per language.
Global scopes use `language_code = ''`.

### 3.4 Why one table

Tempting alternative: one table per scope (`bcv_state`, `language_state`,
etc.). Rejected because:

- Schema changes when new scopes appear (every new endpoint family
  needs a migration).
- N tables × M users isn't more efficient than 1 table indexed.
- JSON-in-text isn't ideal but the values are small (<1 KB each),
  query patterns are key lookups, not value filters.

## 4. Endpoint behaviour

For each of the six endpoint families, the new behaviour:

### 4.1 `GET /navigation/bcv` (and variants)

- Resolve user from session cookie. If unauthenticated → 401.
- Resolve language from `X-Language-Code` header (or fallback to
  empty for global).
- Query `user_state WHERE github_user_id=? AND language_code=? AND scope='navigation.bcv'`.
- If row exists: return JSON value with 200.
- If no row: return default `{book: "GEN", chapter: 1, verse: 1}`
  with 200 (matches today's stub behaviour for back-compat).

### 4.2 `POST /navigation/bcv/<book>/<chapter>/<verse>`

- Auth + language same as GET.
- Validate book/chapter/verse path params (book is 3-letter code,
  others are positive integers).
- `INSERT OR REPLACE` into user_state with the new value.
- Return `{is_good: true, reason: "ok"}` (matches today's stub
  response).

### 4.3 `GET /settings/languages`

- Auth required.
- Scope: `settings.languages`, language_code: `''` (global).
- Default value: `["en"]`.

### 4.4 `POST /settings/languages/<lang>`

- Auth + validate `<lang>` is BCP47-shaped.
- Read current array, append if not present.
- Write back.
- Return same envelope as 4.2.

(Note: today's stub endpoint accepts a single language; behaviour is
"add to the list, don't replace." Preserve this — it's what clients
expect.)

### 4.5 `POST /settings/typography/<spec>`

- Auth required.
- `<spec>` is a serialized typography descriptor — `<font_set>--<size>--<direction>`.
- Parse into structured form, write.

### 4.6 `POST /settings/typography-feature/<font>/<feature>`

- Auth required.
- Read current value (object keyed by font, each entry a feature
  map), set/clear the feature flag, write.

### 4.7 `GET /i18n/used-languages`

- Derived endpoint. No write.
- Compute from `settings.languages` + the server's known i18n
  language list (intersect — return only languages the server has
  translations for).
- Return array.

### 4.8 `GET /app-state/current-project`

- Auth + language.
- Scope: `app_state.current_project`.
- Default value: `null`.

### 4.9 `POST /app-state/current-project/<repo>`

- Auth + language + validate `<repo>` shape (`<source>/<org>/<repo>`).
- Optional: verify the repo is in the catalog for that language. If
  not: 400 with `reason: "<repo> not in catalog for language <code>"`.
  Skip this check if it adds latency users will notice.
- Write.

## 5. Behavioural contract preservation

Two things to preserve carefully so existing clients don't break:

### 5.1 Response shapes

Today's stub responses use `{is_good: true, reason: "ok"}` and
default values that match the old FS-mode behavior. Keep those
shapes exactly. Adding fields is OK; changing types or removing
fields breaks consumers.

### 5.2 Unauthenticated requests

Today's stubs accept requests without authentication and silently
respond with defaults / accept writes (per the stub semantics).

The real implementation should respond `401` for unauthenticated
requests. **This is a behaviour change.** Document it in
`CLIENT_INTEGRATION.md`.

For clients that aren't ready to handle 401 from these endpoints,
two transition options:

- **Soft mode**: a config flag `PANKOSMIA_USER_STATE_REQUIRE_AUTH=false`
  that returns defaults instead of 401 for unauthenticated requests.
  Default off (real behavior). Lets operators ease the transition.
- **Hard cutover**: just return 401. Clients update; the upgrade is
  a small lift.

Recommend **soft mode for the first release**, then flip to hard
cutover in the next release once consumers have migrated.

## 6. Concurrency

Multiple sessions from the same user (browser tab + mobile) may write
concurrently. The `INSERT OR REPLACE` is atomic per row; last-write-wins
at the row level. This is fine for these endpoint families — none of
them have semantics that need cross-row coordination.

If a future scope needs read-modify-write (e.g., "add this language
to my list" — which we do today by reading the current list, appending,
writing back), add a small transactional helper. Sqlite handles this
trivially with `BEGIN IMMEDIATE; ... COMMIT;`.

## 7. Migration from stubs

Today's stubs return hardcoded defaults. After this lands:

- Existing users have no state in the DB → they see defaults on first
  read. Identical user-visible behavior.
- First write creates the row. From then on, real persistence.
- No migration data needed.

In other words, this is a **transparent** upgrade for existing users
(no localStorage migration script, no version-specific behavior).

If a deployment wants to import localStorage state from existing
PWAs, that's a client-side concern: the PWA can read its own
localStorage on next sign-in and POST the values to the server. Each
PWA handles its own migration.

## 8. Implementation outline

```
src/storage/
├── user_state.rs           — schema migration, query helpers
├── mod.rs                   — re-exports
└── tests.rs                 — unit tests for query helpers

src/endpoints/
├── settings.rs              — refactor existing stubs to call user_state
├── navigation.rs            — same
├── app_state.rs             — same
└── i18n.rs                  — same (read-only derived endpoint)
```

Sqlite via the `rusqlite` crate or `sqlx` (compile-time-checked).
`sqlx` is heavier but its compile-time query checking is worth it for
the data access layer. Or `rusqlite` for simpler, smaller binary.
Maintainer's choice.

### 8.1 Schema migration

On startup, server runs:

```sql
CREATE TABLE IF NOT EXISTS user_state (...);
CREATE INDEX IF NOT EXISTS idx_user_state_user (...);
```

Idempotent. No migration framework needed for v1. Add `sqlx-migrate`
or `refinery` if the schema grows.

### 8.2 Query patterns

Three primitives cover all endpoints:

```rust
fn get_state(user_id: i64, language: &str, scope: &str) -> Option<serde_json::Value>;
fn put_state(user_id: i64, language: &str, scope: &str, value: serde_json::Value) -> Result<()>;
fn delete_state(user_id: i64, language: &str, scope: &str) -> Result<()>;
```

The append-list pattern (§4.4) is:

```rust
let mut langs: Vec<String> = get_state(user, "", "settings.languages")
    .and_then(|v| serde_json::from_value(v).ok())
    .unwrap_or_else(|| vec!["en".to_string()]);
if !langs.contains(&new_lang) {
    langs.push(new_lang);
    put_state(user, "", "settings.languages", json!(langs))?;
}
```

## 9. Effort

| Component | Days |
|---|---|
| sqlite setup + schema + helpers | 0.5 |
| Refactor 6 endpoint families to use the helpers | 1.5 |
| Soft-mode auth flag (§5.2) | 0.25 |
| Tests (per endpoint + concurrency + auth) | 1 |
| Updates to `CLIENT_INTEGRATION.md` (remove "stub" framing; document real behaviour) | 0.5 |
| **Total** | **~3.5 days** |

Small. The mechanical work is straightforward — most of the time is in
testing and doc updates.

## 10. Open design decisions

### 10.1 Per-language `settings.languages`?

Today's `settings.languages` is global ("which languages do I have
selected for my workspace"). Per-language doesn't make sense for this
scope. Keep global.

But: per-language `settings.typography` (different fonts for different
working languages) might make sense. Current model is global. Either:

- Keep global, accept the limitation.
- Make typography per-language. Requires UI for it.

**Recommend keep global for v1.** Add per-language later if anyone
asks. The schema (§3.2) supports both via the `language_code`
column already.

### 10.2 Pruning old rows

A user who never returns leaves stale rows forever. Disk impact is
negligible (a few KB per user), so don't bother for v1. Add a
"prune state older than N years" admin command in v2 if disk
pressure becomes real.

### 10.3 Audit / history

Today's writes destroy the previous value. Should we keep an
append-only history?

**Recommend no.** The state is per-user, low-stakes (font
preferences, BCV cursor). Audit overhead isn't justified.

If audit becomes useful later, sqlite triggers can capture it
without changing endpoint behaviour.

### 10.4 Sharing state across deployments

If a user signs into two different `pankosmia_docker` deployments
(unlikely but possible), each holds independent state. No
synchronization. Acceptable.

## 11. What this replaces in the prior planning

- `temp/CLIENT_INTEGRATION.md §6 P6` ("Persisting BCV / typography
  in pankosmia-docker storage") — once this lands, that pitfall
  warning becomes stale. The advice "keep state in localStorage"
  shifts to "server state is canonical; localStorage is a fallback
  for offline."
- `temp/OBS_WRAPPER_SPEC.md §3.3` ("Stub-endpoint shimming") — the
  wrapper's localStorage adapter becomes unnecessary in the normal
  path. Keep as offline fallback (see updated `OBS_WRAPPER_SPEC.md`).
- `temp/MIDDLEWARE_PLAN.md §3.3` — the middleware's per-user state
  store is supplanted by the server's own. Middleware no longer
  needs to handle this.

## 12. References

### In this set

- `BULK_OPS_SPEC.md` — implementation of bulk Git operations.
  Independent.
- `AUDIO_STRATEGY.md` — external audio storage. Independent.
- `CLIENT_WRAPPER_GUIDE.md` — describes how clients consume these
  endpoints.
- `ARCHITECTURE_DECISIONS.md` — records why we chose server-side
  state over middleware.

### Crates that may be relevant

- `rusqlite`: https://docs.rs/rusqlite/ — simpler sqlite binding.
- `sqlx`: https://docs.rs/sqlx/ — async, compile-time query check.
- `serde_json`: already in the project.
