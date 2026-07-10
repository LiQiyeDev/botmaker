# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in the **BotMaker umbrella repo**.
It is a map of how the pieces fit together; each submodule has its own `CLAUDE.md` with the detail.

## Layout

This repo is a Maven **aggregator** (`pom.xml`, `com.botmaker:BotMaker`) over git submodules:

| Submodule | Coordinate (published) | Role |
|-----------|------------------------|------|
| `botmaker-shared/` | `com.github.LiQiyeDev:botmaker-shared` | JNA native window plumbing (enumerate/capture/focus/move/input). No JavaFX/OpenCV. |
| `botmaker-sdk/`    | `com.github.LiQiyeDev:botmaker-sdk`    | Runtime library that generated bots compile against. Depends on shared. |
| `botmaker-studio/` | (app, not a library) | JavaFX IDE. Depends on shared. Generates bots + knows the SDK's public API. |
| `botmaker-gallery/`| — | Data-only submodule (published-bot index). Not in the reactor. |

The reactor `<modules>` order is **shared → sdk → studio** so each is built before its consumers; a
`mvn install` at the root builds all three, resolving the internal deps from the reactor.

## Dependency graph (who consumes whom)

```
shared ── depended on by ──▶ sdk ── consumed at runtime by ──▶ generated bots
   └────── depended on by ──▶ studio (editor-time window capture)
```

- **Studio does NOT depend on the SDK.** It *generates* bot projects whose pom pins the SDK
  (`services/MavenService`), and it mirrors the SDK's public facade names in `palette/SdkApi` (as strings,
  not imports). Studio's only BotMaker Maven dep is `shared`.
- Bots resolve the SDK from **JitPack**; the SDK (transitively) and Studio resolve **shared** from JitPack too.

## JitPack coordinate model (important)

JitPack builds each git tag on demand and **serves it as `com.github.LiQiyeDev:<repo>:<tag>` regardless of the
pom's `groupId`/`version`** — so a module's own `<version>` is cosmetic (JitPack overrides it with the tag).
Crucially, JitPack overrides only a build's **own** version, never its **dependencies**. That drives two things:

- **`shared`'s pom `groupId` is `com.github.LiQiyeDev`** (not `com.botmaker.shared`) so the reactor GAV equals
  the published GAV — one dependency line then resolves both locally and from JitPack.
- **sdk/studio reference `com.github.LiQiyeDev:botmaker-shared:${botmaker.shared.version}`.** The property
  defaults to `0.0.0-SNAPSHOT` (reactor/offline dev); the release script bumps it to the released shared tag
  so a published/JitPack build resolves the tagged shared. (The SDK's *own* coordinate is left as-is — CI/JitPack
  owns its version; don't "fix" it.)

## Releasing — `./release.sh`

Cross-module releases are ordered and were manual; `release.sh` automates the ordered tag/bump:

```bash
./release.sh --shared 1.1.0 --sdk 1.0.7 --studio 1.0.7   # any subset; --dry-run previews
```

It tags each requested module in dependency order, waits for `shared`'s JitPack build before tagging
downstream, bumps `botmaker.shared.version` in sdk/studio when shared is part of the release (and optionally
`MavenService.SDK_FALLBACK_VERSION` when the SDK is), pushes tags, and commits the moved submodule pointers.
Each repo's own CI reacts to the tag (sdk/shared → warm JitPack; studio → build app-images + GitHub Release).
It does **not** touch any module's own `<version>` — JitPack owns that.

## API stability — breakable for now (no external consumers yet)

**No published bot/project consumes the SDK or shared API yet.** Until one does, treat the `botmaker-sdk`
`api.*` facades and the `botmaker-shared` `NativeController`/`capture.*` contract as **freely breakable** —
remove/rename/retype public methods when it makes the API cleaner, without a compatibility shim. (The
per-module `CLAUDE.md` files carry the same note.) The only cost of a break is the ordered cross-module
release below (land shared → bump sdk/studio → release). Revisit and reinstate stability discipline once real
bots ship against a released SDK.

## Local dev (no tag push)

The old `dev-install.sh` / `dev-run.sh` scripts were removed. Local library changes propagate through the
**`~/.m2` local repo, which Maven checks before JitPack** — you just have to (re)install the changed module:

- **shared changes:** run `mvn -pl botmaker-shared -am install` (or umbrella `mvn install`) so shared lands at
  `0.0.0-SNAPSHOT` — the version every consumer defaults to via `${botmaker.shared.version}`. **Do this before
  launching Studio from IntelliJ:** IntelliJ's `javafx:run` builds the Studio module alone and resolves shared
  from `~/.m2`, so without a fresh install it silently uses a stale (or missing) shared jar. **Tip — make it
  automatic with `botmaker-sdk`, not `botmaker-shared`:** add a *Before launch → Run Maven Goal* with the
  command line `-pl botmaker-sdk -am install` (working dir = umbrella root) to the Studio run configuration.
  `-am` rebuilds `shared` **and** the SDK, so both land at `0.0.0-SNAPSHOT` on every launch — this covers
  *both* Studio's own stale-shared problem *and* newly created bots picking up your latest SDK. A goal of just
  `install` on `botmaker-shared` (a common mistake) refreshes shared but leaves the SDK jar frozen, so bots
  compile against an old SDK. Running Studio via the reactor instead — `mvn -pl botmaker-studio -am javafx:run`
  from the umbrella root — also resolves shared from the sibling module (but doesn't rebuild the SDK).
- **SDK changes (for a generated bot):** the SDK's pom `groupId` is now `com.github.LiQiyeDev` (matching the
  JitPack coordinate), so a plain `mvn install` already lands it where a bot resolves — the old `dev-install.sh`
  / `local-SNAPSHOT` / `-Dbotmaker.shared.version` dance is obsolete. Just run from the umbrella root:
  `mvn -pl botmaker-sdk -am install`. `-am` builds the reactor dep `shared` first, so both shared **and** the
  SDK land at `0.0.0-SNAPSHOT` (the version every consumer defaults to), and the installed SDK depends on that
  local shared. Re-run after each SDK edit; a bot pinned to `0.0.0-SNAPSHOT` picks up the new jar on its next
  classpath resolve.

**Selecting a local SDK build in Studio:** Studio scans `~/.m2` for locally-installed SDK `*-SNAPSHOT` builds
(`MavenService.localSdkVersions()`, newest first) and lists them at the top of the SDK version dropdown
(**New Project** and **Project ▸ Manage Libraries**), labeled `(local build)` and **preselected** — so a bot
created from a dev-run Studio is pinned to your local `0.0.0-SNAPSHOT` automatically. The scan is gated on
`AppVersion.isDevBuild()` (true only for an IDE/`javafx:run` launch with no jar manifest), so packaged builds
never surface `~/.m2` snapshots. shared isn't user-selectable (it's a transitive dep of the SDK). Released
builds' users only ever select real released versions and never resolve these.

## Working across submodules

Edit code **inside the relevant submodule**, commit there, then bump that submodule's pointer in this umbrella
repo. Don't vendor one module's sources inside another. Each submodule keeps its own `ROADMAP.md`
(shared/sdk/studio) — update the one you changed.
