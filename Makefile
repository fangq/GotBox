# GotBox build system
#
# Common targets:
#   make            - build the GUI app (optimized + stripped Release, ~3.6 MB)
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
#   make install    - install binary + .desktop + hicolor icons (PREFIX=~/.local)
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

PROJECT  := gotbox.lpi
BIN      := gotbox
JCFCFG   := tools/jcfsettings.cfg
RES      := gotbox.res
ICON     := assets/gotbox.ico
TESTOUT  := tests/lib
ICONSIZES := 16 22 24 32 48 64 128 256

PASSRC   := $(shell find src -name '*.pas')

.PHONY: all build debug release tests format format-check clean distclean \
        run hooks jcf icon install uninstall autostart linux win64 win32 macos help

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
	$(LAZBUILD) --build-mode=Release $(PROJECT)

# debug build keeps symbols/debug info for development (large, not stripped)
debug: $(RES)
	$(LAZBUILD) $(PROJECT)

# ---- cross builds ---------------------------------------------------------
linux: $(RES)
	$(LAZBUILD) --operating-system=linux  --widgetset=gtk2  $(PROJECT)
win64: $(RES)
	$(LAZBUILD) --operating-system=win64  --cpu=x86_64 --widgetset=win32 $(PROJECT)
win32: $(RES)
	$(LAZBUILD) --operating-system=win32  --cpu=i386   --widgetset=win32 $(PROJECT)
macos: $(RES)
	$(LAZBUILD) --operating-system=darwin --widgetset=cocoa $(PROJECT)

# ---- tests ----------------------------------------------------------------
# Each test is built and run under a hard per-test timeout (tests/run.sh) so a
# hang fails fast instead of blocking. Override with e.g. TIMEOUT=60 make tests.
tests:
	FPC="$(FPC)" tests/run.sh

# ---- formatting -----------------------------------------------------------
format:
	@test -x "$(JCF)" || { echo "JCF not found at $(JCF); run 'make jcf'"; exit 1; }
	$(JCF) -clarify -R -inplace -y -config=$(JCFCFG) src

format-check:
	@test -x "$(JCF)" || { echo "JCF not found at $(JCF); run 'make jcf'"; exit 1; }
	@tmp=$$(mktemp -d); cp -r src $$tmp/; \
	 $(JCF) -clarify -R -inplace -y -config=$(JCFCFG) $$tmp/src >/dev/null 2>&1; \
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
install: build icon
	install -Dm755 $(BIN) $(PREFIX)/bin/$(BIN)
	install -Dm644 packaging/linux/gotbox.desktop $(PREFIX)/share/applications/gotbox.desktop
	@for s in $(ICONSIZES); do \
	  install -Dm644 assets/icons/$${s}x$${s}/gotbox.png \
	    $(PREFIX)/share/icons/hicolor/$${s}x$${s}/apps/gotbox.png; \
	done
	-update-desktop-database $(PREFIX)/share/applications 2>/dev/null || true
	-gtk-update-icon-cache -f -t $(PREFIX)/share/icons/hicolor 2>/dev/null || true
	@echo "installed to $(PREFIX) (ensure $(PREFIX)/bin is on PATH)"

uninstall:
	rm -f $(PREFIX)/bin/$(BIN) $(PREFIX)/share/applications/gotbox.desktop
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
	rm -f $(BIN) $(BIN).exe tests/testgit tests/testauth tests/testlink tests/testworker tests/testsync tests/testhistory tests/testremote tests/testsuper tests/teststray tests/testengine $(RES)

help:
	@sed -n '1,30p' Makefile