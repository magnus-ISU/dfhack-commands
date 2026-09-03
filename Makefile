# Makefile — deploy this repo into Dwarf Fortress + DFHack.
#
# `make install` is the PLAYER deploy: scripts, the all-in-one bundle, and the plugins.
#
#   1. install-scripts  dfhack/ -> $DF/dfhack-config/scripts/   (hot-reloads a running DF)
#   2. install-mods     content-mods/high-adventure/high-adventure -> $DF/mods/   (BUNDLE ONLY)
#   3. install-plugin   install the plugin binaries into DFHack: df-smooth-movement (from
#                       $(REPO)) and ssaudio (from this repo's ssaudio-v* releases). A prebuilt
#                       is used ONLY when the release carries an asset built against the DFHack
#                       version in play; otherwise the plugin is COMPILED FROM LOCAL SOURCE.
#
# The local steps run FIRST so a network failure in step 3 cannot cost you a mod deploy.
#
#   make install                              # scripts + BUNDLE + plugins; deletes nothing
#   make install-from-source                  # same, but the plugins are ALWAYS compiled
#   make install-components                   # the bundle AND every ha-* member mod
#   make dev-install                          # install-components + prune-snapshots (destructive)
#   make install-mods                         # the bundle only, nothing else
#   make mods-status                          # repo vs deployed vs snapshot, no changes
#   make install DFHACK_DIR=/path/to/DFHack   # if your DFHack lives elsewhere
#   make build-plugins                        # compile + install both plugins, nothing else
#
# THINGS THAT WILL BITE YOU (see instructions.md for the long version):
#
# * `make install` NO LONGER DELETES ANYTHING. Snapshot pruning moved to `make dev-install`
#   (and `make prune-snapshots`), because deleting is a development choice, not a deploy step.
#   When you do run it, `prune-snapshots` runs `rm -rf` on every snapshot under
#   $B12/data/installed_mods whose version is below the one now in $DF/mods, which BREAKS ANY
#   SAVE generated against an older one.
# * `make install` deploys the BUNDLE ONLY. Shipping the bundle and its members side by side
#   puts every creature, entity and reaction in the mod picker twice. Use `install-components`
#   when you deliberately want the individual ha-* mods installable on their own.
# * DF scans $DF/mods exactly ONCE, at startup. Deploying while the game runs is invisible to it
#   — RESTART DF before generating a world, or worldgen silently uses the old raws.
# * The `high-adventure` bundle is GENERATED from the sibling ha-* mods and never updates itself.
#   install-mods refuses to deploy a bundle that has drifted from its members, and tells you to
#   bump the version in build-high-adventure.py and re-run it.
#
# Re-run after every DFHack update (plugins are ABI-specific to a DFHack version).

# Where the smooth-movement prebuilt releases come from. Tracks anmej's fork (branch main),
# which the other-authors/df-smooth-movement submodule also points at.
REPO           ?= anmej/df-smooth-movement
# This repo's own GitHub releases carry the prebuilt ssaudio binaries (tags: ssaudio-v*),
# built by .github/workflows/ssaudio-release.yml for both linux and windows.
SSAUDIO_REPO   ?= magnus-ISU/dfhack-commands
PLUGIN         ?= smooth-movement
# Which make target fetch-plugin falls back to when no correct-version prebuilt exists.
# install-plugin overrides this per plugin (build / build-ssaudio).
FETCH_BUILD    ?= build
# Which release to pull from: "latest" or a tag like v0.5.1 (applies to smooth-movement).
RELEASE        ?= latest
# DFHack version the asset must match, e.g. 53.16-r1.1. Empty = auto-detect via dfhack-run when
# the game is running, else assume $(DFHACK_TAG). An asset for any other version is never used —
# fetch-plugin compiles from source instead.
DFHACK_VERSION ?=

SHELL       := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# Platform + per-OS defaults. On Windows this Makefile expects a bash-flavored environment
# (Git Bash or MSYS2 with make installed); $(OS) is set to Windows_NT by Windows itself, which
# also covers MSYS/MINGW shells where uname reports MINGW64_NT-* rather than anything useful.
ifeq ($(OS),Windows_NT)
PLATFORM   := windows-x86_64
PLUGEXT    := .plug.dll
EXE        := .exe
DFHACK_DIR ?= /c/Program Files (x86)/Steam/steamapps/common/DFHack
else
PLUGEXT    := .plug.so
EXE        :=
ifeq ($(UNAME_S)/$(UNAME_M),Linux/x86_64)
PLATFORM   := linux-x86_64
else
PLATFORM   :=
endif
# The DFHack install directory (the folder that contains hack/plugins/). Override if yours differs;
# on some setups DFHack lives inside the Dwarf Fortress folder instead of its own.
DFHACK_DIR ?= $(HOME)/.local/share/Steam/steamapps/common/DFHack
endif

DFRUN   := $(DFHACK_DIR)/dfhack-run$(EXE)
PLUGDIR := $(DFHACK_DIR)/hack/plugins
SO      := $(PLUGDIR)/$(PLUGIN)$(PLUGEXT)

# --- source build (make build) ---
# Everything lives under build/ (gitignored): the DFHack source tree, its cmake build dir, and a
# locally-built XML::LibXSLT (DFHack's codegen needs it; built from CPAN when the system perl
# lacks it, so no root is required).
ROOT        := $(abspath .)
BUILDDIR    := $(ROOT)/build
DFHACK_SRC  := $(BUILDDIR)/dfhack
CMAKE_BUILD := $(DFHACK_SRC)/build-rel
PERL5_LOCAL := $(BUILDDIR)/perl5
PLUGIN_SRC  ?= $(ROOT)/other-authors/df-smooth-movement
# What the plugin source is symlinked to inside the DFHack tree's plugins/external, and the
# submodule to init when its source is missing (empty for first-party plugins, which are
# committed here rather than pulled in).
PLUGIN_LINK ?= df-smooth-movement
PLUGIN_SUBMODULE ?= other-authors/df-smooth-movement
# Git tag of the DFHack source to build against. Must match the installed DFHack (ABI).
DFHACK_TAG  ?= 53.16-r1.1
# DFHack refuses to configure under GCC 16+. Prefer a versioned gcc-15 when the default is newer.
CC_PIN      ?= $(shell if [ "$$(cc -dumpversion | cut -d. -f1)" -ge 16 ] && command -v gcc-15 >/dev/null; then command -v gcc-15; else command -v cc; fi)
CXX_PIN     ?= $(shell if [ "$$(c++ -dumpversion | cut -d. -f1)" -ge 16 ] && command -v g++-15 >/dev/null; then command -v g++-15; else command -v c++; fi)
JOBS        ?= $(shell nproc)

# --- README composition (make readme) ---
# README.md is GENERATED. Edit the parts, never README.md.
# BROKEN_FEATURES.md is deliberately NOT included: the README advertises what works.
# JOKE_FEATURES.md is deliberately NOT included either, for the opposite reason: those tools
# work fine, they are just jokes and not what this repo is offering people.
#
# The header is emitted verbatim. Each SECTION file is folded into a collapsed <details> block:
# its single leading `# h1` becomes the <summary>, everything after it becomes the body. That is
# why the section files carry exactly one h1 at the top and use h2 for their groups.
README_HEADER   := README-HEADER.md
README_SECTIONS := FORTRESS_MODE_FEATURES.md \
                   ADVENTURE_MODE_FEATURES.md \
                   HIGH_ADVENTURE_FEATURES.md
README_PARTS    := $(README_HEADER) $(README_SECTIONS)

# --- repo deploy (make install-scripts / install-mods / prune-snapshots) ---
# DF_DIR is the game install (contains mods/ and dfhack-config/). B12_DIR is DF's USER data, a
# different tree entirely: saves live there, and so do the per-world baked mod snapshots that
# prune-snapshots cleans out. Both paths contain a space — every use must stay quoted.
ifeq ($(OS),Windows_NT)
DF_DIR      ?= /c/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress
# Windows DF keeps its user data (saves, baked mod snapshots) inside the game dir itself;
# there is no separate "Bay 12 Games" tree like on Linux.
B12_DIR     ?= $(DF_DIR)
else
DF_DIR      ?= $(HOME)/.local/share/Steam/steamapps/common/Dwarf Fortress
B12_DIR     ?= $(HOME)/.local/share/Bay 12 Games/Dwarf Fortress
endif
MODS_SRC    := $(ROOT)/content-mods/high-adventure
SCRIPTS_SRC := $(ROOT)/dfhack
BUNDLE      := high-adventure
# subtrees the bundle build merges verbatim from each member; used to detect a drifted bundle
MERGED_SUBDIRS := objects graphics scripts_modactive

.DEFAULT_GOAL := help
# Deploy order matters (mods before the network step; prune after the deploy that defines
# "current"), so never let -j interleave these.
.NOTPARALLEL:
.PHONY: help install install-from-source dev-install install-scripts install-mods install-components \
        uninstall-components check-bundle prune-snapshots mods-status \
        install-plugin fetch-plugin build build-ssaudio build-plugins \
        enable disable status uninstall readme docs-todo

help:
	@echo "dfhack-commands — make targets:"
	echo
	echo "Deploy the repo into the game:"
	echo "  make install            scripts + the all-in-one BUNDLE + plugins. Deletes nothing."
	echo "  make install-from-source   the same deploy, with both plugins ALWAYS compiled"
	echo "  make install-scripts    dfhack/ -> DF's script path; hot-reloads a running DF"
	echo "  make install-mods       the \$(BUNDLE) bundle only -> \$$DF/mods"
	echo "  make install-components the bundle AND every individual ha-* mod"
	echo "  make uninstall-components  rm -rf the individual ha-* mods from \$$DF/mods"
	echo "                          (leaves the bundle, and touches no world snapshots)"
	echo "  make dev-install        install-components, then prune-snapshots. DESTRUCTIVE."
	echo "  make prune-snapshots    rm -rf per-world snapshots older than what is deployed."
	echo "                          THIS BREAKS SAVES made against those versions, by design."
	echo "  make mods-status        repo vs deployed vs snapshot versions; changes nothing"
	echo
	echo "Plugins (smooth-movement + ssaudio; linux and windows):"
	echo "  make install-plugin  install both: a checksum-verified prebuilt when the release has one"
	echo "                  for this DFHack version, otherwise COMPILED FROM SOURCE"
	echo "  make build-plugins   compile + install both from local source, never downloading"
	echo "  make build      compile one plugin ($(PLUGIN)) from the submodule source (clones the"
	echo "                  DFHack source tree into build/ on first run). Restart DF after."
	echo "  make enable     load + enable it now (Dwarf Fortress must be running)"
	echo "  make disable    disable it now"
	echo "  make status     show the plugin's status / installed binary"
	echo "  make uninstall  remove the installed plugin binary"
	echo
	echo "Repo targets:"
	echo "  make readme     compose README.md from $(words $(README_PARTS)) part files (edit those, not README.md)"
	echo
	echo "Variables (override on the command line, e.g. make install DFHACK_DIR=...):"
	echo "  DF_DIR          = $(DF_DIR)"
	echo "  B12_DIR         = $(B12_DIR)"
	echo "  DFHACK_DIR      = $(DFHACK_DIR)"
	echo "  RELEASE         = $(RELEASE)"
	echo "  DFHACK_VERSION  = $(if $(DFHACK_VERSION),$(DFHACK_VERSION),(auto-detect))"
	echo "  REPO            = $(REPO)"

# Local deploys first: if the network step fails, the mods are already in place.
# This is the PLAYER deploy: the bundle, and nothing removed.
install: install-scripts install-mods install-plugin
	@echo
	echo "All deployed. RESTART Dwarf Fortress before generating a world — DF scans mods/ once,"
	echo "at startup, so raws deployed into a running game are invisible to worldgen."

# The DEVELOPER deploy: every individual ha-* mod as well as the bundle, and then the old
# one-version-only policy applied to the baked world snapshots. Destructive on purpose; this is
# where "delete anything superseded" lives now that `install` no longer does it.
dev-install: install-scripts install-components prune-snapshots install-plugin
	@echo
	echo "Dev deploy complete: bundle + members installed, stale snapshots pruned."
	echo "RESTART Dwarf Fortress before generating a world."

# ---------------------------------------------------------------------------
# dfhack/ mirrors the deployed layout exactly, so a plain recursive copy keeps every command's
# folder prefix (fort/auto-name, adv/reveal, ...). Overlay widgets need a rescan to pick up new
# code; plain commands are re-read per invocation, so they need nothing.
install-scripts:
	@dst="$(DF_DIR)/dfhack-config/scripts"
	if [ ! -d "$(DF_DIR)" ]; then
	  echo "Dwarf Fortress not found at: $(DF_DIR)"
	  echo "Point DF_DIR at your install:  make install-scripts DF_DIR=/path/to/Dwarf Fortress"
	  exit 1
	fi
	mkdir -p "$$dst"
	cp -r "$(SCRIPTS_SRC)/." "$$dst/"
	echo "scripts -> $$dst ($$(find "$(SCRIPTS_SRC)" -name '*.lua' | wc -l) lua files)"
	if [ -x "$(DFRUN)" ] && "$(DFRUN)" lua 'print(1)' >/dev/null 2>&1; then
	  "$(DFRUN)" lua 'require("plugins.overlay").rescan()' >/dev/null 2>&1 \
	    && echo "  hot-reloaded overlays in the running game" \
	    || echo "  warning: overlay rescan failed — check the DFHack console for a load error"
	else
	  echo "  (DF not running; scripts load on next launch)"
	fi

# ---------------------------------------------------------------------------
# Deploy mods, each via an atomic copy-then-swap so a half-written mod is never visible to a
# running game. WHICH mods depends on the target:
#
#   install-mods        the generated $(BUNDLE) bundle, and nothing else. This is what a player
#                       wants: the bundle already contains every member's raws, so installing
#                       the members alongside it lists everything in the picker twice.
#   install-components  the bundle AND every individual ha-* mod, for testing one in isolation.
#
# Neither prunes anything. Deleting old snapshots is `prune-snapshots` / `dev-install`.
install-mods:       MOD_SELECT := bundle
install-components: MOD_SELECT := all
install-mods install-components: check-bundle
	@if [ ! -d "$(DF_DIR)/mods" ]; then
	  echo "No mods/ dir under: $(DF_DIR)"
	  echo "Point DF_DIR at your Dwarf Fortress install."
	  exit 1
	fi
	cd "$(MODS_SRC)"
	field() { sed -n "s/^\[$$2:\(.*\)\]/\1/p" "$$1/info.txt" | head -1 | tr -d '\r'; }
	# declared up front: .SHELLFLAGS carries -u, so the first append below would otherwise
	# abort the whole deploy on an unbound variable
	drifted=""
	for m in */; do
	  m="$${m%/}"
	  [ -f "$$m/info.txt" ] || continue
	  # install-mods ships the bundle alone; install-components ships everything
	  if [ "$(MOD_SELECT)" != "all" ] && [ "$$m" != "$(BUNDLE)" ]; then continue; fi
	  new="$$(field "$$m" DISPLAYED_VERSION)"
	  dst="$(DF_DIR)/mods/$$m"
	  old="(new)"
	  [ -f "$$dst/info.txt" ] && old="$$(field "$$dst" DISPLAYED_VERSION)"
	  # Same version, different bytes = the trap DF cannot see: it keys snapshots by version, so
	  # it will keep serving the old snapshot forever. Loud warning, not an error — you may simply
	  # be re-deploying after an edit you have not versioned yet.
	  same_ver_drift=""
	  if [ "$$old" = "$$new" ] && [ -d "$$dst" ]; then
	    diff -rq "$$m" "$$dst" >/dev/null 2>&1 || same_ver_drift=" <- CONTENT CHANGED WITHOUT A VERSION BUMP"
	  fi
	  tmp="$$dst.tmp.$$$$"
	  rm -rf "$$tmp"
	  cp -a "$$m" "$$tmp"
	  rm -rf "$$dst"
	  mv "$$tmp" "$$dst"
	  if [ "$$old" = "$$new" ]; then
	    printf '  %-26s %s%s\n' "$$m" "$$new" "$$same_ver_drift"
	    # a full `if`, not `[ ... ] && ...`: -e would treat the false test as a failed
	    # command and kill the loop on the first mod that redeploys cleanly
	    if [ -n "$$same_ver_drift" ]; then drifted="$$drifted $$m"; fi
	  else printf '  %-26s %s -> %s\n' "$$m" "$$old" "$$new"; fi
	done
	if [ -n "$${drifted:-}" ]; then
	  echo
	  echo "  NOTE:$$drifted changed content but kept the same version number."
	  echo "  \$$DF/mods now has the new files, but every ALREADY-GENERATED world keeps loading"
	  echo "  its baked snapshot, which DF keys by version and will therefore never refresh."
	  echo "  Bump those mods (and rebuild the bundle) if the change must reach existing worlds."
	fi
	if [ "$(MOD_SELECT)" != "all" ]; then
	  echo "  (bundle only — run 'make install-components' to also install the individual ha-* mods)"
	fi

# ---------------------------------------------------------------------------
# Remove every mod this repo ships EXCEPT the bundle -- the individual ha-* members and the
# standalone content-mods helpers (crash-repro and friends). Mods you installed yourself are
# never touched.
#
# This removes the BAKED SNAPSHOTS too, and it has to: DF lists a mod once per copy it can see,
# so a mod deleted from $DF/mods still shows up in the picker for as long as a snapshot of it
# survives under $B12/data/installed_mods. Deleting only one of the two is why "uninstalled"
# mods keep reappearing. THE SNAPSHOT HALF BREAKS SAVES: any world generated against one of
# these mods loads its scripts and graphics from that snapshot and will not load without it.
uninstall-components:
	@dst="$(DF_DIR)/mods"
	if [ ! -d "$$dst" ]; then echo "No mods/ dir under: $(DF_DIR)"; exit 0; fi
	# Only ever remove mods THIS REPO ships -- the ha-* members plus the standalone content-mods
	# helpers like crash-repro. Anything else under mods/ belongs to the player and is left alone.
	shopt -s nullglob
	ours=""
	for d in "$(MODS_SRC)"/*/ "$(ROOT)/content-mods"/*/; do
	  b="$$(basename "$$d")"
	  [ -f "$$d/info.txt" ] || continue
	  [ "$$b" = "$(BUNDLE)" ] && continue
	  ours="$$ours $$b"
	done
	removed=0
	for b in $$ours; do
	  [ -d "$$dst/$$b" ] || continue
	  rm -rf "$$dst/$$b"
	  printf '  REMOVED %s\n' "$$b"
	  removed=$$((removed + 1))
	done
	if [ "$$removed" -eq 0 ]; then echo "  nothing to remove from mods/: only the $(BUNDLE) bundle is installed"
	else echo "  -> $$removed mod(s) removed from mods/; the $(BUNDLE) bundle is untouched."; fi
	# ...and the baked snapshots, or DF keeps listing them.
	snap="$(B12_DIR)/data/installed_mods"
	if [ ! -d "$$snap" ]; then exit 0; fi
	ids=""
	for d in "$(MODS_SRC)"/*/ "$(ROOT)/content-mods"/*/; do
	  b="$$(basename "$$d")"
	  [ -f "$$d/info.txt" ] || continue
	  [ "$$b" = "$(BUNDLE)" ] && continue
	  ids="$$ids $$(sed -n 's/^\[ID:\(.*\)\]/\1/p' "$$d/info.txt" | head -1 | tr -d '\r')"
	done
	snapped=0
	for d in "$$snap"/*/; do
	  b="$$(basename "$$d")"
	  id="$${b%% (*}"
	  for want in $$ids; do
	    if [ "$$id" = "$$want" ]; then
	      rm -rf "$$d"
	      printf '  REMOVED snapshot %s\n' "$$b"
	      snapped=$$((snapped + 1))
	      break
	    fi
	  done
	done
	if [ "$$snapped" -gt 0 ]; then
	  echo "  -> $$snapped snapshot(s) removed. Worlds generated against them will no longer load."
	fi

# ---------------------------------------------------------------------------
# DF bakes a per-world snapshot named "<MOD_ID> (numeric_version)" and loads that world's scripts
# and graphics from it forever. Anything below the deployed version is dead weight that still
# shows up in the mod picker, so it goes. Snapshots for IDs this repo does not ship are left
# alone. A snapshot AT the deployed version is current — keep it, a live world is using it.
prune-snapshots:
	@snap="$(B12_DIR)/data/installed_mods"
	if [ ! -d "$$snap" ]; then echo "no snapshot dir at $$snap — nothing to prune"; exit 0; fi
	cd "$(MODS_SRC)"
	field() { sed -n "s/^\[$$2:\(.*\)\]/\1/p" "$$1/info.txt" | head -1 | tr -d '\r'; }
	declare -A cur
	for m in */; do
	  m="$${m%/}"
	  [ -f "$$m/info.txt" ] || continue
	  cur["$$(field "$$m" ID)"]="$$(field "$$m" NUMERIC_VERSION)"
	done
	shopt -s nullglob
	deleted=0
	for d in "$$snap"/*/; do
	  b="$$(basename "$$d")"
	  id="$${b%% (*}"
	  n="$${b##*\(}"; n="$${n%\)}"
	  want="$${cur[$$id]:-}"
	  if [ -z "$$want" ]; then printf '  keep    %-34s (not a mod this repo ships)\n' "$$b"; continue; fi
	  case "$$n" in ''|*[!0-9]*) printf '  keep    %-34s (unparsable version)\n' "$$b"; continue ;; esac
	  if [ "$$n" -lt "$$want" ]; then
	    rm -rf "$$d"
	    printf '  DELETED %-34s (superseded by %s)\n' "$$b" "$$want"
	    deleted=$$((deleted + 1))
	  else
	    printf '  keep    %-34s (current)\n' "$$b"
	  fi
	done
	if [ "$$deleted" -gt 0 ]; then
	  echo "  -> $$deleted stale snapshot(s) removed. Saves made against them will no longer load."
	  if command -v pgrep >/dev/null 2>&1 && pgrep -x dwarfort >/dev/null 2>&1; then
	    echo "  -> Dwarf Fortress is RUNNING. If the world you have loaded used one of these,"
	    echo "     do not count on reloading that save."
	  fi
	fi

# Read-only three-way comparison: what the repo builds, what the game will load at next startup,
# and which baked snapshots survive. Run it after an install to confirm the deploy landed.
mods-status:
	@cd "$(MODS_SRC)"
	field() { sed -n "s/^\[$$2:\(.*\)\]/\1/p" "$$1/info.txt" | head -1 | tr -d '\r'; }
	snap="$(B12_DIR)/data/installed_mods"
	printf '%-26s %-8s %-10s %s\n' MOD REPO DEPLOYED SNAPSHOTS
	for m in */; do
	  m="$${m%/}"
	  [ -f "$$m/info.txt" ] || continue
	  r="$$(field "$$m" DISPLAYED_VERSION)"
	  id="$$(field "$$m" ID)"
	  p="MISSING"
	  [ -f "$(DF_DIR)/mods/$$m/info.txt" ] && p="$$(field "$(DF_DIR)/mods/$$m" DISPLAYED_VERSION)"
	  shopt -s nullglob
	  s=""
	  for d in "$$snap/$$id ("*")"/; do
	    b="$$(basename "$$d")"; v="$${b##*\(}"; s="$$s $${v%\)}"
	  done
	  [ -z "$$s" ] && s=" (none)"
	  mark=""; [ "$$r" = "$$p" ] || mark="   <<< STALE, run make install-mods"
	  printf '%-26s %-8s %-10s%s%s\n' "$$m" "$$r" "$$p" "$$s" "$$mark"
	done

# Both prebuilt plugins in one pass: smooth-movement from $(REPO), ssaudio (the sound backend
# behind joke/super-saiyan) from this repo's own ssaudio-v* releases. ssaudio is best-effort —
# until a ssaudio-v* release has been published (push a tag, CI builds it), it warns and moves
# on instead of failing the whole deploy.
install-plugin:
	@$(MAKE) --no-print-directory fetch-plugin \
	  FETCH_PLUGIN=smooth-movement FETCH_REPO=$(REPO) FETCH_RELEASE=$(RELEASE) FETCH_ENABLE=1 FETCH_OPTIONAL=0 \
	  FETCH_BUILD=build
	$(MAKE) --no-print-directory fetch-plugin \
	  FETCH_PLUGIN=ssaudio FETCH_REPO=$(SSAUDIO_REPO) FETCH_RELEASE=latest FETCH_ENABLE=0 FETCH_OPTIONAL=1 \
	  FETCH_BUILD=build-ssaudio

# Compile BOTH plugins from source and install them -- no downloads, no version guessing.
# This is what fetch-plugin falls back to; run it directly when you want the local source shipped
# whatever a release says (a fork fix that is not upstream yet, a DFHack version nobody has
# published assets for, an unsupported platform).
build-plugins:
	@$(MAKE) --no-print-directory build
	$(MAKE) --no-print-directory build-ssaudio

# The same deploy as `install`, with both plugins ALWAYS compiled from source.
install-from-source: install-scripts install-mods build-plugins
	@echo
	echo "All deployed, plugins built from local source. RESTART Dwarf Fortress before generating"
	echo "a world — DF scans mods/ once, at startup."

# Download one prebuilt plugin from a GitHub release and unpack it into $(DFHACK_DIR). Assets are
# named <plugin>-<ver>-dfhack-<dfver>-<platform>.zip and contain hack/... paths, so they extract
# straight over the DFHack dir. Parameters (set by install-plugin above): FETCH_PLUGIN, FETCH_REPO,
# FETCH_RELEASE ("latest" or a tag), FETCH_ENABLE (also `enable` after loading), FETCH_OPTIONAL
# (a source build that also fails = warning, not error), FETCH_BUILD (the make target that
# compiles this plugin from source).
#
# A DOWNLOAD IS ONLY EVER USED WHEN IT MATCHES THE RUNNING DFHACK. Plugins are ABI-bound to a
# DFHack version, and this used to fall back to "the newest asset" when no asset named the right
# one -- which ships a binary built against a different ABI. Every no-usable-download path now
# compiles $(FETCH_BUILD) from local source instead, which is always the right version because it
# builds against $(DFHACK_TAG).
fetch-plugin:
	@plugbin="$(PLUGDIR)/$(FETCH_PLUGIN)$(PLUGEXT)"
	# Every "no usable download" path lands here. A failed build is fatal for a required plugin
	# and a warning for an optional one; either way nothing has been written to $$plugbin yet, so
	# whatever is installed stays installed.
	build_from_source() {
	  echo "$$1"
	  echo "Compiling $(FETCH_PLUGIN) from local source instead: make $(FETCH_BUILD)"
	  if $(MAKE) --no-print-directory $(FETCH_BUILD); then exit 0; fi
	  if [ "$(FETCH_OPTIONAL)" = "1" ]; then
	    echo "warning: source build of $(FETCH_PLUGIN) failed — SKIPPING it."
	    exit 0
	  fi
	  echo "Source build of $(FETCH_PLUGIN) failed, and no usable prebuilt exists."
	  exit 1
	}
	if [ -z "$(PLATFORM)" ]; then
	  build_from_source "No prebuilt $(FETCH_PLUGIN) binary for $(UNAME_S)/$(UNAME_M) (releases ship linux-x86_64 and windows-x86_64)."
	fi
	if [ ! -d "$(PLUGDIR)" ]; then
	  echo "DFHack plugin dir not found: $(PLUGDIR)"
	  echo "Point DFHACK_DIR at your DFHack install (the folder containing hack/plugins/):"
	  echo "    make install DFHACK_DIR=/path/to/DFHack"
	  exit 1
	fi
	# Resolve the DFHack version to match against asset names. This must never come back empty:
	# an unknown version means every asset looks acceptable, which is how a wrong-ABI binary got
	# installed. When the game is not running to be asked, $(DFHACK_TAG) is the answer — it is the
	# version `make build` compiles against, so download and source build agree on what "correct"
	# means.
	dfver="$(DFHACK_VERSION)"
	if [ -z "$$dfver" ] && [ -x "$(DFRUN)" ]; then
	  # dfhack-run prefixes its output with an ANSI reset ("\e[0m53.16-r1.1"), so a ^-anchored
	  # match silently found nothing and every version looked unknown. Strip escapes, no anchor.
	  dfver="$$("$(DFRUN)" lua 'print(dfhack.getDFHackVersion())' 2>/dev/null | tr -d '\r' \
	    | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -oE '[0-9]+\.[0-9]+-r[0-9.]+' | head -1 || true)"
	  [ -n "$$dfver" ] && echo "Detected running DFHack $$dfver."
	fi
	if [ -z "$$dfver" ]; then
	  dfver="$(DFHACK_TAG)"
	  echo "DFHack version not detected (game not running); assuming the build pin, $$dfver."
	fi
	# Fetch the release metadata (public repos; GITHUB_TOKEN used only if set, to dodge rate
	# limits). "latest" lists recent releases rather than hitting /releases/latest: the newest
	# release by date may be a different plugin's (ssaudio shares this repo's release space) or a
	# rolling one without our assets, and the asset-name filter below sorts that out.
	if [ "$(FETCH_RELEASE)" = "latest" ]; then api="https://api.github.com/repos/$(FETCH_REPO)/releases?per_page=30"; \
	else api="https://api.github.com/repos/$(FETCH_REPO)/releases/tags/$(FETCH_RELEASE)"; fi
	curlargs=(-fsSL -H "Accept: application/vnd.github+json")
	[ -n "$${GITHUB_TOKEN:-}" ] && curlargs+=(-H "Authorization: Bearer $$GITHUB_TOKEN")
	echo "Querying $$api"
	json="$$(curl "$${curlargs[@]}" "$$api" || true)"
	urls="$$(printf '%s' "$$json" | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' | sed -E 's/.*"(https[^"]+)".*/\1/' || true)"
	# Candidates = this plugin's archives for this platform, newest release first (the API's
	# order); narrow by DFHack version when we know it.
	cands="$$(printf '%s\n' "$$urls" | grep -E "/$(FETCH_PLUGIN)-[^/]*$(PLATFORM)\.(zip|tar\.gz)$$" || true)"
	if [ -n "$$cands" ]; then
	  esc="$$(printf '%s' "$$dfver" | sed 's/\./\\./g')"
	  filtered="$$(printf '%s\n' "$$cands" | grep -E "dfhack-?$${esc}[.-]" || true)"
	  if [ -n "$$filtered" ]; then cands="$$filtered"; \
	  else build_from_source "No $(FETCH_PLUGIN) asset built against DFHack $$dfver in $(FETCH_REPO) (a release for another DFHack version is the wrong ABI, not a substitute)."; fi
	fi
	asset="$$(printf '%s\n' "$$cands" | head -1)"
	if [ -z "$$asset" ]; then
	  echo "No $(PLATFORM) asset for $(FETCH_PLUGIN) in the $(FETCH_RELEASE) release(s) of $(FETCH_REPO)."
	  [ -n "$$urls" ] && { echo "Available assets:"; printf '%s\n' "$$urls" | sed -E 's#.*/##'; }
	  if [ "$(FETCH_PLUGIN)" = "ssaudio" ]; then
	    echo "  (publish one by pushing a tag: git tag ssaudio-v1.0.0 && git push origin ssaudio-v1.0.0;"
	    echo "   CI builds linux+windows — see .github/workflows/ssaudio-release.yml)"
	  fi
	  build_from_source "No prebuilt to install."
	fi
	echo "Selected asset: $${asset##*/}"
	# Download, verify checksum when one is published, extract into the DFHack dir.
	tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT
	pkg="$$tmp/$${asset##*/}"
	curl -fSL --progress-bar -o "$$pkg" "$$asset"
	if curl -fsSL -o "$$pkg.sha256" "$${asset}.sha256"; then
	  exp="$$(awk '{print $$1}' "$$pkg.sha256")"
	  act="$$(sha256sum "$$pkg" | awk '{print $$1}')"
	  if [ "$$exp" != "$$act" ]; then echo "CHECKSUM MISMATCH: got $$act, expected $$exp"; exit 1; fi
	  echo "Checksum OK ($$act)."
	else
	  echo "warning: no .sha256 published for this asset; skipping checksum verification."
	fi
	mkdir -p "$$tmp/x"
	case "$$pkg" in
	  *.zip)
	    # Git Bash ships no unzip; Windows' own Expand-Archive covers that case.
	    if command -v unzip >/dev/null 2>&1; then unzip -oq "$$pkg" -d "$$tmp/x"
	    elif command -v powershell.exe >/dev/null 2>&1; then
	      powershell.exe -NoProfile -Command "Expand-Archive -Force '$$(cygpath -w "$$pkg")' '$$(cygpath -w "$$tmp/x")'"
	    else tar -C "$$tmp/x" -xf "$$pkg"; fi ;;
	  *) tar -C "$$tmp/x" -xzf "$$pkg" ;;
	esac
	got="$$tmp/x/hack/plugins/$(FETCH_PLUGIN)$(PLUGEXT)"
	if [ ! -f "$$got" ]; then echo "Archive did not contain hack/plugins/$(FETCH_PLUGIN)$(PLUGEXT)"; exit 1; fi
	# smooth-movement: upstream's prebuilt DEADLOCKS DF. plugin_enable waits for the render
	# thread, but every `enable smooth-movement` from a script (onMapLoad.init ->
	# fort/magnus-scripts apply) runs on the simulation thread, which is holding the frame the
	# render thread is waiting to start -- DF wedges on the way into a fort, threads in
	# futex_wait, no error anywhere. The submodule carries the fix (a core-suspended inline
	# path); until it is upstream and released, a fetched asset that lacks it must not land on
	# top of a locally built one. The fix is the only thing in the plugin that calls
	# Core::isSuspended, so the symbol is the marker.
	# `nm | grep -q` would lie here: grep -q exits on the first match, nm dies of SIGPIPE, and
	# under `set -o pipefail` a FOUND symbol reports failure. Match on a captured string instead.
	if [ "$(FETCH_PLUGIN)" = "smooth-movement" ] && command -v nm >/dev/null 2>&1; then
	  fixsym="_ZN6DFHack4Core11isSuspendedEv"
	  newsyms="$$(nm -D --undefined-only "$$got" 2>/dev/null || true)"
	  case "$$newsyms" in
	    *"$$fixsym"*) ;;
	    *) build_from_source "REFUSING $(FETCH_REPO)'s smooth-movement asset: it lacks the core-suspended deadlock fix and will hang DF on fort load." ;;
	  esac
	fi
	# Publish the binary by ATOMIC RENAME, never by extracting/cp'ing onto the live path: if DF
	# has the old .so mapped, overwriting its inode in place crashes the game (hit twice; same
	# rule as `make build`). The staging copy lives in PLUGDIR so the rename stays same-fs.
	staged="$$plugbin.new.$$$$"
	cp "$$got" "$$staged"
	mv -f "$$staged" "$$plugbin"
	# Any lua companions ride along under hack/lua/; pure lua, safe to copy in place.
	if [ -d "$$tmp/x/hack/lua" ]; then
	  mkdir -p "$(DFHACK_DIR)/hack/lua"
	  cp -r "$$tmp/x/hack/lua/." "$(DFHACK_DIR)/hack/lua/"
	fi
	echo "Installed: $$plugbin"
	# If DF is running, load (and for FETCH_ENABLE plugins, enable) it right away; otherwise it
	# loads on next launch.
	if [ -x "$(DFRUN)" ] && "$(DFRUN)" lua 'print(1)' >/dev/null 2>&1; then
	  "$(DFRUN)" load $(FETCH_PLUGIN) >/dev/null 2>&1 || true
	  if [ "$(FETCH_ENABLE)" = "1" ]; then "$(DFRUN)" enable $(FETCH_PLUGIN) || true; fi
	  echo "Loaded in the running game."
	else
	  echo "Start Dwarf Fortress to load it. 'magnus-scripts' enables smooth-movement automatically,"
	  echo "or run 'make enable' while the game is running."
	fi

# ssaudio -- the first-party audio plugin (source in plugins/ssaudio), used by fort/super-saiyan.
# Same machinery as `build`, pointed at this repo's own source instead of the submodule.
build-ssaudio:
	$(MAKE) build PLUGIN=ssaudio PLUGIN_SRC=$(ROOT)/plugins/ssaudio PLUGIN_LINK=ssaudio PLUGIN_SUBMODULE=

# Compile the plugin from the submodule source against a local DFHack source tree, then install.
# The tree is cloned (shallow, tag $(DFHACK_TAG), with submodules) into build/dfhack on first run;
# later runs reuse it. ABI rule: $(DFHACK_TAG) must match the installed DFHack version.
build:
	@if [ ! -f "$(PLUGIN_SRC)/CMakeLists.txt" ]; then
	  if [ -z "$(PLUGIN_SUBMODULE)" ]; then
	    echo "No source at $(PLUGIN_SRC)"; exit 1
	  fi
	  echo "Initializing the plugin submodule..."
	  git -C "$(ROOT)" submodule update --init "$(PLUGIN_SUBMODULE)"
	fi
	if [ ! -f "$(DFHACK_SRC)/CMakeLists.txt" ]; then
	  echo "Cloning the DFHack $(DFHACK_TAG) source tree (one-time, ~200MB)..."
	  git clone --depth 1 --branch "$(DFHACK_TAG)" --recurse-submodules --shallow-submodules -j8 \
	    https://github.com/DFHack/dfhack "$(DFHACK_SRC)"
	fi
	# DFHack's codegen needs perl XML::LibXSLT; build it locally (no root) if the system lacks it.
	export PERL5LIB="$(PERL5_LOCAL)/lib/perl5$${PERL5LIB:+:$$PERL5LIB}"
	if ! perl -MXML::LibXSLT -e 1 2>/dev/null; then
	  echo "Building perl XML::LibXSLT locally into build/perl5 (needs libxslt headers)..."
	  mkdir -p "$(BUILDDIR)/perl5-src"
	  cd "$(BUILDDIR)/perl5-src"
	  [ -f libxslt.tar.gz ] || curl -fsSL -o libxslt.tar.gz \
	    "https://cpan.metacpan.org/authors/id/S/SH/SHLOMIF/XML-LibXSLT-2.003000.tar.gz"
	  tar xzf libxslt.tar.gz && cd XML-LibXSLT-*
	  perl Makefile.PL INSTALL_BASE="$(PERL5_LOCAL)" >/dev/null && make -j4 >/dev/null && make install >/dev/null
	  perl -MXML::LibXSLT -e 1 || { echo "local XML::LibXSLT build failed"; exit 1; }
	fi
	# Wire the plugin into the tree as an external plugin (symlink -> always builds current source).
	mkdir -p "$(DFHACK_SRC)/plugins/external"
	ln -sfn "$(PLUGIN_SRC)" "$(DFHACK_SRC)/plugins/external/$(PLUGIN_LINK)"
	grep -qs 'add_subdirectory($(PLUGIN_LINK))' "$(DFHACK_SRC)/plugins/external/CMakeLists.txt" || \
	  echo 'add_subdirectory($(PLUGIN_LINK))' >> "$(DFHACK_SRC)/plugins/external/CMakeLists.txt"
	if [ ! -f "$(CMAKE_BUILD)/CMakeCache.txt" ]; then
	  # -Wno-error goes in the per-config flags: they land AFTER DFHack's hardcoded -Werror on the
	  # compile line, neutralizing it (newer gcc releases add warnings the pinned tree predates).
	  # DFHack hard-refuses GCC 16+ (its CMakeLists check_gcc), so the compiler is pinned rather
	  # than left to /usr/bin/cc. Changing it needs a fresh build dir: the cache bakes it in.
	  cmake -S "$(DFHACK_SRC)" -B "$(CMAKE_BUILD)" -G Ninja \
	    -DCMAKE_BUILD_TYPE=Release -DBUILD_DOCS=OFF -DBUILD_TESTS=OFF \
	    -DCMAKE_C_COMPILER="$(CC_PIN)" -DCMAKE_CXX_COMPILER="$(CXX_PIN)" \
	    -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG -Wno-error" \
	    -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG -Wno-error"
	fi
	cmake --build "$(CMAKE_BUILD)" --target $(PLUGIN) -j"$(JOBS)"
	built="$$(find "$(CMAKE_BUILD)" -name '$(PLUGIN).plug.so' | head -1)"
	[ -n "$$built" ] || { echo "build produced no $(PLUGIN).plug.so"; exit 1; }
	# Swap the binary in by ATOMIC RENAME, never `cp` onto the live path: cp truncates and
	# rewrites the existing inode, and if DF has that .so mapped it is executing the bytes being
	# overwritten -- an instant crash (hit twice). A rename leaves the old inode intact for the
	# running process and publishes the new file for the next load. Do NOT disable/unload first
	# either: dlclose races DF's render thread. A RESTART picks up the new code.
	tmp="$(SO).new.$$$$"
	cp "$$built" "$$tmp"
	mv -f "$$tmp" "$(SO)"
	echo "Installed freshly-built plugin: $(SO)"
	# The Lua companion, if the plugin has one. Without it `require('plugins.<name>')` fails
	# even though the plugin loaded and `plug` lists it: DFHack resolves plugins.<name> to a
	# real file under hack/lua/plugins/, and mkmodule inside that file is what binds the
	# exported C++ functions. Pure Lua, so unlike the .so this takes effect immediately.
	if [ -d "$(PLUGIN_SRC)/lua" ]; then
	  install -Dm644 "$(PLUGIN_SRC)/lua/"*.lua -t "$(DFHACK_DIR)/hack/lua/plugins/"
	  echo "Installed plugin Lua: $(DFHACK_DIR)/hack/lua/plugins/"
	fi
	echo "RESTART Dwarf Fortress now (or: dfhack-run load $(PLUGIN) && dfhack-run enable $(PLUGIN)"
	echo "for a hot reload, then verify with 'make status')."

enable:
	@"$(DFRUN)" load $(PLUGIN) >/dev/null 2>&1 || true
	"$(DFRUN)" enable $(PLUGIN)

disable:
	@"$(DFRUN)" disable $(PLUGIN)

status:
	@"$(DFRUN)" $(PLUGIN) 2>/dev/null || { \
	  echo "Could not query the plugin (is Dwarf Fortress running?). Installed binary:"; \
	  ls -l "$(SO)" 2>/dev/null || echo "  (not installed — run 'make install')"; }

uninstall:
	@rm -fv "$(SO)"

# Which scripts lack a README section, and which sections lack a demo image.
# Sections live in *_MODE_FEATURES.md as "### **`prefix/name`**" headings; an image is any
# "![...](...)" line inside the section. magnus-scripts is documented in README-HEADER.md.
docs-todo:
	@bt=$$(printf '\140'); miss=0; noimg=0
	for f in dfhack/fort/*.lua dfhack/adv/*.lua dfhack/embark/*.lua; do
	  name=$${f#dfhack/}; name=$${name%.lua}
	  case $$name in fort/*) doc=FORTRESS_MODE_FEATURES.md ;; *) doc=ADVENTURE_MODE_FEATURES.md ;; esac
	  if grep -q "### \*\*$${bt}$$name$${bt}" "$$doc"; then
	    if ! awk -v pat="$${bt}$$name$${bt}" \
	        '/^### /{if(s)exit; if(index($$0,pat))s=1; next} s&&/^!\[/{found=1} END{exit found?0:1}' "$$doc"; then
	      echo "NO IMAGE:  $$name  ($$doc)"; noimg=$$((noimg+1))
	    fi
	  elif grep -q "$$name" README-HEADER.md; then :
	  else
	    echo "NO DOCS:   $$name  (add to $$doc)"; miss=$$((miss+1))
	  fi
	done
	echo ""
	echo "$$miss script(s) undocumented, $$noimg documented without an image."
	echo "(edit the *_MODE_FEATURES.md part files, put images in demos/, then run 'make readme')"

# Concatenate the part files into README.md. Written to a temp file and moved into place, so a
# missing part cannot leave a half-built README behind.
readme:
	@missing=""
	for f in $(README_PARTS); do
	  [ -f "$$f" ] || missing="$$missing $$f"
	done
	if [ -n "$$missing" ]; then
	  echo "make readme: missing part file(s):$$missing"
	  exit 1
	fi
	tmp="$$(mktemp README.md.XXXXXX)"
	trap 'rm -f "$$tmp"' EXIT
	cat $(README_HEADER) >> "$$tmp"
	printf '\n' >> "$$tmp"
	for f in $(README_SECTIONS); do
	  # <summary> holds the h1 text; the blank line after it is REQUIRED or GitHub renders the
	  # body as literal text instead of markdown. No `open` attribute => collapsed by default.
	  awk '
	    !opened && /^# / {
	      print "<details>"
	      printf "<summary><h1>%s</h1></summary>\n\n", substr($$0, 3)
	      opened = 1
	      next
	    }
	    { print }
	    END {
	      if (!opened) { print "AWK_NO_H1" > "/dev/stderr"; exit 1 }
	      print "</details>"
	    }
	  ' "$$f" >> "$$tmp" || { echo "make readme: $$f has no leading '# h1' to fold into <details>"; exit 1; }
	  printf '\n' >> "$$tmp"
	done
	mv "$$tmp"  README.md
	trap - EXIT
	echo "README.md composed from $(words $(README_PARTS)) parts:"
	printf '  %s (verbatim)\n' $(README_HEADER)
	for f in $(README_SECTIONS); do
	  printf '  %s -> <details> "%s"\n' "$$f" "$$(sed -n 's/^# //p;/^# /q' "$$f" | head -1)"
	done
