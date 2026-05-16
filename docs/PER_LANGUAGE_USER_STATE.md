# Per-language user state

Tracking document for making user state per-(user, language) where
it makes sense, and how the SQLite persistence layer supports this.

---

## 1. Current state (2026-05-15)

### SQLite persistence

`SqliteUserState` (`src/store/sqlite_user_state.rs`) is active when
`PANKOSMIA_SQLITE_PATH` is set. Two tables:

```sql
-- global per-user state
user_state (user_id TEXT, key TEXT, value TEXT, PRIMARY KEY (user_id, key))

-- per-(user, language) state
user_language_state (user_id TEXT, lang TEXT, key TEXT, value TEXT, PRIMARY KEY (user_id, lang, key))
```

### What is already per-(user, language)

| Data | Table | Key | Status |
|---|---|---|---|
| BCV cursor | `user_language_state` | `(user, lang, "bcv")` | Done — `get_bcv`/`put_bcv` already receive `lang` on the trait |
| App state | `user_state` | `(nil-user, "app_state:<lang>")` | Done — `get_app_state`/`put_app_state` receive `lang` |

### What is global but should become per-(user, language)

| Data | Table now | Key now | Why per-language |
|---|---|---|---|
| Typography | `user_language_state` | `(user, "x-global", "typography")` | RTL vs LTR languages need different direction/font |
| Current project | not persisted yet | — | Different resource (obs, bible) per language |

### What stays global per-user

| Data | Table | Key | Why global |
|---|---|---|---|
| Selected languages | `user_state` | `(user, "languages")` | The list of languages the user works with is inherently cross-language |
| i18n preference | not persisted yet | — | UI language is a user preference |
| Auth tokens | `user_state` | `(user, "auth_token:<key>")` | Identity, not language-specific |

---

## 2. The `x-global` workaround

The `ProjectStore` trait methods for typography do not currently
receive a language parameter:

```rust
async fn get_typography(&self, user: UserId) -> StoreResult<Typography>;
async fn put_typography(&self, user: UserId, t: Typography) -> StoreResult<()>;
```

The SQLite layer stores typography per-(user, language), but since
the trait only passes `user`, the `GitHubLanguageStore` uses
`x-global` as a placeholder language key. This is a BCP 47
private-use tag (`x-` prefix) — no real language will collide.

Once the trait and endpoints are updated (§3), the `x-global`
fallback is removed and each language gets its own typography
naturally. No SQLite schema migration needed.

---

## 3. Implementation plan for per-language typography

### 3.1 Update the `ProjectStore` trait

In `src/store/project_store.rs`, add `lang` to the typography
methods:

```rust
// before
async fn get_typography(&self, user: UserId) -> StoreResult<Typography>;
async fn put_typography(&self, user: UserId, t: Typography) -> StoreResult<()>;

// after
async fn get_typography(&self, user: UserId, lang: LanguageCode) -> StoreResult<Typography>;
async fn put_typography(&self, user: UserId, lang: LanguageCode, t: Typography) -> StoreResult<()>;
```

### 3.2 Update FsLanguageStore

In `src/store/fs/store.rs`. Two options:

- **Ignore the new parameter** — single-tenant FS mode has one user,
  one global typography. Keep reading/writing the same file path.
  Simplest, fully backwards compatible.
- **Store per-language** — write to
  `.pankosmia/languages/<lang>/typography/<user>.json`. Only worth
  doing if FS-mode users want per-language typography.

Recommendation: ignore the parameter in FS mode.

### 3.3 Update GitHubLanguageStore

In `src/store/github/store.rs`, replace:

```rust
let global_lang = LanguageCode::parse("x-global").unwrap();
```

with the `lang` parameter passed by the trait. Remove the
`x-global` workaround entirely.

### 3.4 Update the endpoint handlers

**GET typography** — `src/endpoints/settings2/get_typography.rs`:

The handler needs to read `X-Language-Code` from the request and
pass it to `store.get_typography(user, lang)`. In FS mode (no
header), fall back to a default language code.

**POST typography** — `src/endpoints/settings2/post_typography.rs`:

Same: read `X-Language-Code`, pass to `store.put_typography(user,
lang, t)`.

**POST typography-feature** —
`src/endpoints/settings2/post_typography_feature.rs`:

This endpoint mutates a single feature within the typography
struct. It needs to: read current typography for the language,
update the feature, write it back.

### 3.5 Migration of existing `x-global` data

When the trait change lands, optionally migrate stored `x-global`
rows to the user's first selected language. Or leave them — the
`x-global` rows simply become unreachable (harmless), and users
get fresh defaults for each language on first visit.

---

## 4. Implementation plan for per-language current-project

Similar pattern. The `ProjectStore` trait does not currently have
a `get_current_project` / `put_current_project` method — the
current project is stored in `AppState` which is per-language.

If a dedicated method is needed:

```rust
async fn get_current_project(&self, user: UserId, lang: LanguageCode) -> StoreResult<Option<ProjectIdentifier>>;
async fn put_current_project(&self, user: UserId, lang: LanguageCode, p: ProjectIdentifier) -> StoreResult<()>;
```

Store in `user_language_state` under key `"current_project"`.
The endpoint `POST /app-state/current-project/<source>/<org>/<project>`
would read `X-Language-Code` and persist per-(user, language).

---

## 5. Files involved

| File | Role |
|---|---|
| `src/store/project_store.rs` | Trait definition — add `lang` param |
| `src/store/types.rs` | Type definitions (no change needed) |
| `src/store/fs/store.rs` | FS impl — ignore new param |
| `src/store/github/store.rs` | GitHub impl — pass `lang` to SQLite, remove `x-global` |
| `src/store/sqlite_user_state.rs` | SQLite layer — already supports per-language, no change |
| `src/endpoints/settings2/get_typography.rs` | Read `X-Language-Code`, pass to store |
| `src/endpoints/settings2/post_typography.rs` | Same |
| `src/endpoints/settings2/post_typography_feature.rs` | Same |
| `src/endpoints/app_state.rs` | Current-project endpoint (if adding dedicated method) |
