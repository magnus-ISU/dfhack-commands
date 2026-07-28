# Makefile — install the df-smooth-movement DFHack plugin.
#
# The submodule under other-authors/df-smooth-movement ships SOURCE ONLY, and that source only
# builds inside a full DFHack source tree (its CMakeLists uses DFHack's dfhack_plugin() macro —
# see the submodule README "Build" section). So there is no standalone source build here.
#
# `make install` downloads the prebuilt plugin binary matching your platform and DFHack version
# from the upstream GitHub release, verifies its SHA-256, and extracts it into DFHack's plugin
# directory. The plugin is auto-enabled by `magnus-scripts lovely`; `make enable` turns it on now.
#
# Common use:
#     make install                              # auto-detect everything
#     make install DFHACK_DIR=/path/to/DFHack   # if your DFHack lives elsewhere
#     make install DFHACK_VERSION=53.15-r2      # pin the release asset explicitly
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

.DEFAULT_GOAL := help
.PHONY: help install enable disable status uninstall

help:
	@echo "df-smooth-movement plugin — make targets:"
	echo "  make install    download + checksum-verify the prebuilt plugin, install into DFHack"
	echo "  make enable     load + enable it now (Dwarf Fortress must be running)"
	echo "  make disable    disable it now"
	echo "  make status     show the plugin's status / installed binary"
	echo "  make uninstall  remove the installed plugin binary"
	echo
	echo "Variables (override on the command line, e.g. make install DFHACK_DIR=...):"
	echo "  DFHACK_DIR      = $(DFHACK_DIR)"
	echo "  RELEASE         = $(RELEASE)"
	echo "  DFHACK_VERSION  = $(if $(DFHACK_VERSION),$(DFHACK_VERSION),(auto-detect))"
	echo "  REPO            = $(REPO)"

install:
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
	  echo "Start Dwarf Fortress to load it. 'magnus-scripts lovely' enables it automatically,"
	  echo "or run 'make enable' while the game is running."
	fi

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
