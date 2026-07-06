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

## Local dev — `dev-install.sh` (no tag push)

Each library has a `dev-install.sh` so you can test local changes without pushing a git tag (the `~/.m2`
local repo is checked before JitPack):

- **`botmaker-sdk/dev-install.sh`** — installs the SDK (and reinstalls shared) into `~/.m2` under
  `com.github.LiQiyeDev:botmaker-sdk:local-SNAPSHOT` (a plain `mvn install` would use the wrong
  `com.botmaker.sdk` coordinate, so a bot wouldn't see it). Then set the bot's SDK version to
  `local-SNAPSHOT` (Studio's version field is editable).
- **`botmaker-shared/dev-install.sh`** — installs shared at `0.0.0-SNAPSHOT` (its groupId already matches
  JitPack, so no rename needed); that's the version every consumer defaults to via
  `${botmaker.shared.version}`, so the SDK build, Studio, and bots pick it up immediately.

Local-only — users select real released versions and never resolve these. Detail in each module's `CLAUDE.md`.

## Working across submodules

Edit code **inside the relevant submodule**, commit there, then bump that submodule's pointer in this umbrella
repo. Don't vendor one module's sources inside another. Each submodule keeps its own `ROADMAP.md`
(shared/sdk/studio) — update the one you changed.
