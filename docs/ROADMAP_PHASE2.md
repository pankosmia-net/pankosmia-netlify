# Phase 2 Roadmap — Hosted Pankosmia (post-Docker, post-Railway-MVP)

This document captures the architectural direction for the hosted version of this Pankosmia app **after** the initial Docker + Railway MVP (Phase 1) is in place. It is a planning document, not a spec — decisions listed here are the current intent, not commitments.

The goal of writing it down now is to ensure that Phase 1 choices do not paint Phase 2 into a corner, and to give a single place to come back to when the actual Phase 2 work begins.

---

## Context

### Phase 1 (the immediate target — see separate Docker scripts)
- Containerize the existing desktop server as-is.
- Deploy to Railway, single instance, `linux/amd64`.
- Persistent volume mounted at `/data` for the server's `working_dir`.
- No auth, no backups (data-loss risk explicitly accepted).
- One customer per deployment. Single-tenant.

### Phase 2 (this document)
- Move data ownership out of the server's local filesystem.
- Source of truth for repo content: **a real git host (Gitea, or similar)** accessed via API — not internal `git2`/libgit2 working trees.
- Source of truth for users / project metadata / cross-repo state: **Supabase Postgres**.
- Source of truth for large media (audio, video, images): **Supabase Storage** (or equivalent S3-compatible blob store).
- Local disk on the server becomes a **cache + write queue**, not a source of truth.
- Multi-user, with Supabase Auth handling identity and per-user Gitea OAuth tokens stored server-side.

---

## Why this direction

### What it unlocks vs. an "internal git" approach

- **No FUSE / no scratch-disk gymnastics.** The hardest piece of a pure-Supabase-backed git design (libgit2 needs a real working tree) goes away entirely once git is delegated to the host's REST API. The 22 git endpoints in `pankosmia_web`'s `src/endpoints/git2/` become HTTP-to-HTTP adapters.
- **Storage abstraction simplifies.** Gitea itself is the blob store for source files. Supabase Storage handles only derived/large artifacts that don't belong in git.
- **Auth model aligns naturally.** Users authenticate to the service (Supabase Auth); the service holds a per-user Gitea OAuth token. Well-trodden pattern.
- **Multi-tenancy becomes tractable.** Each user's "storage" is "their Gitea account" — no shared `working_dir`, no path collisions on the server.

### What it complicates

- **Latency and rate limits.** Local git is microseconds; a remote git API is 100–300ms per call and rate-limited. Editor flows that today do many small reads/writes per keystroke (USFM autosave, etc.) will overload the API without batching/caching.
- **Offline editing dies** unless a sync layer is built. The Pankosmia desktop currently works offline because git is local. A pure-API server has no offline mode.
- **Host-specific risk.** "Gitea or similar" is a real risk. Gitea, GitHub, GitLab, Codeberg APIs all differ in webhooks, rate-limit headers, content-size caps. Need a thin abstraction over the host so we are not painted into one vendor.
- **Repo-shape vs. burrito-shape.** A "burrito" today is a directory layout. As a Gitea repo, it is one project. Decide: one burrito = one repo, or one burrito = a path inside a monorepo?
- **Media size limits.** Git hosts don't like large binaries. USFM is small, but Pankosmia stores audio and images. This is the strongest argument for keeping media off git entirely.

---

## Findings from inspecting `pankosmia_web` 0.14.12

(Captured here so future readers do not have to re-derive these.)

- **No storage abstraction.** Zero traits over storage. `std::fs` is called in **56 files / 145 sites**; `working_dir`/`repo_dir` referenced in **~150 places across 50 files**. Path strings are passed around bare, not handles.
- **`git2` (libgit2) on real working trees.** All git ops live in `src/endpoints/git2/*.rs` and call `Repository::open(<on-disk path>)` / `Repository::clone(...)` directly.
- **URL shape is the filesystem shape.** Routes like `/clone-repo/<repo_path..>` and `/ingredient/raw/<repo_path..>?<ipath>` use a 3-segment `source/org/repo` path enforced by `src/utils/paths.rs::check_path_components`. ~193 path-shaped params across 41 endpoint files.
- **No database.** State is JSON files (`app_setup.json`, `app_state.json`, `user_settings.json`) plus burrito dirs with `metadata.json` + `ingredients/`.
- **No auth on inbound routes.** The `auth_tokens` map in `structs.rs:65-78` exists only for *outbound* Gitea proxying. Single-tenant single-process by design.
- **Useful head start:** the existing `auth_tokens` / `auth_requests` plumbing is already aimed at Gitea, not GitHub. That code is not throwaway.

The existing URL scheme (`<repo_path..>` = `source/org/repo`) **maps cleanly onto Gitea**: `source` becomes the Gitea host, `org/repo` is the Gitea project. Do not rush to redesign it.

---

## Architecture target

```
┌────────────┐    HTTPS     ┌──────────────────────┐
│  Browser   │ ───────────► │  Pankosmia server    │
│  clients   │              │  (Rust, Rocket)      │
└────────────┘              │                      │
                            │  ┌────────────────┐  │
                            │  │ Cache layer    │  │
                            │  │ + write queue  │  │
                            │  │ (sqlite on     │  │
                            │  │  /data volume) │  │
                            │  └────────────────┘  │
                            │       │      │       │
                            │       │      │       │
                            └───────┼──────┼───────┘
                                    │      │
                       ┌────────────┘      └────────────┐
                       │                                │
                       ▼                                ▼
              ┌───────────────┐               ┌──────────────────┐
              │ Gitea (or     │               │ Supabase         │
              │ similar)      │               │  • Postgres      │
              │  • repos      │               │    (users, proj. │
              │  • files      │               │     metadata)    │
              │  • commits    │               │  • Storage       │
              │  • branches   │               │    (media blobs) │
              └───────────────┘               │  • Auth          │
                                              └──────────────────┘
```

### What lives where

| Concern | Owner |
|---|---|
| User identity, sessions, password reset | Supabase Auth |
| User-to-Gitea OAuth tokens (encrypted) | Supabase Postgres |
| Project list, cross-repo metadata, per-user prefs | Supabase Postgres |
| Burrito source files (USFM, USJ, JSON metadata) | Gitea repo |
| Burrito version history, branches, merges | Gitea (via API) |
| Audio, video, large images | Supabase Storage |
| Hot read cache, pending writes, derived state | Server volume (sqlite + files) |

---

## The cache layer

This is the single most consequential Phase 2 component. Notes for whoever builds it:

- **Cache shape.** Write-through (writes hit cache + Gitea synchronously) vs. write-behind (writes hit cache instantly, flush to Gitea async). Write-behind gives the latency win and protects against rate limits, but introduces "what if the flush fails." Most editor-style apps land on **write-behind with a durable queue** (small sqlite table on the volume).
- **Cache lives on the Railway/Fly volume.** That is what `/data` becomes in Phase 2 — not "transient cache for current pankosmia_web" but "durable cache + write queue for Gitea." Same volume, different role. Phase 1 Docker layout does not have to change to support this.
- **Conflict resolution.** Two users edit the same file in different tabs / different devices → cache and Gitea disagree. Strategies, in order of complexity: last-write-wins (simple, lossy), per-field merge (complex), surface conflicts to the user (honest, more UI work). Decide before building.
- **Cache eviction & multi-user.** Per-user cache directories under `/data/<user-id>/...` give isolation but disk grows unboundedly. Need an LRU eviction policy or a max-size-per-user cap.
- **Cache invalidation from the Gitea side.** Users may edit through the Gitea web UI directly, or another tool may push to the repo. Webhooks from Gitea → service → invalidate cache is the clean answer. Polling on read is the lazy fallback. Webhooks scale better but require a public ingress endpoint and webhook-secret management.
- **Cold start.** First read of a project not in cache pulls from Gitea — the slow path. Pre-warming on session start (fetch project tree once, lazy-fetch file contents) is a typical pattern.

---

## Media handling

- **Reference shape.** Burrito `metadata.json` references media by **stable URL or opaque ID**, not local path. This is a burrito-spec change. Clients (`core-client-workspace`, `core-contenthandler_obs` for OBS audio/images, audio "viewer") must learn to resolve those references.
- **Upload flow.** Standard pattern: server issues a signed PUT URL, browser uploads directly to Supabase, then notifies the server which records the reference in burrito metadata (which then flushes to Gitea via the cache). Avoid making the server a proxy for GBs of audio.
- **Privacy model.** Burritos are private by default (drafts, in-progress work). Media must also be private — served via signed GET URLs that expire. Clients should not hardcode media URLs in the DOM; they need a `getMediaUrl(id)` helper that handles refresh.
- **Server-side proxy layer for media.** A `/media/<id>` endpoint that returns a signed URL (or proxies the bytes) keeps clients ignorant of which backend stores media. Worth doing for that reason alone — it lets the storage backend change later without touching every client.
- **Garbage collection.** Deleting a media reference from a burrito orphans the Supabase blob. Either reference-count on commit (complex; walks all repos) or run a periodic sweep (simple; nightly cron). Storage bills compound — do not skip this.
- **Format conversion.** Use the existing `ffmpeg` invocation pattern (already present for video) to normalize audio on upload (e.g. always opus or m4a). Consistent formats simplify browser playback.

---

## Open design decisions

These should be settled before Phase 2 implementation begins. None block Phase 1.

1. **One repo per burrito, or burritos as folders in a user's monorepo?** One-repo-per-burrito is cleaner but explodes a user's Gitea repo list. Folders-in-monorepo keeps things tidy but complicates per-burrito permissions and webhook routing.
2. **Cross-host (`Gitea | GitHub | GitLab | Codeberg`) or Gitea-only?** Determines whether to build a `GitHost` trait or commit to a single client.
3. **Offline editing: drop, or build a sync layer?** Significant architectural fork. If kept, the cache layer also needs to work in the desktop client, not just on the server.
4. **Conflict resolution policy** (see cache layer above): last-write-wins / per-field merge / surface to user.
5. **Webhooks vs. polling** for cache invalidation. Webhooks scale better; polling is simpler to ship.
6. **Cache eviction policy and per-user disk caps.**
7. **Media GC strategy:** reference-count on commit, or periodic sweep.

---

## Guidance for the Rust server rewrite

Not to be implemented now — captured here so it is available when the rewrite begins.

- **Land auth and storage abstraction together.** Both touch every endpoint. Doing them in two passes is roughly 2× the work.
- **Introduce a `BurritoStore` trait early.** Two minimum methods that hide the cache / Gitea / media distinction:
  - `read(burrito_id, path) -> Bytes`
  - `write(burrito_id, path, Bytes) -> CommitId`
  Endpoints call the trait, not Gitea directly. Cache + write-queue + media-routing live behind the trait.
- **Introduce a `GitHost` trait** before writing any host-specific code. Implement Gitea first. Even if cross-host portability never ships, the trait is cheap insurance and keeps endpoints testable with a fake.
- **The existing URL scheme is fine.** `<repo_path..>` = `source/org/repo` maps cleanly onto Gitea. Do not redesign it just because the backend changed.
- **Remove the `git2` dependency** once endpoints go through the API. Smaller binary, faster Docker builds, no libgit2 system-library headaches.
- **Reuse `auth_tokens` / `auth_requests` plumbing** (`pankosmia_web/src/structs.rs:65-78`). It is already aimed at Gitea — head start, not throwaway.

---

## Implications for Phase 1 (already reflected in the Docker scripts)

These are the small Phase 1 choices that exist specifically to keep Phase 2 cheap.

1. **`/data` volume is documented as transient cache, not source of truth.** No backup tooling. Data-loss risk explicitly accepted.
2. **Volume is sized modestly** (a few GB). In Phase 2 it shrinks to a cache anyway.
3. **All config flows through env vars**, never flags or files baked into the image. Future env vars (`GITEA_OAUTH_CLIENT_ID`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, etc.) plug in without restructuring the launcher.
4. **Outbound HTTPS is treated as first-class.** Recent `debian:slim` base for current CA bundle. No egress lockdown in any future network policy.
5. **Multi-tenancy is *not* promised in Phase 1.** The path-shaped URL scheme means today's API cannot safely host two users' content under one `working_dir` without rewriting `check_path_components` and every route. One customer per Phase 1 deploy, period.

---

## Out of scope for this document

- The actual Rust refactor steps (left to whoever drives `pankosmia_web` v2).
- Pricing and tier choices on Supabase / Gitea hosting.
- Deployment platform comparison beyond Railway-for-Phase-1 (Fly.io, Render, etc. — re-evaluate when Phase 2 lands).
- Client-side (`core-client-*`) changes for media references and auth — needs its own document closer to implementation time.
