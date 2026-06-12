# Standalone OBS Editor — Project Specification

This document contains everything needed to start a new project:
a standalone Open Bible Stories (OBS) editor that combines text editing,
audio recording, document management, and creation into a single client app.

---

## 1. Goal

Create `core-client-obs-editor` — a focused single-page app for editing
OBS stories (text + audio) that replaces the need to navigate between
four separate clients (dashboard, content, workspace, OBS handler).

The app should:
- List available OBS documents (filtered to `textStories` flavor)
- Create new OBS documents
- Edit OBS story text (markdown-based, chapter/paragraph navigation)
- Record and manage audio per paragraph (multi-track)
- Export documents
- Work within the existing pankosmia Netlify + Railway deployment

---

## 2. Current Architecture

### 2.1 Deployment Model

The pankosmia platform is split across two hosts:

- **Netlify** (`pankosmia.netlify.app`) — serves static client builds + proxies API calls
- **Railway** (`pankosmia-web.up.railway.app`) — runs the Rust backend (pankosmia-docker)

Static files live in `netlify_dist/` on Netlify. API calls are proxied
via `netlify.toml` redirect rules.

### 2.2 Endpoints Handled by Netlify (not Railway)

These are served locally from Netlify, not proxied:

| Path | Method |
|---|---|
| `/client-interfaces` | Static JSON (`netlify_dist/api/client-interfaces.json`) |
| `/list-clients` | Static JSON (`netlify_dist/api/list-clients.json`) |
| `/notifications` | Edge function (SSE stream proxy to Railway) |
| `/app-resources/*` | Static files from `resource-core` repo |
| `/webfonts/*` | Static files from `webfonts-core` repo |
| `/templates/*` | Static files from `resource-core/templates` |
| `/clients/*` | Static client builds |

### 2.3 Endpoints Proxied to Railway

All other API paths proxy to Railway via `netlify.toml`, including:

| Path | Purpose |
|---|---|
| `/burrito/metadata/summaries` | List all available projects |
| `/burrito/metadata/summary/<path>` | Single project metadata |
| `/burrito/metadata/raw/<path>` | Raw metadata.json |
| `/burrito/ingredient/raw/<path>?ipath=<ipath>` | Read text ingredient |
| `/burrito/ingredient/bytes/<path>?ipath=<ipath>` | Read binary ingredient |
| `POST /burrito/ingredient/raw/<path>?ipath=<ipath>` | Write text ingredient |
| `POST /burrito/ingredient/bytes/<path>?ipath=<ipath>` | Write binary ingredient |
| `/git/new-obs-resource` | Create new OBS document |
| `/git/clone-repo/*` | Clone remote repo |
| `/git/list-local-repos` | List repos on server |
| `/auth/*` | GitHub OAuth flow |
| `/me` | Current user identity |
| `/i18n/flat` | Internationalization strings |
| `/settings/*` | User settings (typography, languages) |
| `/navigation/bcv/<book>/<ch>/<v>` | Set current position |
| `/app-state/current-project/<path>` | Set active project |
| `/user-resources/*` | User resource management |
| `/content-utils/versifications` | Versification data |

### 2.4 Read/Write Boundary

This is a critical architectural boundary:

**READ (catalog/browsing):**
- All `GET /burrito/*` endpoints
- Unauthenticated
- Currently reads from Railway server filesystem
- Future plan: proxy to gitea raw API for door43.org repos (no pre-cloning)

**WRITE (editing):**
- All `POST /burrito/ingredient/*` endpoints
- Require authenticated session (GitHub OAuth cookie)
- Writes go through GitHub App flow, NOT to Railway filesystem:
  - Session cookie → GitHub user identity
  - GitHub App installation token
  - Per-user branch: `pankosmia-edit-<login>`
  - GitHub Contents API PUT
  - Auto-creates PR
- Multi-user isolation via per-user branches

### 2.5 Curated Content Sources

Three gitea orgs on `git.door43.org` provide curated content:

| Org | Label |
|---|---|
| `git.door43.org/BurritoTruck` | Xenizo |
| `git.door43.org/uW` | UnfoldingWord |
| `git.door43.org/shower` | Aquifer |

The gitea API at `https://git.door43.org/api/v1/orgs/{org}/repos`
returns rich metadata per repo (flavor, language, ingredients, etc.).
Individual ingredient files are accessible via
`https://git.door43.org/{org}/{repo}/raw/branch/master/{path}`.

---

## 3. Existing Code to Reuse

### 3.1 OBS Editor Components (from core-client-workspace)

**Source:** `core-client-workspace/src/munchers/OBS/`

| File | Lines | Purpose |
|---|---|---|
| `OBSEditorMuncher.jsx` | ~345 | Core text editor — loads markdown per chapter/paragraph, tracks dirty state via MD5 checksum, saves via `/burrito/ingredient/raw/` |
| `OBSViewerMuncher.jsx` | ~73 | Read-only viewer for reference OBS content |
| `OBSNavigator.jsx` | ~108 | Chapter/paragraph navigation buttons |
| `SaveOBSButton.jsx` | ~17 | Save button wrapper |
| `AudioRecorder.jsx` | ~1830 | Multi-track audio recorder with waveform visualization, region editing, copy/paste, track management. Stores WAV files at `audio_content/{ch}-{para}/{ch}-{para}_{track}.wav` |
| `Waveform.jsx` | (varies) | Waveform display component |

**Context provider:** `OBSContext` — shares `[chapter, paragraph]` state across all OBS components.

**Shared component:** `MarkdownField` (from workspace's shared components) — text editing field used by OBSEditorMuncher.

**Dependencies:** wavesurfer.js (audio waveforms), react-markdown, @mui/material, pankosmia-rcl, pithekos-lib.

### 3.2 Document Listing (from core-client-content)

**Source:** `core-client-content/src/components/DataGridComponent.jsx` (~408 lines)

Lists all projects from `/burrito/metadata/summaries`. Shows columns:
abbreviation, name, language, source, type, nBooks, dateUpdated, actions.

For the OBS editor: filter to `flavor === "textStories"` only.

Also relevant from core-client-content:
- `ContentRowButtonPlusMenu.jsx` — per-row action menu (edit, delete, export, archive, etc.)
- `Notification.jsx` — download/update status indicators
- `ImportBurrito.jsx` — ZIP import dialog

### 3.3 OBS Document Creation (from core-contenthandler_obs)

**Source:** `core-contenthandler_obs/src/pages/NewOBSContent.jsx` (~150 lines)

Simple form: name, abbreviation, language code → `POST /git/new-obs-resource`.
Returns success/error. Very self-contained.

### 3.4 Auth Context (from core-client-dashboard)

**Source:** `core-client-dashboard/src/context/AuthContext.jsx`

Handles `/me` endpoint to determine auth state. Important behavior:
- 200 with user data → authenticated, sets `isOnline=true`
- 401 → server is online but not authenticated, sets `isOnline=true`
  (this fix was added for the Netlify deployment — the backend returns
  401 instead of 404 when no session exists)
- Network error → `isOnline=false`

Also triggers `POST /net/enable` when online and adds `hosted-online`
CSS class to body.

**AuthWidget** — renders Sign In / Sign Out chip based on auth state.
Shows Sign In when `isOnline && !user`.

---

## 4. Proposed Structure

```
core-client-obs-editor/
├── package.json
├── pankosmia_metadata.json
├── public/
│   └── index.html
├── src/
│   ├── App.jsx                    # Router + providers + layout
│   ├── index.jsx                  # Entry point with SpSpa wrapper
│   ├── context/
│   │   ├── AuthContext.jsx         # Adapted from dashboard
│   │   └── OBSContext.jsx          # From workspace (chapter/paragraph state)
│   ├── components/
│   │   ├── ProjectList.jsx         # Adapted DataGridComponent, filtered to textStories
│   │   ├── CreateOBS.jsx           # Adapted NewOBSContent form
│   │   ├── AuthWidget.jsx          # Sign In/Out from dashboard
│   │   └── ProjectActions.jsx      # Per-project action menu (export, delete, etc.)
│   └── editor/
│       ├── OBSEditor.jsx           # From OBSEditorMuncher
│       ├── OBSViewer.jsx           # From OBSViewerMuncher
│       ├── OBSNavigator.jsx        # From workspace
│       ├── SaveButton.jsx          # From SaveOBSButton
│       ├── AudioRecorder.jsx       # From workspace (1830 lines, keep as-is)
│       ├── Waveform.jsx            # From workspace
│       └── MarkdownField.jsx       # From workspace shared components
```

### 4.1 App Layout

Split view:
- **Left panel:** Project list (filtered to OBS) + Create button
- **Main panel:** OBS editor with chapter/paragraph nav + audio recorder
- **Header:** Standard pankosmia-rcl header with auth widget

No tile-pane system needed. Simple CSS grid or flexbox split.

### 4.2 Navigation Flow

1. App loads → fetch `/burrito/metadata/summaries` → filter to `textStories`
2. User sees list of OBS projects (or empty state with Create button)
3. User clicks project → `POST /app-state/current-project/{path}` → load editor
4. Editor loads chapter/paragraph content from `/burrito/ingredient/raw/`
5. User edits text → save via `POST /burrito/ingredient/raw/`
6. User toggles audio mode → AudioRecorder loads/records WAV files
7. User clicks Create → form dialog → `POST /git/new-obs-resource` → refresh list

---

## 5. pankosmia_metadata.json

```json
{
  "id": "core-obs-editor",
  "require": {
    "net": false
  },
  "endpoints": {
    "textStories": {
      "edit": {
        "doc": "OBS text and audio editor",
        "label": "pages:core-obs-editor:main",
        "url": ""
      }
    }
  },
  "exclude_from_menu": false,
  "exclude_from_dashboard": false,
  "i18n": {
    "title": {
      "en": "OBS Editor"
    },
    "summary": {
      "en": "Edit Open Bible Stories text and audio"
    }
  }
}
```

---

## 6. Netlify Integration

### 6.1 Build and Deploy

The new client needs to be added to the pankosmia-netlify build pipeline:

**`app_config.env`** — add:
```
CLIENT10=core-client-obs-editor
```

**`Makefile`** — the `client_dir` function needs a mapping:
```makefile
$(if $(filter core-client-obs-editor,$(1)),obs-editor,\
```

**`scripts/build_for_netlify.sh`** — the `client_dir_name` function:
```bash
core-client-obs-editor) echo "obs-editor" ;;
```

**`package.json`** in the new client:
```json
"homepage": "/clients/obs-editor"
```

**`netlify.toml`** — add SPA fallback:
```toml
[[redirects]]
  from = "/clients/obs-editor/*"
  to = "/clients/obs-editor/index.html"
  status = 200
```

### 6.2 Static API Updates

After adding the client, regenerate static APIs:
```bash
scripts/generate_static_apis.sh
```

This will include the new client in `/client-interfaces` and `/list-clients`.

### 6.3 Proxy Rules

No new proxy rules needed — all API paths used by the OBS editor
are already proxied (`/burrito/*`, `/git/*`, `/auth/*`, `/me`,
`/i18n/*`, `/settings/*`, `/navigation/*`, `/app-state/*`).

---

## 7. API Endpoints Used by the OBS Editor

### On Load
| Endpoint | Purpose |
|---|---|
| `GET /me` | Check auth state |
| `GET /list-clients` | Client registry (static on Netlify) |
| `GET /client-interfaces` | Client capabilities (static on Netlify) |
| `GET /i18n/flat` | UI translations |
| `GET /settings/typography` | Font settings |
| `GET /burrito/metadata/summaries` | Project list |
| `GET /notifications` | SSE change notifications |

### When Opening a Project
| Endpoint | Purpose |
|---|---|
| `POST /app-state/current-project/<path>` | Set active project |
| `GET /burrito/metadata/raw/<path>` | Full metadata (ingredients list) |
| `GET /burrito/ingredient/raw/<path>?ipath=content/<ch>.md` | Load chapter text |
| `GET /burrito/ingredient/bytes/<path>?ipath=audio_content/...` | Load audio |

### When Editing
| Endpoint | Purpose |
|---|---|
| `POST /burrito/ingredient/raw/<path>?ipath=content/<ch>.md` | Save text |
| `POST /burrito/ingredient/bytes/<path>?ipath=audio_content/...` | Save audio |

### When Creating a New Document
| Endpoint | Purpose |
|---|---|
| `POST /git/new-obs-resource` | Create OBS document |

### When Exporting
| Endpoint | Purpose |
|---|---|
| `GET /burrito/zipped/<path>` | Export as ZIP |

---

## 8. Known Issues and Gotchas

### 8.1 Auth Flow on Netlify

The backend returns 401 (not 404) when no session exists. AuthContext
must treat 401 as "online but not authenticated" and set `isOnline=true`.
Without this, the Sign In button is hidden.

### 8.2 OBS Document Creation

`POST /git/new-obs-resource` currently returns 500 on Railway. This
needs to be investigated on the backend side — may be a missing
workspace directory or permission issue.

### 8.3 Audio File Structure

Audio is stored as WAV files in the burrito at:
```
audio_content/{chapter}-{paragraph}/{chapter}-{paragraph}_{track}.wav
```

The AudioRecorder manages main track + supplementary tracks per
paragraph. Track metadata (names, order) is stored alongside the WAV files.

### 8.4 Session Cookie

Writes require the `pankosmia_session` cookie set by the GitHub OAuth
flow. The cookie has no explicit `Domain=` so it scopes to the Netlify
origin. `SameSite=Lax`, `Secure=true`. All API calls from the browser
include it automatically via same-origin fetch.

### 8.5 `.netlifyignore`

The pankosmia-netlify repo has a `.netlifyignore` that ensures
`netlify_dist/` is uploaded during deploy (it's in `.gitignore` to
keep `git add .` safe, but `.netlifyignore` overrides for the CLI).

---

## 9. GitHub Authentication and Write Authorization

### 9.1 Overview

Only signed-in GitHub users can edit OBS stories. The auth flow is
cookie-based — the client never handles tokens directly. All write
requests include the session cookie automatically (same-origin fetch),
and the Rust backend uses it to route writes to the correct GitHub repo
via per-user branches.

### 9.2 Auth Flow

1. **User clicks "Sign in"** → browser navigates to:
   ```
   /auth/start?redirect=/clients/obs-editor
   ```
   This is proxied to Railway, which redirects to GitHub's OAuth
   authorization page.

2. **User authorizes on GitHub** → GitHub redirects back to the backend
   callback URL. The backend:
   - Receives the OAuth code
   - Exchanges it for a GitHub access token
   - Creates a server-side session
   - Sets a `pankosmia_session` cookie (`SameSite=Lax`, `Secure=true`,
     no explicit `Domain=` so it scopes to the Netlify origin)
   - Redirects the user back to the `redirect` URL

3. **Session check on page load** → `GET /me` (proxied to Railway):
   - **200 + JSON with `github_user_id`** → user is authenticated
   - **401** → server is online, no valid session (show Sign In button)
   - **Network error** → server unreachable (hide Sign In entirely)

4. **Sign out** → `POST /auth/logout` → clears session on server

### 9.3 Reference Implementation (from core-client-dashboard)

**AuthContext.jsx** — provides auth state to the entire app:

```jsx
import { createContext, useState, useEffect, useCallback } from "react";

const AuthContext = createContext({
  user: null,
  loading: true,
  isOnline: false,
  signIn: () => {},
  signOut: () => {},
});

function AuthProvider({ children }) {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  const [isOnline, setIsOnline] = useState(false);

  useEffect(() => {
    fetch("/me")
      .then(async (r) => {
        if (r.ok) {
          const data = await r.json();
          if (data && data.github_user_id) {
            setIsOnline(true);
            setUser(data);
            return;
          }
        }
        if (r.status === 401) {
          setIsOnline(true);  // online but not authenticated
          return;
        }
      })
      .catch(() => {
        // network error — leave isOnline false
      })
      .finally(() => setLoading(false));
  }, []);

  useEffect(() => {
    if (isOnline) {
      fetch("/net/enable", { method: "POST" }).catch(() => {});
      document.body.classList.add("hosted-online");
    }
  }, [isOnline]);

  const signIn = useCallback(() => {
    window.location.href = `/auth/start?redirect=${encodeURIComponent(location.pathname)}`;
  }, []);

  const signOut = useCallback(() => {
    fetch("/auth/logout", { method: "POST" }).then(() => setUser(null));
  }, []);

  return (
    <AuthContext.Provider value={{ user, loading, isOnline, signIn, signOut }}>
      {children}
    </AuthContext.Provider>
  );
}
```

**AuthWidget.jsx** — renders Sign In / Sign Out UI:

```jsx
import { useContext } from "react";
import { Avatar, Chip, Stack, Tooltip } from "@mui/material";
import LogoutIcon from "@mui/icons-material/Logout";

function AuthWidget() {
  const { user, loading, isOnline, signIn, signOut } = useContext(AuthContext);

  if (!isOnline || loading) return null;

  if (!user) {
    return <Chip label="Sign in" variant="outlined" onClick={signIn} />;
  }

  return (
    <Stack direction="row" spacing={1} alignItems="center">
      <Chip
        avatar={<Avatar src={user.avatar_url} alt={user.name || user.login} />}
        label={user.name || user.login}
        variant="outlined"
      />
      <Chip icon={<LogoutIcon />} label="Sign out" size="small"
            variant="outlined" onClick={signOut} />
    </Stack>
  );
}
```

### 9.4 User Object

The `/me` endpoint returns (when authenticated):

| Field | Example |
|---|---|
| `github_user_id` | `12345678` |
| `login` | `"larsgson"` |
| `name` | `"Lars Gson"` |
| `avatar_url` | `"https://avatars.githubusercontent.com/u/12345678"` |

### 9.5 How Writes Use the Session

When the editor saves text or audio, the flow is:

1. Client calls `POST /burrito/ingredient/raw/<path>?ipath=content/01.md`
   (or `POST /burrito/ingredient/bytes/...` for audio)
2. The `pankosmia_session` cookie is included automatically (same-origin)
3. Railway backend reads the session → identifies the GitHub user
4. Backend obtains a **GitHub App installation token** for the target repo
5. Backend writes to a per-user branch: `pankosmia-edit-<login>`
6. Backend auto-creates a **Pull Request** from that branch
7. Subsequent saves to the same project update the same branch/PR

This means:
- **No auth token management** in client code — it's all cookie-based
- **Multi-user isolation** — each user writes to their own branch
- **No direct filesystem writes** — everything goes through the GitHub API
- **The editor must gate write operations on `user !== null`** — show
  read-only mode or a "Sign in to edit" prompt for unauthenticated users

### 9.6 Proxy Rules (already configured)

These auth-related proxy rules exist in `netlify.toml` and require no changes:

```toml
# GitHub OAuth flow
[[redirects]]
  from = "/auth/*"
  to = "https://pankosmia-web.up.railway.app/auth/:splat"
  status = 200

# Current user identity
[[redirects]]
  from = "/me"
  to = "https://pankosmia-web.up.railway.app/me"
  status = 200
```

---

## 11. Local Repo Paths

These repos contain the source code referenced in this document.
Set up symlinks or provide paths to the Claude session:

| Repo | Purpose |
|---|---|
| `pankosmia-netlify/` | Netlify deployment config, build scripts, proxy rules |
| `core-client-workspace/` | OBS editor/viewer munchers, audio recorder |
| `core-client-content/` | Document listing DataGridComponent |
| `core-contenthandler_obs/` | OBS creation form |
| `core-client-dashboard/` | Auth context, auth widget |
| `pankosmia-rcl/` | Shared React component library (contexts, dialogs, tables) |
| `pithekos-lib/` | API helper library (getText, postText, getJson, doI18n) |
| `resource-core/` | Static assets (lookups, themes, pages) |
| `pankosmia-docker/` | Rust backend (for understanding API contracts) |

---

## 12. Effort Estimate

| Task | Estimate |
|---|---|
| Project setup (package.json, vite config, entry point) | 2 hours |
| Auth context + widget | 1 hour |
| Project list (adapt DataGridComponent) | 3 hours |
| OBS creation form (adapt NewOBSContent) | 1 hour |
| OBS editor integration (munchers + context) | 4 hours |
| Audio recorder integration | 2 hours |
| App layout (split view, routing) | 3 hours |
| Netlify build integration | 1 hour |
| Testing and polish | 4 hours |
| **Total** | **~3 days** |
