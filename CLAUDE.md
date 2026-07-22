# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in the **BotMaker umbrella repo**.
It is a map of how the pieces fit together; each submodule has its own `CLAUDE.md` with the detail.

## Layout

This repo is a Maven **aggregator** (`pom.xml`, `com.botmaker:BotMaker`) over git submodules:

| Submodule | Coordinate (published) | Role |
|-----------|------------------------|------|
| `botmaker-shared/` | `com.github.LiQiyeDev:botmaker-shared` | JNA native window plumbing (enumerate/capture/focus/move/input) + OCR core (`ocr/`, OpenCV+Tess4J), shared by SDK & Studio. No JavaFX. |
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

## Multi-phase work — stop at each phase boundary

A plan with numbered phases/steps is executed **one phase per turn**. At the end of each phase: commit that
phase's work, report what landed, and **stop** — do not roll straight into the next one. The maintainer
compacts the context between phases, so a turn that spans several phases loses the detail the later ones need.

Concretely, per phase: implement → build/test the touched modules → commit inside the submodule(s) → bump the
umbrella pointer if a submodule moved → summarise → end the turn. Resume from the plan file on the next turn.

## Code style (repo-wide)

Each module's `CLAUDE.md` has the detail; these two apply everywhere and are the ones that decay silently.

**Type a closed set instead of passing a bare `String`.** `PlatformId` (shared) is the worked example: the
emulator product key was a free-form `String platformId`, so a typo could invent a product and each consumer
kept its own id→display-name switch — which had already drifted ("MuMu" in Studio vs "MuMu Player" in shared).
An enum carrying the stable wire `id()` **and** the `displayName()` makes the set closed, exhaustively
switchable, and single-sourced. Keep the wire id stable if it's ever persisted, and keep the parse total
(`fromId` → `UNKNOWN`, never throws) so an unrecognised value from a newer config still loads. Counter-example
worth knowing: an `ActivityName` wrapper in Studio was considered and **rejected** — that identifier crosses
into generated bot source as a string literal (`Activity.disable("Mining")`) and is resolved through a
`String`-keyed registry, so a wrapper adds ceremony at a boundary that must be a runtime string anyway.

**A shared type owns the labels, keys and probes its consumers would otherwise each rebuild.** Because shared
feeds both the SDK and Studio, anything derivable from a shared type belongs there — `EmulatorInstance.identity()`
(never key a cache on a display name; instances routinely share one), `.brand()`, `PlatformStatus.statusLine()`,
`WindowsRegistry.firstNonBlank`, `PlatformScan.directory`. Duplicated copies don't stay identical; the naming
drift above and three different spellings of the same instance key are what prompted this note.

**Warnings baseline.** The IDE warnings come from an IntelliJ inspection profile
(`.idea/inspectionProfiles/Project_Default_copy.xml`), **not** javac — no pom sets `-Xlint` or `-Werror`, so a
clean `mvn install` says nothing about them. That profile started as "enable all 467 inspections", which buries
real findings under style dogma. It is now curated to ~222 enabled / ~245 disabled: **off** are house-style
opinions (`MagicNumber`, `HardCodedStringLiteral`, `LawOfDemeter`, `FeatureEnvy`, qualification/import-style
rules that literally contradict each other), size and complexity caps (`CyclomaticComplexity`, `ClassCoupling`,
`ParametersPerMethod`, …), exception-style rules that fight this codebase's deliberate best-effort
`catch (Exception)` in discovery/probe paths, and whole domains it doesn't use (JDBC, J2EE, serialization);
**on** are the ones that find defects — unused symbols, nullability and DFA, resource leaks (`IOResource`,
`SocketResource`), equality/`hashCode`, switch fall-through, unreachable code, concurrency, the JavaFX
inspections and `JavadocHtmlLint`. Note `.idea/` is **gitignored**, so the profile itself is not version
controlled — this paragraph is the reproducible record of the policy. Prefer disabling a noisy inspection over
contorting code to satisfy it, and say why here.
