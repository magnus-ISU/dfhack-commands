# Makefile — deploy this repo into Dwarf Fortress + DFHack.
#
# `make install` ships EVERYTHING this repo produces, in this order:
#
#   1. install-scripts  dfhack/ -> $DF/dfhack-config/scripts/   (hot-reloads a running DF)
#   2. install-mods     content-mods/high-adventure/* -> $DF/mods/, then prune-snapshots
#   3. install-plugin   download + verify the df-smooth-movement binary into DFHack
#
# The local steps run FIRST so a network failure in step 3 cannot cost you a mod deploy.
#
#   make install                              # everything, auto-detect paths
#   make install-mods                         # mods + snapshot prune only
#   make mods-status                          # repo vs deployed vs snapshot, no changes
#   make install DFHACK_DIR=/path/to/DFHack   # if your DFHack lives elsewhere
#   make build                                # compile the plugin from submodule SOURCE instead
#
# THINGS THAT WILL BITE YOU (see instructions.md for the long version):
#
# * DELETING OLD VERSIONS IS THE POINT. `prune-snapshots` runs `rm -rf` on every snapshot under
#   $B12/data/installed_mods whose version is below the one now in $DF/mods. This repo keeps
#   exactly ONE version of each mod alive, and that BREAKS ANY SAVE generated against an older
#   one. Old worlds are expendable here; a picker full of stale versions is not worth them.
# * DF scans $DF/mods exactly ONCE, at startup. Deploying while the game runs is invisible to it
#   — RESTART DF before generating a world, or worldgen silently uses the old raws.
# * The `high-adventure` bundle is GENERATED from the sibling ha-* mods and never updates itself.
#   install-mods refuses to deploy a bundle that has drifted from its members, and tells you to
#   bump the version in build-high-adventure.py and re-run it.
#
# Re-run after every DFHack update (plugins are ABI-specific to a DFHack version).

REPO           ?= notliad/df-smooth-movement
PLUGIN         ?= smooth-movement
# The DFHack install directory (the folder that contains hack/plugins/). Override if yours differs;
# on some setups DFHack lives inside the Dwarf Fortress folder instead of its own.
DFHACK_DIR     ?= $(HOME)/.local/share/Steam/steamapps/common/DFHack
# Which release to pull from: "latest" or a tag like v0.2.0.
RELEASE        ?= latest
# DFHack version the asset must match, e.g. 53.15-r2. Empty = auto-detect via dfhack-run when the
# game is running, else fall back to the sole platform asset in the release.
DFHACK_VERSION ?=

SHELL       := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

DFRUN   := $(DFHACK_DIR)/dfhack-run
PLUGDIR := $(DFHACK_DIR)/hack/plugins
SO      := $(PLUGDIR)/$(PLUGIN).plug.so

# --- source build (make build) ---
# Everything lives under build/ (gitignored): the DFHack source tree, its cmake build dir, and a
# locally-built XML::LibXSLT (DFHack's codegen needs it; built from CPAN when the system perl
# lacks it, so no root is required).
ROOT        := $(abspath .)
BUILDDIR    := $(ROOT)/build
DFHACK_SRC  := $(BUILDDIR)/dfhack
CMAKE_BUILD := $(DFHACK_SRC)/build-rel
PERL5_LOCAL := $(BUILDDIR)/perl5
PLUGIN_SRC  := $(ROOT)/other-authors/df-smooth-movement
# Git tag of the DFHack source to build against. Must match the installed DFHack (ABI).
DFHACK_TAG  ?= 53.16-r1
# DFHack refuses to configure under GCC 16+. Prefer a versioned gcc-15 when the default is newer.
CC_PIN      ?= $(shell if [ "$$(cc -dumpversion | cut -d. -f1)" -ge 16 ] && command -v gcc-15 >/dev/null; then command -v gcc-15; else command -v cc; fi)
CXX_PIN     ?= $(shell if [ "$$(c++ -dumpversion | cut -d. -f1)" -ge 16 ] && command -v g++-15 >/dev/null; then command -v g++-15; else command -v c++; fi)
JOBS        ?= $(shell nproc)

# --- README composition (make readme) ---
# README.md is GENERATED. Edit the parts, never README.md.
# BROKEN_FEATURES.md is deliberately NOT included: the README advertises what works.
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
DF_DIR      ?= $(HOME)/.local/share/Steam/steamapps/common/Dwarf Fortress
B12_DIR     ?= $(HOME)/.local/share/Bay 12 Games/Dwarf Fortress
MODS_SRC    := $(ROOT)/content-mods/high-adventure
SCRIPTS_SRC := $(ROOT)/dfhack
BUNDLE      := high-adventure
# subtrees the bundle build merges verbatim from each member; used to detect a drifted bundle
MERGED_SUBDIRS := objects graphics scripts_modactive

.DEFAULT_GOAL := help
# Deploy order matters (mods before the network step; prune after the deploy that defines
# "current"), so never let -j interleave these.
.NOTPARALLEL:
.PHONY: help install install-scripts install-mods check-bundle prune-snapshots mods-status \
        install-plugin build enable disable status uninstall readme

help:
	@echo "dfhack-commands — make targets:"
	echo
	echo "Deploy the repo into the game:"
	echo "  make install          EVERYTHING: scripts, then mods (+ prune), then the plugin"
	echo "  make install-scripts  dfhack/ -> DF's script path; hot-reloads a running DF"
	echo "  make install-mods     content mods -> \$$DF/mods, then prune-snapshots"
	echo "  make prune-snapshots  rm -rf per-world snapshots older than what is deployed."
	echo "                        THIS BREAKS SAVES made against those versions, by design."
	echo "  make mods-status      repo vs deployed vs snapshot versions; changes nothing"
	echo
	echo "df-smooth-movement plugin:"
	echo "  make install-plugin  download + checksum-verify the prebuilt plugin, install into DFHack"
	echo "  make build      compile the plugin from the submodule source (clones the DFHack"
	echo "                  source tree into build/ on first run) and install it. Restart DF after."
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
install: install-scripts install-mods install-plugin
	@echo
	echo "All deployed. RESTART Dwarf Fortress before generating a world — DF scans mods/ once,"
	echo "at startup, so raws deployed into a running game are invisible to worldgen."

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
# Deploy every mod that has an info.txt (art/ and the build script are skipped), each via an
# atomic copy-then-swap so a half-written mod is never visible to a running game.
install-mods: check-bundle
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
	# -C: this recipe has cd'd into the mod source dir, and the Makefile is not there.
	$(MAKE) -C "$(ROOT)" --no-print-directory prune-snapshots

# The bundle is generated, so it silently rots whenever a member changes. Two independent ways it
# rots, both fatal here: its merged files no longer match the members (never rebuilt), or its
# description advertises member versions that have moved on (rebuilt before the members bumped).
check-bundle:
	@cd "$(MODS_SRC)"
	field() { sed -n "s/^\[$$2:\(.*\)\]/\1/p" "$$1/info.txt" | head -1 | tr -d '\r'; }
	if [ ! -f "$(BUNDLE)/info.txt" ]; then
	  echo "No generated bundle at $(MODS_SRC)/$(BUNDLE) — run: python3 build-high-adventure.py"
	  exit 1
	fi
	desc="$$(field "$(BUNDLE)" DESCRIPTION)"
	stale=""
	for m in */; do
	  m="$${m%/}"
	  [ -f "$$m/info.txt" ] || continue
	  [ "$$m" = "$(BUNDLE)" ] && continue
	  nm="$$(field "$$m" NAME)"; vr="$$(field "$$m" DISPLAYED_VERSION)"
	  case "$$desc" in *"$$nm $$vr"*) ;; *) stale="$$stale $$m($$vr:not-in-bundle-description)" ;; esac
	  for sub in $(MERGED_SUBDIRS); do
	    [ -d "$$m/$$sub" ] || continue
	    # every member file must appear byte-identical in the bundle; bundle-only files are the
	    # other members' contributions and are expected
	    d="$$(diff -rq "$$m/$$sub" "$(BUNDLE)/$$sub" 2>/dev/null | grep -v "^Only in $(BUNDLE)/" || true)"
	    [ -n "$$d" ] && stale="$$stale $$m/$$sub"
	  done
	done
	if [ -n "$$stale" ]; then
	  echo "The generated $(BUNDLE) bundle has drifted from its members:"
	  for s in $$stale; do echo "    $$s"; done
	  echo
	  echo "Bump NUMERIC_VERSION/DISPLAYED_VERSION at the top of build-high-adventure.py, then:"
	  echo "    (cd $(MODS_SRC) && python3 build-high-adventure.py)"
	  echo "Deploying a stale bundle ships old raws under a version DF thinks it already has."
	  exit 1
	fi
	echo "bundle $$(field "$(BUNDLE)" DISPLAYED_VERSION) is in sync with its members"

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
	  if pgrep -x dwarfort >/dev/null 2>&1; then
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

install-plugin:
	@platform=""
	case "$(UNAME_S)/$(UNAME_M)" in
	  Linux/x86_64) platform="linux-x86_64" ;;
	  *)
	    echo "No prebuilt binary for $(UNAME_S)/$(UNAME_M) (upstream ships linux-x86_64 and windows-x86_64)."
	    echo "Build from source inside a DFHack tree — see other-authors/df-smooth-movement/README.md."
	    exit 1 ;;
	esac
	if [ ! -d "$(PLUGDIR)" ]; then
	  echo "DFHack plugin dir not found: $(PLUGDIR)"
	  echo "Point DFHACK_DIR at your DFHack install (the folder containing hack/plugins/):"
	  echo "    make install DFHACK_DIR=/path/to/DFHack"
	  exit 1
	fi
	# Resolve the DFHack version to match against asset names.
	dfver="$(DFHACK_VERSION)"
	if [ -z "$$dfver" ] && [ -x "$(DFRUN)" ]; then
	  dfver="$$("$(DFRUN)" lua 'print(dfhack.getDFHackVersion())' 2>/dev/null | tr -d '\r' | grep -oE '^[0-9]+\.[0-9]+-r[0-9]+' || true)"
	  [ -n "$$dfver" ] && echo "Detected running DFHack $$dfver."
	fi
	# Fetch the release metadata (public repo; GITHUB_TOKEN used only if set, to dodge rate limits).
	if [ "$(RELEASE)" = "latest" ]; then api="https://api.github.com/repos/$(REPO)/releases/latest"; \
	else api="https://api.github.com/repos/$(REPO)/releases/tags/$(RELEASE)"; fi
	curlargs=(-fsSL -H "Accept: application/vnd.github+json")
	[ -n "$${GITHUB_TOKEN:-}" ] && curlargs+=(-H "Authorization: Bearer $$GITHUB_TOKEN")
	echo "Querying $$api"
	json="$$(curl "$${curlargs[@]}" "$$api")"
	urls="$$(printf '%s' "$$json" | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' | sed -E 's/.*"(https[^"]+)".*/\1/')"
	# Candidate = the platform tarball(s); narrow by DFHack version when we know it.
	cands="$$(printf '%s\n' "$$urls" | grep -E "$${platform}\.tar\.gz$$" || true)"
	if [ -n "$$dfver" ]; then
	  filtered="$$(printf '%s\n' "$$cands" | grep -F "dfhack$${dfver}-" || true)"
	  if [ -n "$$filtered" ]; then cands="$$filtered"; \
	  else echo "warning: release has no asset for DFHack $$dfver; using the available $$platform asset instead."; fi
	fi
	n="$$(printf '%s\n' "$$cands" | grep -c . || true)"
	if [ "$$n" -eq 0 ]; then
	  echo "No $$platform asset in the $(RELEASE) release. Available assets:"
	  printf '%s\n' "$$urls" | sed -E 's#.*/##'
	  exit 1
	fi
	if [ "$$n" -gt 1 ]; then
	  echo "Multiple $$platform assets — pick one with DFHACK_VERSION=<ver>:"
	  printf '  %s\n' $$(printf '%s\n' "$$cands" | sed -E 's#.*/##')
	  exit 1
	fi
	asset="$$cands"
	echo "Selected asset: $${asset##*/}"
	# Download, verify checksum, extract into the DFHack dir.
	tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT
	curl -fSL --progress-bar -o "$$tmp/p.tar.gz" "$$asset"
	if curl -fsSL -o "$$tmp/p.sha256" "$${asset}.sha256"; then
	  exp="$$(awk '{print $$1}' "$$tmp/p.sha256")"
	  act="$$(sha256sum "$$tmp/p.tar.gz" | awk '{print $$1}')"
	  if [ "$$exp" != "$$act" ]; then echo "CHECKSUM MISMATCH: got $$act, expected $$exp"; exit 1; fi
	  echo "Checksum OK ($$act)."
	else
	  echo "warning: no .sha256 published for this asset; skipping checksum verification."
	fi
	tar -C "$(DFHACK_DIR)" -xzf "$$tmp/p.tar.gz"
	if [ ! -f "$(SO)" ]; then echo "Extraction did not produce $(SO)"; exit 1; fi
	echo "Installed: $(SO)"
	# If DF is running, load+enable it right away; otherwise it loads on next launch.
	if [ -x "$(DFRUN)" ] && "$(DFRUN)" lua 'print(1)' >/dev/null 2>&1; then
	  "$(DFRUN)" load $(PLUGIN) >/dev/null 2>&1 || true
	  "$(DFRUN)" enable $(PLUGIN) || true
	  echo "Loaded and enabled in the running game."
	else
	  echo "Start Dwarf Fortress to load it. 'magnus-scripts' enables it automatically,"
	  echo "or run 'make enable' while the game is running."
	fi

# Compile the plugin from the submodule source against a local DFHack source tree, then install.
# The tree is cloned (shallow, tag $(DFHACK_TAG), with submodules) into build/dfhack on first run;
# later runs reuse it. ABI rule: $(DFHACK_TAG) must match the installed DFHack version.
build:
	@if [ ! -f "$(PLUGIN_SRC)/CMakeLists.txt" ]; then
	  echo "Initializing the plugin submodule..."
	  git -C "$(ROOT)" submodule update --init other-authors/df-smooth-movement
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
	ln -sfn "$(PLUGIN_SRC)" "$(DFHACK_SRC)/plugins/external/df-smooth-movement"
	grep -qs 'add_subdirectory(df-smooth-movement)' "$(DFHACK_SRC)/plugins/external/CMakeLists.txt" || \
	  echo 'add_subdirectory(df-smooth-movement)' >> "$(DFHACK_SRC)/plugins/external/CMakeLists.txt"
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
