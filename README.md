# GotBox

[![CI](https://github.com/fangq/GotBox/actions/workflows/ci.yml/badge.svg)](https://github.com/fangq/GotBox/actions/workflows/ci.yml)

A cross-platform desktop tool (Lazarus/FPC) that gives a Dropbox-like
"edit locally, auto-sync everywhere" experience, backed by **GitHub private
repos** instead of a proprietary cloud. Built for a single user working across
multiple machines.

You pick one **root directory**, which becomes the working tree of a single
private **`.gotbox`** repo. Loose files in the root sync to `.gotbox` itself, and
you link additional repos as **git submodules** under it (each with a custom
local name). Use **"Link submodule…"** to either create a new private repo or
attach an existing one. GotBox watches the root and each submodule, auto-commits
and pushes on-disk changes, periodically pulls remote changes, and keeps repos
lean by capping history and running git maintenance. It lives in the system tray.

Submodules use loose pointer tracking (`ignore = all`), so each syncs
independently and the `.gotbox` superproject isn't churned by their commits.

## Status

End-to-end functional, with a console test suite (`make tests`). Implemented:

- **Skeleton** — tray icon + menu, Login/Settings/Status windows, JSON config, logging.
- **Auth** — OS credential store (libsecret / Keychain / file fallback) + GitHub
  token validation; login window persists the PAT.
- **Git runner** — async-safe wrapper over the system `git` CLI, with
  non-interactive auth via a `GIT_ASKPASS` helper.
- **Repo linking** — scans the root's subfolders, auto-creates matching private
  repos via the REST API, wires remotes, and does the initial commit/push.
- **Sync engine** — one worker thread per repo: a polling file watcher,
  debounced auto-commit, and a bidirectional cycle (push / fast-forward / merge).
- **Conflicts** — unmergeable changes keep both versions and raise a tray alert.
- **History cap** — rolling squash + force-push past the cap, with a
  rewrite-safe reset so other machines absorb the rewrite losslessly.

Possible next steps: native file-watch backends (inotify / ReadDirectoryChangesW
/ FSEvents) behind the existing watcher interface, file-manager context-menu
integration, and per-platform packaging/autostart.

## Design decisions

- Cross-platform (Windows / Linux / macOS); core engine (`src/core/`) is
  LCL-free and unit-testable, GUI (`src/ui/`) is LCL.
- Uses the locally installed `git` CLI; authenticates with a GitHub Personal
  Access Token (scope `repo`) stored in the OS credential store.
- Auto-creates private repos via the GitHub REST API.
- Conflicts: keep both versions and flag the user (never lose data).
- History cap: rolling squash + force-push; remote is source of truth.

## Building

Requires Lazarus/FPC and a local `git`.

```sh
make            # build the GUI app for the host
make tests      # build and run the console test suite
make run        # build and launch
make release    # optimized build
make win64      # cross-compile (needs a matching cross-FPC + LCL)
```

## Formatting

GotBox uses **JCF** (JEDI Code Format) as its canonical Pascal formatter,
configured by `tools/jcfsettings.cfg`.

```sh
make jcf        # build+install the JCF CLI to ~/.local/bin (one time)
make hooks      # install the pre-commit auto-format hook
make format     # format all sources now
make format-check  # verify formatting (CI)
```

## Commit conventions

First commit line is `[type] message`, type lower-case
(e.g. `[feat]`, `[fix]`, `[build]`, `[docs]`, `[test]`, `[init]`).
