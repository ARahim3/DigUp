# Stage 12 — integration groundwork: serving applications *of* the library (Nextcloud first)

The user's brief, in their words: Nextcloud, Immich and PhotoPrism should gain DigUp's search
"the most efficient, professional and streamlined way"; the Nextcloud app is installed like a
normal Nextcloud app; the operator pastes the server's `URL:port` into it; the search tool
"will have to remain user specific" — showing each user only files they have access to,
"even files shared with" them, never files they do not have; the app "must not change the
Nextcloud database at all … must not modify any files"; the server may live on another
computer (the GPU's box) and act as a service for several Nextcloud instances.

This stage is the **server-side half** (additive, `server/**` + `deploy/**` + docs): the
compose shape for a shared stack, the named-token map, the CORS allowlist, the principal
log, and the embed widget. The **application half** (the PHP app) lives in its own repository
(`digup-nextcloud`) — Nextcloud's app framework cannot live in this repo (§10, additive) and
the PR stays reviewable. What follows is the contract both halves code against.

## §11.1 The shape: one stack, the data dir mounted, the app is the ACL boundary

```
Nextcloud box (no GPU)                        AI server box (GPU)
  nextcloud container ─── compose network ─── digup-server container
      │ data dir (files under <user>/files) ──ro──▶ /media/photos  (a DIGUP_SERVER_ROOT)
      │ DigUp app (PHP, inside Nextcloud) ──Bearer(read token)──▶ /api/v1/search
      ▼
  browser ── Nextcloud's own login/previews/file-view; it never sees the token
```

* Indexing a platform is **a Compose volume, not code**: `deploy/docker-compose.nextcloud.yml`
  mounts the data dir read-only and pre-sets the exclusions (§11.3); `group_add`
  (`DIGUP_MEDIA_GID`, 33 = www-data by default in that file) is what lets uid 990 read the
  tree the Nextcloud scanner owns.
* The API gains no user concept: it answers for the whole index, as it always has. The
  **per-user ACL lives in the host application** — Nextcloud's app filters every result set
  against Nextcloud's own permissions (own files + user/group shares), maps paths to Nextcloud
  file ids, and renders through Nextcloud's own UI surfaces (previews via the core preview
  API, opening in the Files app). The single-user server (§7) stays single-user; the app
  makes the multi-user exposure safe.
* The token is a **server-to-server secret**: it travels from the Nextcloud container to the
  server container. The browser talks only to Nextcloud, with its normal session. The token
  never reaches a browser URL, a log line, a `<img>` src, or the page source.
* The server must **not** be able to change the host: the mount is `:ro`, the app uses read
  APIs only. The app creates **no database tables**; its settings are appconfig values — the
  mechanism every Nextcloud app uses — and its code carries no write APIs (the pilot audits
  this with `grep`, and the data dir's checksums prove it before/after a full session).

## §11.2 Named-token map and the principal log

`DIGUP_SERVER_READ_TOKENS=name:token,name:token,…` joins `DIGUP_SERVER_TOKEN`/
`DIGUP_SERVER_ADMIN_TOKEN` as a third, opt-in knob: every entry guards the **read scope
only** (index/estimate stay admin-only), the FIRST value wins per name, a malformed entry
is skipped with a named warning line, and revoking one entry revokes exactly that client.
`PrincipalLog` (outermost middleware) writes one line per guarded request —
`POST /api/v1/search -> 200 principal=nc-a` — so a shared server can say **which** client
asked. Health/docs stay out of the audit line (the healthcheck calls them every 30 s;
that is not an audit event). `test_integrations.py` pins the map's scopes, attribution,
revocation isolation, and the end-to-end API path.

## §11.3 Nextcloud data-dir exclusions (the junk gate)

A Nextcloud data dir is not only files: previews, thumbnails, versions and temporaries live
under `appdata_<instanceid>/`, and indexing those copies pollutes the index with derived
JPEGs. The engine's rules, read from `Sources/DigUpKit/Rules.swift` (read-only, matched,
not patched):

* `--exclude` matches **exact folder paths and their subpaths** — so the appdata exclusion
  is composed in Compose from the deployment's own instance id
  (`DIGUP_NEXTCLOUD_INSTANCE_ID`, from `php occ config:system:get instanceid`);
* folders carrying a `CACHEDIR.TAG` file — which is exactly what Nextcloud writes inside
  `preview/`, `thumbnails/`, `versions/` and `cache/` — are auto-skipped by the engine's
  cache-folder rule; the appdata exclusion then covers the folder itself;
* a `<name>.noindex` folder suffix is the user-facing opt-out the engine already honors.

**The gate**: `POST /estimate` over a pilot data dir containing both real gallery photos
and planted preview/thumbnails/versions copies reports **the photos only** — the copy
count is excluded, exactly, in the engine's own answer. Numbers land in
`IMPLEMENTATION_STATUS.md`.

## §11.4 CORS allowlist, the guard's one exception, and the embed widget

* `DIGUP_SERVER_ALLOWED_ORIGINS` = **exact origins** (`http://nextcloud.lan:8081`,
  scheme+host+port, comma-separated), OFF by default. The server's own UI is same-origin
  and server-to-server clients send no `Origin` at all — neither needs CORS. This exists
  for in-browser widgets hosted by other applications (the embed page below is served by
  this server; Immich *workspaces* will embed it at P2).
* `Cors` middleware: a preflight (`OPTIONS`) from an allowlisted origin answers 204 with
  the grant; a request from an allowlisted origin is passed with the response decorated
  (`access-control-allow-origin` + `Vary: Origin`). An origin not on the list gets nothing.
* The `HostOriginGuard`'s cross-origin-POST rule keeps its teeth: it refuses a
  cross-origin state-changing request **unless** the Cors middleware (installed outside the
  guard) marked the scope — a mark only a CORS-passed, operator-allowlisted origin can
  set. The rule defends cookie-authed CSRF; this API is cookie-free (§7), and browsers
  attach the bearer `Authorization` header cross-site only because this server's CORS
  allowed it — so the allowlist is exactly the boundary, and `test_integrations.py` pins
  all four combinations (allowlisted/not × POST/GET, plus the Host rule outranking all).
* `server/ui/embed.html` (+ `embed.css`, `embed.js`) — the compact widget: the same UI
  rules as the full UI (no external URLs, no build step, server-issued media handles, the
  engine's fields relayed verbatim, keyword-first typing with `embed_ahead`). *(2026-11-08:
  the widget is now the Lit `<digup-embed>` component built by Vite to the same pinned
  names — "no build step" applies to `shell/ui` only; the served names and every rule
  below are unchanged, pinned in `test_integrations.py`.)* Its token
  enters via `?token=`, moves to `sessionStorage`, and the URL line is rewritten
  (`history.replaceState`) so the secret never lands in bookmarks, history, or host logs;
  previews load as **authorized blob fetches**, never as `<img src?token=…>`; the host
  drives the theme by `postMessage {source:"digup-host", theme}` and the widget announces
  `{source:"digup-embed", event:"ready"}`.

## §11.5 Remote AI server, several Nextcloud instances, honest concurrency

* One server, one index, **N trees**: mount each instance's data dir under its own prefix
  (`/media/photos/nc-a`, `/media/photos/nc-b`), register one token-map entry per instance,
  and each app instance carries its own root prefix — dropping hits that belong to no
  tree of its instance is string math at the app's edge. The ghost-row rules apply
  unchanged: one index folder per root layout; a moved mount needs one prune job (§5).
* The GPU stays on the AI box: the Nextcloud machine needs neither card nor toolkit. The
  data dir reaches the AI server as a **read-only network mount** (NFS/SMB/rsync mirror) —
  a file indexer indexes files, and no protocol changes that. Documented as a standing
  prerequisite, not a bug. The LAN path is the shipped shape: `docker-compose.lan.yml`
  (loopback stays) + the required read token + `DIGUP_SERVER_ALLOWED_HOSTS` naming the
  names both sides use; off-LAN, an authenticating reverse proxy with TLS (§7).
* Nextcloud's SSRF firewall blocks PHP requests to private ranges by default — the app's
  README documents `config.php`'s `'allow_local_servers' => true` (config lives on a bind
  volume, so it persists); the pilot proves the hop.
* Concurrency honesty (measured, §7 "Multiple clients on one index"): the API answers one
  search at a time (0.7–0.8 s at 132k files measured on this box); index jobs serialize
  under the flock and answer `409` while busy. Family/small-office scale is fine on one
  server; heavier fleets run one server per instance — each with its own index folder.

## §11.6 What this stage deliberately does not do

* No Immich/PhotoPrism adapters built this stage (P2/P3, after the T0 spike) — the map,
  the CORS shape and the widget are their groundwork, and the compose mount recipes carry
  over unchanged (Immich `library/`, PhotoPrism `originals/` as roots).
* No Nextcloud database schema: the app has **no migration, no tables**; nothing in the
  server touches a Nextcloud process.
* No engine-side ACL, no per-user indexes, no user field on the API: the engine answers
  for the index it owns (§1, §4); the ACL belongs to the application that owns the users.
* The unified-search provider (DigUp tab inside Nextcloud's global search) is a documented
  follow-on (~one small class over the same service) — the Files-style top-bar page is
  the product of the first release.
* App-store packaging is a later milestone: personal install (`occ app:enable`) first,
  review process after.

## §11.7 WebDAV deployment: per-user davfs2 mounts as the server's roots

The user's deployment decision (2026-11-06): the share reaches the server over
Nextcloud's **built-in WebDAV endpoint**, not over a file-server export. The user's
follow-up (2026-11-07): **no host sudo** — the mounts must come up from the compose
file alone. The shape that satisfies both:

* The Nextcloud machine runs **nothing extra** (its `/remote.php/dav/files/<user>/` is
  the share). On the server machine, **the compose `dav` service does the mounting**
  (`--profile dav`, `deploy/dav/`): davfs2 in a privileged container (FUSE needs
  `/dev/fuse` + SYS_ADMIN — the standard fuse-in-container shape), mounting each user's
  dav view **read-only** at `/mnt/dav/<uid>/` (`ro` + `uid=990` + `0640/0750` — the
  Nextcloud bytes are un-writable through the mount by construction, readable by the
  server container and nobody else). Credentials ride the compose env chain
  (`DAV_USERS`, `DAV_APPPW="user:pw …"`) into the container's root-owned 600
  `/etc/davfs2/secrets`; per user they are **app passwords**
  (`occ user:auth-tokens:add <user>`). `deploy/nextcloud-webdav.sh` remains the
  documented **host-mount alternative** (fstab/automount deployments).
* **Propagation, measured 2026-11-07**: the dav container's bind is `:shared` and the
  server's media bind rides it `ro,rslave` (`DIGUP_MEDIA_BIND_OPTS`), so mounts appear
  and vanish **live** in the server — stop/start the dav container is the whole remount
  procedure, **no server restart** (measured: dav stop → estimate 0 files → dav start →
  153 files back on the same running server process). Graceful stop unmounts through the
  entrypoint's TERM trap. Two image facts this box measured: the mounting environment
  needs a **passwd entry for uid 990** (davfs2 resolves the tree's owner via getpwuid —
  "can't read user data base" otherwise), and **`buf_size 64`** in `davfs2.conf` (the
  1.7.x read breakage on modern kernels, "reading directory: Invalid argument" —
  Launchpad #2129131).
* **Roots are per user** (measured 2026-11-07): the engine's walk **does not cross
  mount points** — a walk rooted AT each dav view works, one walk through the shared
  parent sees zero subtrees. So `DIGUP_SERVER_ROOTS=/media/dav/alice:/media/dav/bob:…`
  — §11.5's multi-root colon list is exactly this shape.
* **The ACL moves into the mount**: a path under `<root>/<uid>/` is, by construction, a
  file in user `<uid>`'s own view (shares, groupfolders, received external shares,
  virtual files included — none of these exist in the raw data dir). The app's
  `mapping_mode=webdav` maps `<prefix>/<uid>/<rel>`: own files resolve in the asking
  user's view root; foreign-root hits resolve in the OWNER's view root (the mount
  mirrors it 1:1) and are confirmed by the asking user's own-view `getById` — the same
  core ACL boundary as the data shape, with the share-list prefix test replaced by the
  mount semantics. fileId dedup collapses the same file indexed under several viewers'
  mounts (a share embeds once per viewer-mount — the accepted cost, measured).
* **Why this beats NFS for this deployment**: server-side encryption survives (dav
  serves plaintext, NFS would hand the engine ciphertext); it is internet-safe (HTTPS +
  app passwords, no NFS export, no LAN-trust); zero privileged host setup; ACL per user
  for free. **Its costs, stated, not hidden**: shared trees duplicate in the index and
  in GPU time (per viewer-mount); davfs2 crawl latency; app passwords per user; the
  crawl reads through the web server (load on the Nextcloud box). Big libraries stay on
  the §11.5 mount shape; this is the encryption-safe/internet-safe/small-medium shape.
* **Ghost-row rule carries over**: this root layout owns its own index folder
  (`index-dav`); the 0-files signature (mounts down, or roots one level short) is
  self-diagnosing — the app's Test connection says so when the server reports 0 files.

## Pilot gates (this box, measured; numbers in `IMPLEMENTATION_STATUS.md`)

1. Suite: all passed, **0 skipped**, with `test_integrations.py` included (zero-skip rule).
2. Shared stack: Nextcloud + server from `docker-compose.nextcloud.yml`, corpus2-grade
   **public** gallery photos as the users' files, planted junk dirs; estimate excludes the
   junk exactly; one index job → `done`; searches answer strong.
3. Token scopes over the live stack: tokenless search 401; map token 200 on search/media,
   403 on index/estimate; admin token on estimate; the log names each principal.
4. The app: icon in the top bar; page = search box + results-count + Files-style preview
   grid; a query answers with previews (Nextcloud's own preview API) and z-scores;
   clicking a result opens Nextcloud's file view.
5. **ACL gate**: a restricted user sees only own + shared-with-them hits (counts recorded);
   a shared file answers for the sharee and not for an uninvolved user; a second instance
   on the same server sees only its own prefix's hits.
6. No-mutation proofs: data-dir file checksums identical before/after the full session;
   the app's code carries zero write APIs (`grep` audit line); the DB diff of a full
   session touches only the app's own appconfig rows (registration + settings) — the
   standard mechanism every Nextcloud app uses, named, not hidden.
7. Survival: `docker compose restart` (both services) → the app still answers; graceful
   stop of the server → exit 143 with `Application shutdown complete`.
8. **dav-container shape (2026-11-07, this box)**: `--profile dav` mounts three users'
   dav views read-only, propagated live into the running server (153 files across
   `/media/dav/<uid>` roots); full ACL gate battery green over dav roots (per-user hit
   sets, shared-file hits deduped to the viewer's own path, preview 200/404 scopes,
   token scopes 401/200/403 + admin estimate 200); mount-flap without a server restart
   (dav stop → estimate 0 files → dav start → 153 files back); graceful stop: server
   exit 143 + `Application shutdown complete`, dav unmount trap line, index survived
   (post-restart search 5 hits, top z 5.0); fixture checksums identical after the whole
   session (36/36; the only churn was Nextcloud's own appdata preview cache).
