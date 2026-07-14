# GotBox build system
#
# Common targets:
#   make            - build the GUI app (optimized + stripped Release, ~3.6 MB)
#   make gotboxd    - build the headless daemon (no GUI/X; for servers/SSH)
#   make debug      - build with debug info/symbols (large, for development)
#   make tests      - build and run the console test suite
#   make format     - format all Pascal sources with JCF (tools/jcfsettings.cfg)
#   make format-check - verify sources are already formatted (CI-friendly)
#   make run        - build and launch the app
#   make hooks      - install the git pre-commit formatting hook
#   make jcf        - build+install the JCF formatter into ~/.local/bin
#   make clean      - remove build artifacts
#   make distclean  - also remove binaries
#   make icon       - (re)generate assets/gotbox.ico from tools/make-icon.py
#   make install    - install prebuilt binary + .desktop + icons (does NOT rebuild)
#                     user:   make && make install                  (~/.local, no sudo)
#                     system: make && sudo make install PREFIX=/usr/local
#   make uninstall  - remove the installed files
#   make autostart  - start GotBox on login (drops a .desktop in ~/.config/autostart)
#
# Cross-compile targets (need a matching cross-FPC + LCL for the target):
#   make win64 | win32 | linux | macos

LAZBUILD ?= lazbuild
FPC      ?= fpc
FPCRES   ?= fpcres
JCF      ?= $(HOME)/.local/bin/jcf
PREFIX   ?= $(HOME)/.local

# Optional: force the Lazarus install dir. Useful when lazbuild's saved config
# points elsewhere (e.g. a different/older Lazarus, or a shared home whose
# ~/.lazarus was written by another machine). Empty -> let lazbuild auto-detect.
#   make LAZARUSDIR=/usr/lib/lazarus/2.2.0
LAZARUSDIR ?=
LAZDIR := $(if $(LAZARUSDIR),--lazarusdir="$(LAZARUSDIR)")

PROJECT  := gotbox.lpi
BIN      := gotbox
JCFCFG   := tools/jcfsettings.cfg
# JCF can't parse Objective-Pascal, so skip src/mac (objcclass externals for the
# Finder Sync extension). Format every other src subdirectory.
FMTDIRS  := $(filter-out src/mac,$(wildcard src/*))
RES      := gotbox.res
ICON     := assets/gotbox.ico
TESTOUT  := tests/lib
ICONSIZES := 16 22 24 32 48 64 128 256

PASSRC   := $(shell find src -name '*.pas')

.PHONY: all build debug release tests format format-check clean distclean \
        run hooks jcf icon overlay finder install uninstall autostart linux win64 win32 macos help

all: build

# the application icon (regenerated only if the generator script changes)
$(ICON): tools/make-icon.py
	python3 tools/make-icon.py
icon: $(ICON)

# the project resource is generated from the .rc/.manifest/icon so a fresh clone builds
$(RES): gotbox.rc gotbox.manifest $(ICON)
	$(FPCRES) -of res -o $(RES) gotbox.rc

# default build is the optimized, stripped Release mode (~3.6 MB vs ~30 MB debug)
build release: $(RES)
	$(LAZBUILD) $(LAZDIR) --build-mode=Release $(PROJECT)

# debug build keeps symbols/debug info for development (large, not stripped)
debug: $(RES)
	$(LAZBUILD) $(LAZDIR) $(PROJECT)

# headless daemon: the sync engine with no LCL/widgetset, so it runs with no X
# server (servers, plain SSH). Pure-FPC build from the core units -- no Lazarus
# project needed. Use `gotboxd [-d]` where the GUI `gotbox` can't open a display.
gotboxd: $(PASSRC)
	@mkdir -p lib/gotboxd
	$(FPC) -O2 -Fusrc/core -FUlib/gotboxd -o$@ gotboxd.lpr

# ---- Windows Explorer icon-overlay DLL ------------------------------------
# GotBoxOverlay.dll -- the in-process COM shell extension explorer.exe loads to
# draw per-file status badges (see gboxshellext.lpr / src/win). Windows-only;
# built for win64 with the same cross-FPC `make win64` uses. Its badge icons are
# embedded via a dedicated resource ($(OVERLAYRES)).
OVERLAYRES  := gboxoverlay.res
OVERLAYICONS := assets/overlay-synced.ico assets/overlay-modified.ico assets/overlay-conflict.ico
OVERLAYDLL  := GotBoxOverlay.dll

$(OVERLAYICONS): tools/make-icon.py
	python3 tools/make-icon.py

$(OVERLAYRES): gboxoverlay.rc $(OVERLAYICONS)
	$(FPCRES) -of res -o $(OVERLAYRES) gboxoverlay.rc

overlay: $(OVERLAYRES)
	@mkdir -p lib/overlay-win64
	$(FPC) -Twin64 -O2 -Fusrc/core -Fusrc/win -FUlib/overlay-win64 -o$(OVERLAYDLL) gboxshellext.lpr

# ---- macOS Finder Sync extension ------------------------------------------
# GotBoxFinder.appex -- the Finder status-badge extension (src/mac +
# packaging/macos/build-appex.sh). macOS only (needs Cocoa/FinderSync +
# codesign); the badge PNGs come from make-icon.py.
finder: $(OVERLAYICONS)
	FPC="$(FPC)" packaging/macos/build-appex.sh $(CURDIR)

# ---- cross builds ---------------------------------------------------------
linux: $(RES)
	$(LAZBUILD) $(LAZDIR) --operating-system=linux  --widgetset=gtk2  $(PROJECT)
win64: $(RES)
	$(LAZBUILD) $(LAZDIR) --operating-system=win64  --cpu=x86_64 --widgetset=win32 $(PROJECT)
win32: $(RES)
	$(LAZBUILD) $(LAZDIR) --operating-system=win32  --cpu=i386   --widgetset=win32 $(PROJECT)
macos: $(RES)
	$(LAZBUILD) $(LAZDIR) --operating-system=darwin --widgetset=cocoa $(PROJECT)

# ---- tests ----------------------------------------------------------------
# Each test is built and run under a hard per-test timeout (tests/run.sh) so a
# hang fails fast instead of blocking. Override with e.g. TIMEOUT=60 make tests.
tests:
	FPC="$(FPC)" tests/run.sh

# ---- formatting -----------------------------------------------------------
format:
	@test -x "$(JCF)" || { echo "JCF not found at $(JCF); run 'make jcf'"; exit 1; }
	$(JCF) -clarify -R -inplace -y -config=$(JCFCFG) $(FMTDIRS)

format-check:
	@test -x "$(JCF)" || { echo "JCF not found at $(JCF); run 'make jcf'"; exit 1; }
	@tmp=$$(mktemp -d); cp -r src $$tmp/; \
	 dirs=""; for d in $(FMTDIRS); do dirs="$$dirs $$tmp/$$d"; done; \
	 $(JCF) -clarify -R -inplace -y -config=$(JCFCFG) $$dirs >/dev/null 2>&1; \
	 if diff -ru src $$tmp/src; then echo "format OK"; rm -rf $$tmp; \
	 else echo "** sources need formatting: run 'make format' **"; rm -rf $$tmp; exit 1; fi

# build the JCF (JEDI Code Format) command-line tool from the Lazarus sources
jcf:
	tools/install-jcf.sh

hooks:
	install -m 755 tools/git-hooks/pre-commit .git/hooks/pre-commit
	@echo "installed .git/hooks/pre-commit"

run: build
	./$(BIN)

# ---- desktop integration (Linux) ------------------------------------------
# Install the binary, a .desktop entry, and the hicolor icons so the app shows
# up in the menu with the GotBox icon and StatusNotifier panels resolve it by
# name (Icon=gotbox) instead of a generic fallback. PREFIX defaults to ~/.local.
# Copy the already-built files -- does NOT recompile (so it's safe under sudo).
# Build first as your normal user, then install:
#   make && make install                        # into ~/.local  (no sudo)
#   make && sudo make install PREFIX=/usr/local  # system-wide
install:
	@test -x "$(BIN)" || { \
	  echo "GotBox isn't built yet. Build first as your normal user (not root):"; \
	  echo "    make"; \
	  echo "then:"; \
	  echo "    make install                         # into ~/.local (no sudo)"; \
	  echo "    make gotboxd && sudo make install PREFIX=/usr/local   # system-wide"; \
	  exit 1; }
	install -Dm755 $(BIN) $(PREFIX)/bin/$(BIN)
	@if [ -x gotboxd ]; then \
	  install -Dm755 gotboxd $(PREFIX)/bin/gotboxd; \
	else \
	  echo "(gotboxd not built -- run 'make gotboxd' for the headless server daemon; skipping)"; \
	fi
	install -Dm644 packaging/linux/gotbox.desktop $(PREFIX)/share/applications/gotbox.desktop
	@for s in $(ICONSIZES); do \
	  install -Dm644 assets/icons/$${s}x$${s}/gotbox.png \
	    $(PREFIX)/share/icons/hicolor/$${s}x$${s}/apps/gotbox.png; \
	done
	-update-desktop-database $(PREFIX)/share/applications 2>/dev/null || true
	-gtk-update-icon-cache -f -t $(PREFIX)/share/icons/hicolor 2>/dev/null || true
	@echo "installed to $(PREFIX) (ensure $(PREFIX)/bin is on PATH)"

uninstall:
	rm -f $(PREFIX)/bin/$(BIN) $(PREFIX)/bin/gotboxd $(PREFIX)/share/applications/gotbox.desktop
	@for s in $(ICONSIZES); do \
	  rm -f $(PREFIX)/share/icons/hicolor/$${s}x$${s}/apps/gotbox.png; \
	done
	-update-desktop-database $(PREFIX)/share/applications 2>/dev/null || true
	@echo "uninstalled from $(PREFIX)"

# launch GotBox in the background on login (Exec=gotbox -d)
autostart: install
	install -Dm644 packaging/linux/gotbox-autostart.desktop $(HOME)/.config/autostart/gotbox.desktop
	@echo "GotBox will start on login (remove $(HOME)/.config/autostart/gotbox.desktop to disable)"

clean:
	rm -rf lib $(TESTOUT) backup
	find . -name '*.o' -o -name '*.ppu' -o -name '*.or' | xargs -r rm -f

distclean: clean
	rm -f $(BIN) $(BIN).exe gotboxd gotboxd.exe tests/testgit tests/testauth tests/testlink tests/testworker tests/testsync tests/testhistory tests/testremote tests/testsuper tests/teststray tests/testengine tests/testfilestatus tests/testoverlayipc $(RES) $(OVERLAYRES) $(OVERLAYDLL)
	rm -rf GotBoxFinder.appex

help:
	@sed -n '1,30p' Makefile