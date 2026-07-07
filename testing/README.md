# BotMaker Studio — cross-platform test environment

Manual/exploratory test harness for the Studio GUI across display servers and OSes.
Studio's Linux native backend (`botmaker-shared`) is **entirely X11 + kernel `uinput`**, so
behavior genuinely differs by display server — this harness makes it easy to launch Studio in
each combination and drive it by hand.

```
testing/
  windows/docker-compose.yml   # dockurr/windows VM (Windows 11)
  linux/
    {fedora,ubuntu,debian}.Dockerfile
    build-images.sh            # build the three toolchain images
    run.sh                     # launch Studio via x11docker (X11 or Wayland)
    entrypoint.sh              # runs inside the container (source/installer/appimage)
```

## Why not one docker-compose for everything?

`x11docker` is a CLI wrapper that provisions the nested X/Wayland server, GPU, security, and device
passthrough — it is **not** driven by docker-compose in idiomatic use, so the Linux side uses
`run.sh`. docker-compose stays the right tool for the Windows **VM** (a long-lived service).

---

## Windows (dockurr/windows)

```bash
docker compose -f testing/windows/docker-compose.yml up -d     # boot the VM
# web viewer:  http://localhost:8006     RDP: localhost:3389
docker compose -f testing/windows/docker-compose.yml down      # stop
```

Storage lives in `~/vms/windows-storage` (unchanged), so the existing install is preserved.

### Auto-installing BotMaker Studio in the guest

The compose file mounts `testing/windows/oem` to `/oem`. dockurr/windows copies that folder to
`C:\OEM` in the guest and runs `install.bat` **once**, right after Windows finishes installing.
It installs BotMaker Studio from (in priority order):

1. **A local `*.msi`** you drop into `testing/windows/oem/` — installs that exact build (e.g. an
   MSI pulled from CI). Ignored by git.
2. **A GitHub release** otherwise — the latest Windows `.msi`, or a pinned tag if you set
   `$Version` at the top of `oem/install.ps1`.

The jpackage MSI is self-contained (bundles its own JDK), so nothing else is provisioned. After it
runs, Studio is in the Start menu / on the desktop. Logs land in `oem/install.log` and `oem/msi.log`.

> The OEM hook only fires on a **fresh** Windows install. Since you already have a VM in
> `~/vms/windows-storage`, it won't run there — delete that folder to reprovision and trigger it,
> or just install manually in the guest (open the release `.msi` from a browser, or copy
> `oem/install.ps1` in and run it).

You can still build the `.msi` from source **inside** the VM (`mvn -Pdist package`) if you need to
test unreleased local changes — a Linux host can't cross-build a Windows installer.

---

## Linux (x11docker)

### Prerequisites (host)

- **x11docker** and **docker** on `PATH` (both present on this machine).
- **Nested display server**, provisioned on the host by x11docker (`run.sh` preflights these):
  - `x11` backend needs **Xephyr** — Fedora `sudo dnf install xorg-x11-server-Xephyr`,
    Debian/Ubuntu `sudo apt install xserver-xephyr`.
  - `wayland` backend needs **weston** — Fedora `sudo dnf install weston`,
    Debian/Ubuntu `sudo apt install weston`.
- **`/dev/uinput` writable inside the container**, to exercise `UinputBackend`. `run.sh` passes
  `--device=/dev/uinput`, but Docker preserves the node's host ownership (`root:root 0660`) and the
  container user isn't in a matching group — so a host-side `input`-group ACL is **not** enough. Make
  the node world-writable (throwaway test box) or use a `0666` udev rule:
  ```bash
  sudo modprobe uinput
  sudo chmod 0666 /dev/uinput                    # quick, non-persistent
  # persistent:
  echo 'KERNEL=="uinput", MODE="0666"' | sudo tee /etc/udev/rules.d/99-uinput.rules
  sudo udevadm control --reload && sudo udevadm trigger
  ```
  If absent/unwritable, `run.sh` still launches (the entrypoint banner prints the uinput status);
  only `uinput` input testing is unavailable.
- No GPU needed: JavaFX runs with the **software** Prism pipeline by default (`PRISM_ORDER=sw`),
  since the nested servers have no hardware GL. (See `USE_GPU` under "Run" if you want to try GL.)

### Build the images (once)

```bash
cd testing/linux
./build-images.sh                 # fedora + ubuntu + debian
./build-images.sh fedora          # or a single distro
```

Images are toolchain-only (JDK 21, Maven, GTK/X libs, jpackage packaging tools). The repo is
**bind-mounted at run time**, so you never rebuild an image just because Studio source changed.

### Run

```bash
./run.sh <distro> <x11|wayland> [source|installer|appimage]
```

| Arg      | Values                          | Meaning                                                        |
|----------|---------------------------------|----------------------------------------------------------------|
| distro   | `fedora` `ubuntu` `debian`      | which image                                                     |
| backend  | `x11`                           | `x11docker --xephyr` — isolated nested X server (clean X11)     |
|          | `wayland`                       | `x11docker --wayland` — nested weston compositor + XWayland     |
| mode     | `source` (default)              | `mvn -pl botmaker-studio -am javafx:run` — fast iteration       |
|          | `installer`                     | build native `.deb`/`.rpm`, install it, launch the installed app |
|          | `appimage`                      | build the `-Pdist` portable app-image, launch its launcher     |

Examples:

```bash
./run.sh fedora x11 source                 # quickest smoke test
./run.sh ubuntu wayland source             # Studio as XWayland client
GDK_BACKEND=wayland ./run.sh ubuntu wayland source   # NATIVE Wayland client
./run.sh fedora x11 installer              # build + install the .rpm, launch it
```

Optional env:
- `GDK_BACKEND=wayland` — native Wayland client instead of the default XWayland.
- `PRISM_ORDER=es2` — hardware JavaFX (needs `USE_GPU=1` and a GL-capable backend). Default is
  `sw` (software), because the nested Xephyr/weston servers have **no hardware GL**.
- `USE_GPU=1` — pass `--gpu` to x11docker. Off by default: with `--xephyr` it makes x11docker
  silently fall back to the insecure `--hostdisplay` (which then fails to open the display), so
  leave it off unless you know your backend has GL.

The host `~/.m2` is bind-mounted (at `/m2` in the container) so Maven downloads are cached across
runs; the repo is mounted at `/repo`.

> **Verified**: `./run.sh fedora x11 source` launches Studio's JavaFX UI in a nested Xephyr
> `:1` display with software Prism — no GPU, no host-display sharing.

### Test matrix (manual)

3 distros × {x11, wayland} in `source` mode → confirm launch + rendering + basic interaction.
Then `installer` on one deb distro (ubuntu/debian) and fedora (rpm) to validate native packaging.

## What to expect: X11 vs Wayland (the point of this harness)

- **X11 session** (`x11` backend, or `wayland` + default `GDK_BACKEND=x11`): Studio is an
  X11/XWayland client, so shared's `X11.java` / `XTest` window enumerate, capture, focus, move and
  input all work.
- **Native Wayland** (`wayland` backend + `GDK_BACKEND=wayland`): expect the X11 code path to
  **degrade** — enumeration sees only XWayland windows, XTest input is typically blocked, and
  screen capture won't see native Wayland windows. `UinputBackend` (device-level) can still inject
  input if `/dev/uinput` is passed. **This degradation is the behavior under test, not a setup bug.**

## Not covered here

The **X11-vs-Wayland native gap** in `botmaker-shared` (window enumerate/capture/focus/input) — that
genuinely needs a real display server, so this manual harness remains the way to validate it.

Automated **JavaFX UI** assertions, on the other hand, no longer need this harness (or any display):
`botmaker-studio` now has headless **TestFX + Monocle** tests (`src/test/java/com/botmaker/studio/ui/fx/`,
run with a plain `mvn -pl botmaker-studio test`, no `DISPLAY` required). They cover Studio's scene-graph
layer — screens/dialogs render, controls respond to real clicks/keystrokes — but by construction do
**not** exercise the native window gap above.
