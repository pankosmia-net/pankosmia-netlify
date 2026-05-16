# Scaling

Capacity planning and the architecture choices that make a single
Rust binary serve thousands of users across hundreds of language
repos.

For the architecture overview, see `docs/ARCHITECTURE.md`. For
operator-side configuration, see `docs/HOSTING.md`.

---

## 1. Target

- ~5,000 registered users; ~250–750 simultaneously active.
- Hundreds of registered languages, growing toward 1,000+.
- Per-user-per-language access rights, typically one language per
  user (sometimes a few).
- Text editing (small JSON / USFM / markdown ingredients) and
  audio recording / playback.
- SSE-based change-detection across the user base.
- 24/7 uptime; restarts allowed during scheduled windows.
- One Rocket process. Vertical scale before horizontal.

---

## 2. The single most important call: audio off the request path

**Audio bytes never transit the Rust server.**

The server stores audio **metadata** (filename, hash, duration,
language, who uploaded). The bytes go to **object storage**
(Supabase Storage / S3 / R2 / B2). Browsers upload and download
directly via short-lived presigned URLs issued by the server.

```
              upload                                download
              ──────                                ────────
Browser  ─────────────────►  Object Storage  ◄─────────────  Browser
   ▲                             ▲    ▲                        ▲
   │ presigned PUT URL           │    │      presigned GET URL │
   │                             │    │                        │
   └──────────►  Rust Server  ◄──┘    └──── Rust Server  ──────┘
                  (issues URL)               (issues URL)
```

The server's network never sees the audio bytes. This is the
single largest scaling lever past ~50 simultaneous audio sessions.

Wins:

- A 1 Gbps server handles ~10× more concurrent audio sessions
  than if bytes transited it.
- Object storage is built for parallel cold reads — CDNs cache for
  free with most providers.
- Backups, lifecycle, replication = the storage provider's
  problem.
- The server scales on **requests**, not **bandwidth**.

This is how every serious audio/video product works (podcast
platforms, voice-memo apps, video-content platforms).

---

## 3. Bottlenecks ranked by when they hit

### 3.1 Audio bytes through the server (already covered in §2)

If §2 isn't done, every other optimization is wasted.

### 3.2 Git serialization on a hot language

`git2` is sync; concurrent commits on the same repo serialize.
Doesn't matter when 1,000 users edit 1,000 different languages.
Bites when 50 users edit the same popular language at once.

**Fix**: per-language `RwLock<()>`, lazily created on first use.

```rust
struct LanguageLocks {
    inner: parking_lot::RwLock<
        HashMap<LanguageCode, Arc<tokio::sync::RwLock<()>>>
    >,
}
```

Reads acquire for read; commits acquire for write. Memory: 1,000
locks × ~80 bytes = 80 KB. Ops on French don't block ops on
English; 50 reads on French don't serialize.

### 3.3 Blocking thread-pool starvation

One user's "rebuild language X" runs `git clone` for 60 s. Tokio's
default `spawn_blocking` pool defaults to 512 threads but fills
under bursty load.

**Fix**: bounded thread pools by work class.

```rust
// Default Tokio runtime — fast HTTP only.
// Git pool — bounded ~16 threads.
// CPU pool — ffmpeg, zip, hash-on-load — bounded ~num_cpus.
```

Submit git work via the git pool, audio/zip via the CPU pool.
Default Tokio pool stays free for serving HTTP. Effect: no single
user's heavy work starves the request path.

### 3.4 inotify watcher duplication

50 SSE subscribers on the same ingredient = 50 separate inotify
subscriptions. Linux's per-user `fs.inotify.max_user_watches`
defaults to 8,192. The arithmetic fails fast at scale.

**Fix**: shared fan-out registry.

```rust
type SubKey = (LanguageCode, IngredientPath);
type Sub    = tokio::sync::broadcast::Sender<HashEvent>;

struct WatcherRegistry {
    inner: parking_lot::RwLock<HashMap<SubKey, Sub>>,
}
```

50 users watching the same passage = 1 inotify watch + 50
broadcast receivers. Tear-down on last drop.

### 3.5 Per-process file-descriptor limit

Thousands of SSE connections = thousands of open sockets. Linux
default `nofile = 1024` is too low.

**Fix**: bump in systemd / Docker / k8s spec to 65535+.

### 3.6 GitHub API rate limit

Authenticated calls are limited to 5,000 / hr per user token.
Doesn't bite if reads serve from local clones; bites hard if every
read hits GitHub.

**Fix**: cache aggressively. Hit GitHub only on:
- OAuth flows (per sign-in).
- Writes (push, PR, merge — bounded by user activity).
- Webhook-triggered fetches (server's own clone refresh).
- Periodic 15-min fetch sweep (server's own clone refresh).

Per-user token rate-limits naturally distribute load. Consider
upgrading to a GitHub App (15,000 / hr installation-token limit)
when active user count crosses ~3,000.

### 3.7 Crash blast radius

One server = one restart drops every SSE connection. `EventSource`
auto-reconnects, but you get a thundering herd.

**Fix**: graceful shutdown.

```rust
// On SIGTERM: stop accepting new connections, send a final
// `event: shutdown` SSE event with a reconnect-after value, then
// close streams cleanly.

yield Event::data(format!("{{\"reconnect_after_ms\": {}}}", random_jitter_ms()))
    .event("shutdown");
```

Browser-side: clients listen for `shutdown` events and respect the
`reconnect_after_ms` value, spreading reconnects.

---

## 4. The architecture, six layers

### Layer 1: tenancy unit — language

Per-language GitHub repo. ACLs via GitHub repo collaborators.
Memberships cached in-process (30 s TTL).

### Layer 2: audio off the request path

Object storage; presigned URLs; server issues URLs and records
metadata only. (See §2.)

### Layer 3: per-language locking

`LanguageLocks` map of `RwLock`s. (See §3.2.)

### Layer 4: bounded blocking thread pools

Default + git pool + CPU pool. (See §3.3.)

### Layer 5: SSE fan-out registry

Shared inotify subscriptions broadcast to many subscribers. (See
§3.4.)

### Layer 6: caches

```rust
struct AuthCaches {
    memberships: Arc<MembershipCache>,        // 30 s TTL
    user_settings: Arc<UserSettingsCache>,    // 5 min TTL
    parsed_metadata: Arc<MetadataCache>,      // 1 min TTL, write-invalidated
}
```

Hit rates at steady state: ~99% on memberships, ~95% on metadata.
Miss cost: ~2 ms (GitHub API or local clone read).

---

## 5. Capacity envelopes

### Small machine (4 cores / 16 GB / 1 Gbps)

- ~1,000 concurrent SSE connections.
- ~1,500 active users (audio offloaded).
- ~100 req/s sustained, ~500 req/s peak.
- ~200 GB content on disk.

### Medium machine (16 cores / 64 GB / 10 Gbps)

- ~10,000 concurrent SSE connections.
- ~5,000–8,000 active users.
- ~500 req/s sustained, ~2,000–5,000 req/s peak.
- ~2 TB content on disk.

### Large machine (64 cores / 256 GB / 25 Gbps)

- ~50,000 concurrent SSE connections (with shared-watcher
  discipline).
- ~25,000+ active users.
- ~5,000 req/s sustained.
- ~10 TB content on disk; consider tiered storage (hot SSD + cold
  HDD).

These are conservative estimates assuming the architecture in §4.
Without §2 (audio offload), divide by 5–10×.

---

## 6. Operational checklist

In rough priority order:

- [ ] **Audio offloaded** to object storage with presigned URLs.
- [ ] **Per-language `RwLock` map** for git serialization.
- [ ] **Bounded thread pools** for git, CPU-heavy work.
- [ ] **SSE fan-out registry** (one inotify per path, many
      subscribers).
- [ ] **Membership cache** (30 s TTL).
- [ ] **`ulimit -n` ≥ 65535** in systemd / Docker config.
- [ ] **Reverse-proxy SSE config** (no buffering, generous
      read-timeout). See `docs/HOSTING.md` §5.
- [ ] **Structured logging** (`tracing`) with per-request span
      IDs and per-language activity tags.
- [ ] **Graceful shutdown** that drains SSE + closes git locks
      cleanly.
- [ ] **Liveness and readiness probes** (`/version`, `/health`).
- [ ] **Metrics endpoint** (`/metrics` Prometheus format).
- [ ] **Backup strategy** for the workspace volume (rsync nightly
      + snapshot before deploys).
- [ ] **Disaster-recovery test** — restore from backup, verify
      ACLs intact (they are: GitHub remembers).

Items 1–4 are architectural; the rest are ops hygiene that
quietly determines whether 5,000 users feels fast or feels broken.

---

## 7. When to scale beyond one server

Vertical scaling buys years. Horizontal scaling (multiple Rust
instances) is genuinely complex and should be a last resort.
Triggers:

1. **CPU saturation in steady state**, not just bursts. Using
   >70% of 64 cores on average means vertical is exhausted.
2. **Network bandwidth saturation** that audio offload doesn't
   fix (text traffic alone filling the pipe). Highly unlikely at
   <10,000 active users.
3. **Geographic latency requirements** — Asia users need an Asia
   region, Europe users need a Europe region. Solved with
   multi-region deployments, not load-balanced replicas.
4. **Restart blast radius unacceptable.** Rolling restarts across
   instances let you deploy without dropping all connections.

When that day comes, the per-language tenancy model pays off:
shard languages across instances. Each instance is the source of
truth for ~half the languages. The reverse proxy's existing
language-routing knowledge maps requests to the right instance.
No SSE pub/sub backplane needed — each language's SSE stream
lives on the instance that owns the language.

---

## 8. Numbers to monitor in production

| Symptom | Look at |
|---|---|
| Latency spike on hot path | Blocking thread pool queue depth |
| SSE clients reconnecting in waves | Server graceful-shutdown logs; CPU usage |
| One language's writes are slow | Per-language lock wait time |
| Memory growing unbounded | Cache sizes; LRU eviction rate |
| inotify watch failures | `cat /proc/sys/fs/inotify/max_user_watches` |
| Audio uploads failing | Object storage quota / network egress |
| 401s mysteriously | Reverse-proxy `Authorization` pass-through |
| 5xx during deploys | Graceful-shutdown duration |
| GitHub API rate limit headroom shrinking | Per-user token usage |

Have these dashboards before you're trying to debug a real
incident.

---

## 9. What this enables

The architecture in this document makes the simpler cases trivial:

- **Desktop binary**: same crate, FS backend, single user, no
  auth. Scaling layers are no-ops or have FS-equivalent
  implementations.
- **Internal team server (10–50 users)**: same crate, FS or
  GitHub backend, basic auth fairing if desired. Scaling layers
  mostly no-ops at this size; the architecture doesn't get in the
  way.
- **Public hosted service (5,000+ users)**: same crate, GitHub
  backend, all scaling layers active. The architecture earns its
  keep.

One codebase, three deployments, no architectural divergence.

---

See also:

- `docs/ARCHITECTURE.md` — design rationale.
- `docs/HOSTING.md` — operator-facing integration contract.
- `docs/SECURITY.md` — security posture.
