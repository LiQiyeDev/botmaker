# BotMaker

Umbrella repository for BotMaker. It aggregates git submodules:

- **`botmaker-shared/`** — cross-platform native window plumbing (JNA) shared by the SDK and the Studio ([LiQiyeDev/botmaker-shared](https://github.com/LiQiyeDev/botmaker-shared)).
- **`botmaker-sdk/`** — the runtime SDK that generated bots compile against ([LiQiyeDev/botmaker-sdk](https://github.com/LiQiyeDev/botmaker-sdk)).
- **`botmaker-studio/`** — the JavaFX visual bot-building IDE ([LiQiyeDev/botmaker-studio](https://github.com/LiQiyeDev/botmaker-studio)).
- **`botmaker-gallery/`** — the shared gallery of published bots ([LiQiyeDev/botmaker-gallery](https://github.com/LiQiyeDev/botmaker-gallery)).

`botmaker-shared`, `botmaker-sdk` and `botmaker-studio` are Maven modules in the reactor (built in that
dependency order); `botmaker-gallery` is vendored as a git submodule only.

For how the pieces fit together — the dependency graph, JitPack publishing, local SDK dev, and releases —
see [`CLAUDE.md`](CLAUDE.md).

## Clone

```bash
git clone --recurse-submodules git@github.com:LiQiyeDev/botmaker.git
# or, after a plain clone:
git submodule update --init --recursive
```

## Build

The root `pom.xml` is a Maven aggregator that builds shared → sdk → studio in one reactor:

```bash
mvn install                          # build all three modules in dependency order
mvn -pl botmaker-studio javafx:run   # run the Studio
```

## Release

Cutting a coordinated release across the submodules is automated by [`release.sh`](release.sh):

```bash
./release.sh --shared 1.1.0 --sdk 1.0.7 --studio 1.0.7   # any subset; --dry-run to preview
```
