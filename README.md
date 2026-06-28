# GotBox

[![CI](https://github.com/fangq/GotBox/actions/workflows/ci.yml/badge.svg)](https://github.com/fangq/GotBox/actions/workflows/ci.yml)

**Dropbox-like file sync for your own GitHub account.** GotBox keeps a folder on
your computer in sync across all your machines — edit a file, and it's
automatically saved, versioned, and pushed to a **private GitHub repository**;
changes from your other machines flow back automatically. No proprietary cloud,
no subscription, no file-size surprises — your data lives in git repos you own.

GotBox runs quietly in the **system tray** and just works in the background.

> **Who it's for:** a single user syncing their own files across several
> computers (laptop, desktop, work machine). It uses your GitHub account (or a
> self-hosted git server) as the sync hub.

---

## Contents

- [How it works](#how-it-works)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Getting started](#getting-started)
- [Using GotBox](#using-gotbox-the-tray-menu)
- [Notifications](#notifications)
- [Configuration](#configuration)
- [How GotBox protects your data](#how-gotbox-protects-your-data)
- [Start on login (autostart)](#start-on-login-autostart)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [Contributing](#contributing)

---

## How it works

You pick **one sync folder** (the *root*, default `~/GotBox`). That folder becomes
the working copy of a single private repo called **`.gotbox`** in your GitHub
account:

- **Loose files and folders** you drop in the root sync to the `.gotbox` repo.
- To sync a **separate project** (so it stays its own repo, possibly shared
  independently), you **link** it as a sub-folder. Each linked folder is a git
  *submodule* with a name you choose, backed by its own private repo, and syncs
  on its own.

GotBox watches everything for changes, commits and pushes automatically (after a
short pause so a burst of saves becomes one commit), pulls changes from your
other machines on a timer, and keeps the repos small by trimming old history.

---

## Features

- **Automatic two-way sync** — local edits are committed and pushed; remote
  changes are pulled and merged, all in the background.
- **Backed by private git repos** — your files live in repos you own on GitHub
  (or a self-hosted git server). Full version history comes for free.
- **Multi-machine** — set up the same account on another computer and your files
  appear there; edits propagate both ways.
- **Link separate projects as submodules** — keep distinct repos under one root,
  each with a custom local folder name, each syncing independently.
- **Never loses data on conflicts** — if the same file changed on two machines,
  GotBox keeps **both** versions and alerts you to resolve it.
- **Handles large files** — files at/above a size threshold are automatically
  tracked with **Git LFS**, so they don't hit GitHub's 100 MB push limit.
- **Stays lean** — caps repo history (rolling squash) and runs git maintenance
  so repos don't grow without bound.
- **Secure credentials** — your GitHub token is stored in the OS keychain
  (libsecret / macOS Keychain / Windows DPAPI), never in a plain config file, and
  never written to disk when handed to git.
- **Desktop notifications** — a quiet bubble tells you what synced (file names
  for a few files, a count for many) and alerts you to conflicts/errors.
- **Lightweight tray app** — colored tray icon shows sync state; background
  daemon mode; optional start-on-login.

---

## Requirements

- **git** — the system `git` command must be installed and on your `PATH`.
  - macOS: `xcode-select --install` or `brew install git`
  - Debian/Ubuntu: `sudo apt install git`
  - Windows: [git-scm.com](https://git-scm.com/) (or Git for Windows)
- **git-lfs** *(optional, recommended)* — needed only to sync very large files.
  Without it, large-file tracking is skipped with a warning.
  (`brew install git-lfs` / `sudo apt install git-lfs` / bundled with Git for Windows.)
- **A GitHub account** and a Personal Access Token (see [Getting started](#getting-started)).
  Or a self-hosted git server reachable over SSH.
- Linux secret storage *(optional)* — `libsecret` (`gnome-keyring` /
  `secret-tool`) lets GotBox use the system keychain; otherwise it falls back to
  an obfuscated file in your config dir.

---

## Installation

### Option 1 — download a prebuilt installer

Grab the installer for your OS from the **[Releases](../../releases)** page (or,
between releases, from the artifacts of the latest **Package** workflow run under
the Actions tab):

| OS | Package | Notes |
|----|---------|-------|
| **Linux** | `.deb` | Installs the app, a menu entry, and a login autostart entry. `sudo apt install ./gotbox_*.deb` |
| **Windows** | Setup `.exe` | Per-user install (Inno Setup); optional start-on-login shortcut. |
| **macOS** | `.dmg` | Drag **GotBox** to *Applications*. Unsigned, so the **first** launch needs right-click → **Open**. |

### Option 2 — build from source

See [Building from source](#building-from-source).

---

## Getting started

### 1. Create a GitHub token

GotBox needs a Personal Access Token so it can create and push to private repos
on your behalf.

1. Go to **GitHub → Settings → Developer settings → Personal access tokens**.
   (GotBox's **Account** window has a direct link.)
2. Create a **classic** token with the **`repo`** scope (this allows creating and
   pushing private repositories).
3. Copy the token — you'll paste it into GotBox once.

### 2. First launch

Start GotBox; it appears in your system tray. On first run it will:

1. Ask for your **GitHub username and token** (Account window) — paste the token;
   it's validated and saved to your OS keychain.
2. Confirm the **sync folder** (defaults to `~/GotBox`, created for you). Change
   it in **Settings** if you like.

That's it — drop files into the sync folder and they start syncing. The first
time content appears, GotBox creates your private `.gotbox` repo automatically.

### 3. Link a separate project (optional)

Use tray menu **→ Link submodule…** to add a project as its own repo under the
root. You can:

- **Create a new private repo** — give it an upstream repo name and a local
  folder name (they can differ), or
- **Attach an existing repo** — paste its URL and choose a local folder name.

### 4. Set up a second machine

Install GotBox on the other computer, sign in with the **same** GitHub account,
and point it at a sync folder. GotBox clones your existing `.gotbox` (and all its
linked submodules) and keeps everything in sync from then on.

---

## Using GotBox (the tray menu)

Right-click (or click) the tray icon:

| Item | What it does |
|------|--------------|
| **Open root folder** | Opens your sync folder in the file manager. |
| **Link submodule…** | Add a project as a submodule (new or existing repo). |
| **Sync now** | Force an immediate sync of everything. |
| **Status…** | Per-repo state (synced / syncing / conflict / error / paused), last-sync time, and a live activity log. Pause/resume, sync, or open individual repos here. |
| **Settings…** | Sync folder, backend, history cap, intervals, ignore patterns, machine name, LFS threshold. |
| **Account…** | GitHub username + token. |
| **Export log…** | Save the activity log to a file (handy for bug reports). |
| **About** | Version and project link. |
| **Quit** | Stop GotBox. |

The tray icon is color-coded: grey = idle/paused, green = synced, blue =
syncing, amber = conflict, red = error.

---

## Notifications

After a sync that changed files, GotBox shows a brief desktop notification:

- **Up to 3 files** — it lists the file names.
- **More than 3** — it reports the count (e.g. *"Synced 7 files"*).

It also alerts you when a **conflict** is kept-both or a repo hits a **sync
error** (open **Status…** for details).

---

## Configuration

Settings live in a JSON file you normally don't need to touch (edit it via the
**Settings** window):

| OS | Config file |
|----|-------------|
| Linux | `~/.config/gotbox/config.json` |
| macOS | `~/Library/Application Support/gotbox/config.json` |
| Windows | `%APPDATA%\gotbox\config.json` |

Key options (defaults in brackets):

| Setting | Meaning |
|---------|---------|
| **Root folder** | The synced directory. [`~/GotBox`] |
| **Backend** | `github` (HTTPS + token) or `git` (self-hosted over SSH). [`github`] |
| **GitHub user** | Your GitHub username. |
| **SSH base** | For the `git` backend, the base URL, e.g. `ssh://git@host/srv/git`. |
| **Machine name** | Identifies this computer in commit messages / conflict files. [hostname] |
| **History cap** | Keep about this many recent commits per repo (20–50). [30] |
| **Commit debounce** | Wait this long (ms) after the last save before committing. [5000] |
| **Pull interval** | How often (s) to pull remote changes. [60] |
| **GC every N commits** | Run git maintenance after this many commits. [25] |
| **LFS threshold (MB)** | Auto-track files at/above this size with Git LFS; `0` disables. [95] |
| **Ignore patterns** | Globs never synced. [`.git`, `*.tmp`, `*~`] |

> **Your token is never stored in this file** — it lives only in the OS keychain.

### Self-hosted / SSH backend

Prefer your own git server over GitHub? In **Settings**, set the backend to
`git` and provide the SSH base URL. GotBox then uses your SSH keys (no token
needed); repos are created as bare repositories under that base.

---

## How GotBox protects your data

- **Conflicts keep both copies.** If a file changed on two machines, the remote
  version stays at the real path and your local version is saved alongside as
  `name (conflict <machine> <timestamp>).ext`. Nothing is overwritten; you merge
  manually and delete the extra file.
- **History trimming is rewrite-safe.** When a repo's history is squashed past
  the cap and force-pushed, other machines detect the rewrite and reset to it
  *after* safely replaying any un-pushed local edits.
- **Large files use Git LFS** automatically (when `git-lfs` is installed) so big
  files sync instead of being rejected by GitHub's 100 MB limit.

---

## Start on login (autostart)

- **Installers** set this up for you (optional on Windows).
- **From a source build:** `make autostart` installs a login entry that launches
  `gotbox -d` (background daemon mode).
- **Manually:** run `gotbox -d` to detach into the background.

```sh
gotbox            # start (lives in the tray)
gotbox -d         # daemon: detach and run in the background (Unix/macOS)
gotbox --help     # list options
```

On Windows the GUI is already console-detached, so `-d` is a no-op.

---

## Troubleshooting

- **"git not found"** — install git and make sure it's on your `PATH`, then
  restart GotBox.
- **Token rejected / can't create repos** — the token needs the **`repo`** scope
  (classic token). Re-enter it in **Account…**.
- **Large file won't sync** — install `git-lfs` (large files at/above the LFS
  threshold need it); without it those files are skipped.
- **Nothing syncs on a fresh machine** — make sure you signed in (Account) and
  the sync folder is set; GotBox clones the existing `.gotbox` once both are set.
- **A folder shows as a broken "link" on GitHub** — that folder is itself a git
  repo. Either link it properly via **Link submodule…**, or remove its inner
  `.git` to sync it as plain files.
- **Tray icon looks like a generic gear (Linux, StatusNotifier panels)** — some
  desktops can't render the dynamically drawn icon. Installing via the `.deb`
  (which registers a themed icon) helps; otherwise the colored square shows on
  classic XEmbed tray panels.
- **App looks tiny on a HiDPI Linux screen** — GotBox follows your desktop's
  scaling; you can force it with `GOTBOX_SCALE=2 gotbox` (any factor).
- **Export the log** (**Export log…**) when reporting an issue.

---

## Building from source

Requires **Lazarus/FPC** and a local **git**.

```sh
make            # build the GUI app for the host (optimized, stripped)
make run        # build and launch
make debug      # build with debug symbols
make tests      # build and run the console test suite
make install    # install binary + desktop entry + icons (PREFIX=~/.local)
make autostart  # also start GotBox on login
make win64      # cross-compile (needs a matching cross-FPC + LCL)
```

If `make` can't find Lazarus (e.g. a machine with a different/older Lazarus, or a
shared home with a stale config), point it explicitly:

```sh
make LAZARUSDIR=/usr/lib/lazarus/<version>
```

### Project layout

- `src/core/` — the sync engine, git/REST/credential/LFS logic. LCL-free and
  unit-tested (`make tests`).
- `src/ui/` — the tray app and dialogs (LCL).
- `packaging/` — installer templates (`linux/`, `windows/`, `macos/`).
- `tools/` — formatter config, icon generator, git hooks.

---

## Contributing

GotBox uses **JCF** (JEDI Code Format) as its canonical Pascal formatter.

```sh
make jcf           # build+install the JCF CLI to ~/.local/bin (one time)
make hooks         # install the pre-commit auto-format hook
make format        # format all sources
make format-check  # verify formatting (used by CI)
```

Commit messages start with `[type] message`, type lower-case
(e.g. `[feat]`, `[fix]`, `[build]`, `[docs]`, `[test]`).
