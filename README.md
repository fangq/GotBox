# GotBox

A cross-platform desktop tool (Lazarus/FPC) that gives a Dropbox-like
"edit locally, auto-sync everywhere" experience, backed by **GitHub private
repos** instead of a proprietary cloud. Built for a single user working across
multiple machines.

You pick one **root directory**; each immediate subfolder maps to one private
GitHub repo. GotBox watches each subfolder, auto-commits and pushes on-disk
changes, periodically pulls remote changes, and keeps repos lean by capping
history and running git maintenance. It lives in the system tray.

## Status

Early development. Implemented and tested:

- **Skeleton** — tray icon + menu, Login/Settings/Status windows, JSON config, logging.
- **Auth** — OS credential store (libsecret / Keychain / file fallback) + GitHub
  token validation; login window persists the PAT.
- **Git runner** — async-safe wrapper over the system `git` CLI.

Pending: repo linking + auto-create, file watching + auto-commit worker,
sync/merge/keep-both conflicts, history trimming. See the design notes for the
full roadmap.

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
