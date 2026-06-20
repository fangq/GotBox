# GotBox build system
#
# Common targets:
#   make            - build the GUI app for the host platform (debug)
#   make release    - optimized build
#   make tests      - build and run the console test suite
#   make format     - format all Pascal sources with JCF (tools/jcfsettings.cfg)
#   make format-check - verify sources are already formatted (CI-friendly)
#   make run        - build and launch the app
#   make hooks      - install the git pre-commit formatting hook
#   make jcf        - build+install the JCF formatter into ~/.local/bin
#   make clean      - remove build artifacts
#   make distclean  - also remove binaries
#
# Cross-compile targets (need a matching cross-FPC + LCL for the target):
#   make win64 | win32 | linux | macos

LAZBUILD ?= lazbuild
FPC      ?= fpc
FPCRES   ?= fpcres
JCF      ?= $(HOME)/.local/bin/jcf

PROJECT  := gotbox.lpi
BIN      := gotbox
JCFCFG   := tools/jcfsettings.cfg
RES      := gotbox.res
TESTOUT  := tests/lib

PASSRC   := $(shell find src -name '*.pas')

.PHONY: all build debug release tests format format-check clean distclean \
        run hooks jcf linux win64 win32 macos help

all: build

# the project resource is generated from the .rc/.manifest so a fresh clone builds
$(RES): gotbox.rc gotbox.manifest
	$(FPCRES) -of res -o $(RES) gotbox.rc

build debug: $(RES)
	$(LAZBUILD) $(PROJECT)

release: $(RES)
	$(LAZBUILD) --build-mode=Release $(PROJECT) || $(LAZBUILD) -O3 $(PROJECT)

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
tests: | $(TESTOUT)
	$(FPC) -Fusrc/core -FU$(TESTOUT) -otests/testgit  tests/testgit.lpr
	$(FPC) -Fusrc/core -FU$(TESTOUT) -otests/testauth tests/testauth.lpr
	tests/testgit
	tests/testauth

$(TESTOUT):
	mkdir -p $(TESTOUT)

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

clean:
	rm -rf lib $(TESTOUT) backup
	find . -name '*.o' -o -name '*.ppu' -o -name '*.or' | xargs -r rm -f

distclean: clean
	rm -f $(BIN) $(BIN).exe tests/testgit tests/testauth $(RES)

help:
	@sed -n '1,30p' Makefile