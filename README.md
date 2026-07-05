# BotMaker

Umbrella repository for BotMaker. It aggregates two git submodules:

- **`botmaker-studio/`** — the JavaFX visual bot-building IDE ([LiQiyeDev/botmaker-studio](https://github.com/LiQiyeDev/botmaker-studio)).
- **`botmaker-sdk/`** — the runtime SDK used by generated bots ([LiQiyeDev/botmaker-sdk](https://github.com/LiQiyeDev/botmaker-sdk)).
- **`botmaker-gallery/`** — the shared gallery of published bots ([LiQiyeDev/botmaker-gallery](https://github.com/LiQiyeDev/botmaker-gallery)).

Only `botmaker-sdk` and `botmaker-studio` are Maven modules in the reactor; `botmaker-gallery` is vendored as a git submodule only.

## Clone

```bash
git clone --recurse-submodules git@github.com:LiQiyeDev/botmaker.git
# or, after a plain clone:
git submodule update --init --recursive
```

## Build

The root `pom.xml` is a Maven aggregator that builds the SDK then the Studio in one reactor:

```bash
mvn install          # build both modules (SDK first)
mvn -pl botmaker-studio javafx:run   # run the Studio
```