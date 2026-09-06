# aeb Makefile
#
# `aeb` itself is a thin bash trampoline that lazy-builds the Aether
# tools under tools/ on first use. This Makefile pre-builds those
# binaries and installs a copy of the runtime tree to $PREFIX/share/aeb,
# with a small wrapper at $PREFIX/bin/aeb that pins AEB_HOME at the
# installed copy (decoupling installs from the dev tree).

AETHER ?= ae
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
SHAREDIR ?= $(PREFIX)/share/aeb

TOOLS := tools/aeb-main tools/aeb-link tools/aeb-graph tools/affected-targets tools/gcheckout tools/gen-orchestrator tools/file-to-label
INSTALL_TOOLS := tools/aeb-main tools/aeb-link tools/aeb-graph tools/affected-targets tools/gcheckout

# --lib tools makes the shared `aeblabel` module (tools/aeblabel/
# module.ae) importable by the tools that consume it (aeb-link,
# gen-orchestrator, file-to-label). --lib lib makes the SDK modules
# (build, provision, c, ...) importable by the tools that consume THEM
# (aeb-main imports build + provision; aeb-link/aeb-driver import build).
# Both are harmless for tools that don't use them — a flat tools/*.ae
# file is not a `name/module.ae` module, so an unused search root never
# picks one up by accident. Pattern-rule builds (the `build` target) thus
# get both, matching what the install loop's per-tool case already does.
AEFLAGS ?= --lib tools --lib lib

# Source-content hash of the aeb tree — a stable identity surfaced by
# `aeb --version` (AEB_STAMP) and the stale-install check. `git
# ls-files` covers every tracked source under aeb/lib/tools and
# excludes the gitignored prebuilt binaries; `find` is the
# outside-a-checkout fallback. Content, not mtime: a revert restores
# the prior hash, identical sources always hash the same.
SRCHASH_CMD = { git ls-files aeb lib tools 2>/dev/null | grep . || find aeb lib tools -type f; } | LC_ALL=C sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-12

.PHONY: all build install uninstall clean check-install

all: build

build: $(TOOLS)
	@if [ -f "$(SHAREDIR)/AEB_STAMP" ]; then \
	    dev=$$( $(SRCHASH_CMD) ); \
	    inst=$$(awk '$$1=="src"{print $$2}' "$(SHAREDIR)/AEB_STAMP"); \
	    [ "$$dev" = "$$inst" ] || echo "note: installed aeb at $(SHAREDIR) is stale vs this tree ($$inst -> $$dev) — run 'make install'"; \
	fi

# One pattern rule for every tool — each tools/<name> is built from
# tools/<name>.ae. Replaces six near-identical explicit rules.
tools/%: tools/%.ae
	$(AETHER) build $< -o $@ $(AEFLAGS)

# install — copy the runtime tree to $(SHAREDIR) and drop a wrapper
# at $(BINDIR)/aeb that pins AEB_HOME at the installed copy. The
# wrapper is regenerated each install so PREFIX changes are picked up.
install: $(INSTALL_TOOLS)
	@mkdir -p $(BINDIR) $(SHAREDIR)
	@# Force-rebuild every tools/*.ae binary before copying. The lazy-
	@# built tools (topo-sort, extract-deps, scan-ae-files, …) are
	@# gitignored binaries not in $(INSTALL_TOOLS); the pattern rule
	@# won't refresh them because their .ae source is older than the
	@# binary — but the binary can still be stale vs the *toolchain*
	@# (a binary built under an older aetherc with since-fixed codegen
	@# bugs). Shipping such a stale binary silently breaks the install
	@# (a stale topo-sort produced a wrong DAG order → cascading build
	@# failures). Unconditional rebuild here guarantees the shipped
	@# binaries match the current toolchain.
	@# NB: tools/aeb-agent.ae is deliberately NOT built here. The remote
	@# build agent is an opt-in capability a human installs as a second,
	@# deliberate step (it's a network-listening server, not core build
	@# machinery) — and `make` must not recurse into `aeb` to build it
	@# (that would couple the install to a freshly-built aeb being
	@# correct). The source ships in $(SHAREDIR)/tools; build it with
	@#   aeb tools/agentbuild/.build.ae         (dogfood, once aeb works)
	@# or  ae build tools/aeb-agent.ae --lib lib -o <bin>
	@# Self-heal a tree poisoned by a past `sudo make install`. The prefix
	@# is per-user (~/.local), so sudo is never needed here — but if someone
	@# did it once, the rebuilt tool binaries in THIS checkout were left
	@# root-owned. A later non-sudo run then can't overwrite them and the
	@# linker dies cryptically ("ld: can't write output file: tools/aeb-cli").
	@# Removing the stale binary fixes it: `rm` needs write on the *directory*
	@# (ours), not the file — so this works as the normal user even on a
	@# root-owned file, and the loop below rebuilds it clean.
	@# ONLY reclaim files the rebuild loop below can actually regenerate —
	@# i.e. a tools/<x> that has a tools/<x>.ae source. Reclaiming anything
	@# else (notably tools/aeb-resolve.jar, a Java artifact built out-of-band
	@# by tools/resolver/.dist.ae, NOT by this Makefile) would delete it with
	@# no way to rebuild it — the jar is gitignored, so it's then gone for
	@# good and every maven/java/scala/kotlin build breaks. That is the exact
	@# "make install keeps wiping aeb-resolve.jar" bug: a non-writable jar
	@# (e.g. from a tarball/CI/prior sudo) got reclaimed but never rebuilt.
	@for bin in tools/*; do \
	    case "$$bin" in *.ae) continue;; esac; \
	    [ -f "$$bin.ae" ] || continue; \
	    [ -f "$$bin" ] && [ ! -w "$$bin" ] && { rm -f "$$bin" && echo "  reclaim $$bin (was not writable — stale from a prior sudo install?)"; }; \
	done; true
	@for src in tools/*.ae; do \
	    case "$$src" in tools/aeb-agent.ae|tools/aeb-lease.ae|tools/aeb-keygen.ae) echo "  skip    $$src (opt-in: install with the remote-agent kit)"; continue;; esac; \
	    bin="$${src%.ae}"; \
	    extra=""; \
	    case "$$src" in tools/aeb-main.ae|tools/aeb-cli.ae|tools/aeb-driver.ae|tools/aeb-remote.ae|tools/aeb-vet.ae|tools/aeb-sandbox.ae|tools/aeb-sbom.ae|tools/aeb-trace.ae) extra="--lib lib";; esac; \
	    echo "  rebuild $$bin"; \
	    $(AETHER) build "$$src" -o "$$bin" $(AEFLAGS) $$extra >/dev/null || { echo "install: failed to build $$src" >&2; exit 1; }; \
	done
	rm -f $(BINDIR)/aeb
	rm -rf $(SHAREDIR)/lib $(SHAREDIR)/tools $(SHAREDIR)/veto $(SHAREDIR)/sandbox
	cp -f aeb $(SHAREDIR)/aeb
	chmod +x $(SHAREDIR)/aeb
	cp -R lib $(SHAREDIR)/lib
	cp -R tools $(SHAREDIR)/tools
	cp -R veto $(SHAREDIR)/veto
	cp -R sandbox $(SHAREDIR)/sandbox
	@printf '%s\n' \
	    '#!/usr/bin/env bash' \
	    '# aeb wrapper — generated by aeb `make install`' \
	    'export AEB_HOME="$(SHAREDIR)"' \
	    'exec "$(SHAREDIR)/aeb" "$$@"' \
	    > $(BINDIR)/aeb
	chmod +x $(BINDIR)/aeb
	@SRCH=$$( $(SRCHASH_CMD) ); \
	 GITD=$$(git describe --always --dirty 2>/dev/null || echo unknown); \
	 VER=$$( [ -f VERSION ] && tr -d '[:space:]' < VERSION || echo 0.0.0-dev+$$SRCH ); \
	 printf 'src %s\ncommit %s\ninstalled %s\ntoolchain %s\nversion %s\n' \
	    "$$SRCH" "$$GITD" "$$(date '+%Y-%m-%d %H:%M:%S')" "$$($(AETHER) --version 2>/dev/null | head -1)" "$$VER" \
	    > $(SHAREDIR)/AEB_STAMP; \
	 echo "installed:"; \
	 echo "  wrapper:  $(BINDIR)/aeb"; \
	 echo "  runtime:  $(SHAREDIR)/"; \
	 echo "  version:  aeb $$VER (git $$GITD)"; \
	 echo "  (remote build agent + lease minter NOT installed — opt in with BOTH at once:)"; \
	 echo "        aeb tools/remote-agent/.install.ae          # → aeb-agent + aeb-lease"; \
	 echo "     (or individually: aeb tools/agent/.install.ae  /  aeb tools/lease/.install.ae)"
	@# If this ran under sudo into a PER-USER prefix, the files just landed
	@# root-owned — which then breaks the NON-sudo `aeb tools/agent/.install.ae`
	@# (it cp's into $(SHAREDIR) as the normal user → "Permission denied"). Hand
	@# the installed tree back to the invoking user. Guarded: only when actually
	@# under sudo ($$SUDO_USER set, not root) AND the prefix is under that user's
	@# home (don't touch a real system prefix like /usr/local). Group via
	@# `id -gn` so it's correct on macOS (staff) and Linux (user's own group).
	@if [ -n "$$SUDO_USER" ] && [ "$$SUDO_USER" != "root" ]; then \
	    uhome=$$(eval echo "~$$SUDO_USER"); \
	    case "$(SHAREDIR)" in \
	      "$$uhome"/*) \
	        ugrp=$$(id -gn "$$SUDO_USER" 2>/dev/null || echo "$$SUDO_USER"); \
	        chown -R "$$SUDO_USER:$$ugrp" "$(SHAREDIR)" "$(BINDIR)/aeb" 2>/dev/null && \
	          echo "  (ran under sudo → chowned $(SHAREDIR) + wrapper back to $$SUDO_USER:$$ugrp," && \
	          echo "   so the non-sudo 'aeb tools/agent/.install.ae' can write there)"; ;; \
	      *) ;; \
	    esac; \
	 fi

# NB: there is deliberately NO `make install-agent`. If aeb builds the
# agent, aeb installs it too — `make` stays out of the remote-agent path
# entirely. Build + install it with aeb:
#   aeb tools/agent/.dist.ae      # build the binary (dogfood)
#   aeb tools/agent/.install.ae   # deps .dist, places binary + wrapper (~/.local)

uninstall:
	rm -f $(BINDIR)/aeb $(BINDIR)/aeb-agent
	rm -rf $(SHAREDIR)

clean:
	rm -f $(TOOLS)

# check-install — is the installed aeb current with this source tree?
# Compares the dev tree's source-content hash against the installed
# AEB_STAMP. Catches the "accidentally running an older install"
# trap without any version-manager machinery.
check-install:
	@if [ ! -f "$(SHAREDIR)/AEB_STAMP" ]; then \
	    echo "aeb: not installed at $(SHAREDIR) — run 'make install'"; \
	else \
	    dev=$$( $(SRCHASH_CMD) ); \
	    inst=$$(awk '$$1=="src"{print $$2}' "$(SHAREDIR)/AEB_STAMP"); \
	    if [ "$$dev" = "$$inst" ]; then \
	        echo "aeb: installed tree is current (src $$inst)"; \
	    else \
	        echo "aeb: installed tree is STALE — installed src $$inst, this tree $$dev — run 'make install'"; \
	    fi; \
	fi
