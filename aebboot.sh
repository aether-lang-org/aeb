#!/usr/bin/env bash
# aebboot.sh — the ONE shared bootstrap helper. Ensures the Aether toolchain
# (`ae`) AND the aeb build runner (`aeb`) are present and recent enough, and
# provides the shared shell primitives a repo's bootstrap.sh needs. SOURCE it:
#
#     . <(curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/aebboot.sh)
#     aeb_bootstrap        # ensures ae (>= AE_PIN) THEN aeb, in the right order
#
# or call the two steps yourself if you need to interleave work:
#     ae_ensure            # ae  >= AE_PIN on PATH
#     aeb_ensure           # aeb on PATH (needs ae first)
#
# WHY ONE FILE. aeb's installer needs an `ae` to target, so any helper that
# ensures aeb must first ensure ae — the two are inseparable, and every real
# consumer (selenium, servirtium-vcr, html-sanitizer, aeo) builds through aeb
# and needs both. One self-contained file means ONE curl in every repo's
# bootstrap.sh and no "source ae first" contract to get wrong. It replaces the
# ~95 lines of toolchain-install shell copy-pasted (and DRIFTED) across those
# repos' bootstrap.sh files.
#
# BINARY-FIRST. We FAVOR precompiled release binaries over building from source:
#   * ae:  download aether-<ver>-<plat>.tar.gz from gh-releases (root layout:
#          bin/ include/ share/ lib/ -> PREFIX/). aether ships NO .sha256, so
#          the trust boundary is github-over-HTTPS. Fall back to get.sh (source
#          `make install`) if there is no matching asset / the download fails.
#   * aeb: download aeb-<plat>.tar.gz + its .sha256 from gh-releases, VERIFY the
#          checksum, then run the bundled install.sh (which just copies files —
#          "no compiler needed"). Fall back to the repo install.sh (source) if
#          no asset / download / checksum fails.
# A cold box thus skips the ~1-2 min per-tool compile. Source fallback keeps
# unusual platforms (e.g. linux-arm64 ae, which has no prebuilt asset) working.
#
# TRUST MODEL (deliberate). The aeb .sha256 is fetched from gh-releases AT
# RUNTIME and compared — it catches transit corruption, not a compromised
# release (a tamperer replacing the tarball could replace its sidecar too). We
# do NOT bake a pinned {platform -> sha256} table into this file. That was a
# considered choice: the trust boundary is github + TLS, and a hardcoded hash
# table would have to be regenerated on every pin bump (download every platform,
# hash, paste) — maintenance the runtime-sidecar model avoids. If the threat
# model ever includes a compromised github release, revisit and pin the hashes.
#
# WHERE THIS LIVES. This is the canonical home: the aeb repo root, beside
# install.sh (which it falls back to). It was pioneered in the `aeo` repo — so
# the whole loop (edit -> commit -> observe raw.githubusercontent redeploy ->
# run) stayed in one repo during bring-up — then relocated here once stable.
# Consumers curl it from the aeb-repo raw URL above; aeo's copy is retired.
#
# ---------------------------------------------------------------------------
# AEBBOOT_REV: 7
# ^ PROPAGATION SNIFF MARKER. Bumped by hand on every change. raw.github lags a
# push by up to minutes; poll the raw URL for `AEBBOOT_REV: <n>` to know your
# push redeployed. (A commit hash can't be used — a file can't contain its own
# not-yet-existing hash — so this monotonic integer is the honest stamp.)
# ---------------------------------------------------------------------------

# --- Contract (what the CALLER sets) ----------------------------------------
#   AE_PIN     FLOOR: oldest ae that can build this repo. Required for ae_ensure.
#   AE_FETCH   ae release to install when the floor is unmet (binary or source).
#              MUST be >= AE_PIN. Defaults to AE_PIN. (bare X.Y.Z or vX.Y.Z)
#   AEB_MIN    FLOOR: oldest aeb this repo's build files need. Optional (warns).
#   AEB_FETCH  aeb release to install. Defaults to AEB_MIN, else latest.
#   AETHER_REF (env) explicit ae ref. A tag installs a binary if one matches;
#              a branch/SHA forces source (no binary exists for it).
#   AEB_REF    (env) explicit aeb ref. Same tag-vs-branch behaviour.
#   PREFIX     (env) install prefix. Default $HOME/.local (no sudo). Shared.
#   AEBBOOT_NO_BINARY=1  (env) force source builds for both (skip gh-releases).
#
# Setting `set -euo pipefail` is the CALLER's job.

AEBBOOT_AETHER_GET_URL="${AEBBOOT_AETHER_GET_URL:-https://raw.githubusercontent.com/aether-lang-dev/aether/main/get.sh}"
AEBBOOT_AEB_INSTALL_URL="${AEBBOOT_AEB_INSTALL_URL:-https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh}"
AEBBOOT_AETHER_REPO="${AEBBOOT_AETHER_REPO:-aether-lang-dev/aether}"
AEBBOOT_AEB_REPO="${AEBBOOT_AEB_REPO:-aether-lang-dev/aeb}"

# --- Shared primitives ------------------------------------------------------
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# version_ge A B : true if A >= B (semver-ish, via sort -V)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# ae_version : bare X.Y.Z of the ae on PATH, or nothing.
ae_version() { ae --version 2>/dev/null | head -n1 | sed -E 's/^ae ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'; }

# aeb_version : aeb's version NORMALIZED to X.Y.Z, or nothing. aeb prints a
# TWO-component tag "aeb v0.297"; a source build reports "aeb 0.0.0-dev+<sha>".
# Normalize X.Y -> X.Y.0 so `sort -V` doesn't order 0.297 before 0.297.0 (which
# would report a correctly-pinned aeb as "too old").
aeb_version() {
    local v
    v="$(aeb --version 2>/dev/null | head -n1 | sed -E 's/^aeb v?([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
    [ -n "$v" ] || return 0
    case "$v" in *.*.*) : ;; *.*) v="$v.0" ;; esac
    printf '%s' "$v"
}

# fetch_run URL : download an installer to a temp file and run it under sh,
# inheriting the exported env. Downloading first (not `curl | sh`) means a fetch
# failure is not masked by the pipe.
fetch_run() {
    command -v curl >/dev/null 2>&1 || die "curl is required to install the toolchain (or install ae/aeb yourself and re-run)."
    local tmp rc; tmp="$(mktemp)"
    if curl -fsSL "$1" -o "$tmp"; then sh "$tmp"; rc=$?; else rc=$?; fi
    rm -f "$tmp"; return $rc
}

# aeboot_preflight_cc : a C compiler + make (needed for a SOURCE build only).
aeboot_preflight_cc() {
    command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 \
        || die "a C compiler (cc/gcc/clang) is required to build from source — install e.g. build-essential (Debian/Ubuntu) or the Xcode Command Line Tools (macOS)."
    command -v make >/dev/null 2>&1 || command -v gmake >/dev/null 2>&1 \
        || die "GNU make is required to build from source (install 'gmake' on *BSD)."
}

# aeboot_sha256 FILE : print the file's sha256 hex, or nothing (tool-agnostic).
aeboot_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# aeboot_platform : echo "os arch" normalized (os in linux/macos/freebsd/windows,
# arch in x86_64/arm64), or nothing if unrecognized.
aeboot_platform() {
    local os arch
    case "$(uname -s)" in
        Linux) os=linux ;; Darwin) os=macos ;; FreeBSD) os=freebsd ;;
        MINGW*|MSYS*|CYGWIN*) os=windows ;; *) return 0 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;; arm64|aarch64) arch=arm64 ;; *) return 0 ;;
    esac
    printf '%s %s' "$os" "$arch"
}

# --- ae binary install ------------------------------------------------------
# aeboot_install_ae_binary VER : try to download+extract the ae binary for VER
# (a bare X.Y.Z). Returns 0 on success, non-zero to signal "fall back to source"
# (unknown platform, no asset, download or extract failure). Prints nothing
# fatal — the caller decides.
aeboot_install_ae_binary() {
    local ver="$1" prefix plat os arch aarch url tmp
    prefix="${PREFIX:-$HOME/.local}"
    plat="$(aeboot_platform)"; [ -n "$plat" ] || return 1
    os="${plat% *}"; arch="${plat#* }"
    # aether asset arch word is x86_64/arm64 (same as our normalized arch).
    aarch="$arch"
    # No prebuilt linux-arm64 ae asset exists at time of writing -> source.
    url="https://github.com/$AEBBOOT_AETHER_REPO/releases/download/v$ver/aether-$ver-$os-$aarch.tar.gz"
    tmp="$(mktemp -d)"
    say "trying ae binary: aether-$ver-$os-$aarch.tar.gz (no .sha256 upstream; HTTPS-trust)"
    if ! curl -fsSL "$url" -o "$tmp/ae.tar.gz" 2>/dev/null; then
        rm -rf "$tmp"; say "  no ae binary for $os-$aarch @ $ver — will build from source"; return 1
    fi
    mkdir -p "$prefix"
    # aether tarball has root layout (bin/ include/ share/ lib/) -> map onto PREFIX.
    if ! tar -xzf "$tmp/ae.tar.gz" -C "$prefix" 2>/dev/null; then
        rm -rf "$tmp"; say "  ae tarball extract failed — will build from source"; return 1
    fi
    rm -rf "$tmp"
    [ -x "$prefix/bin/ae" ] || { say "  ae tarball had no bin/ae — will build from source"; return 1; }
    return 0
}

# --- aeb binary install -----------------------------------------------------
# aeboot_install_aeb_binary : download+verify+install the aeb binary for the
# resolved AEB_FETCH/latest. Returns 0 on success, non-zero for source fallback.
aeboot_install_aeb_binary() {
    local prefix plat os arch aarch base tag url tmp want got here
    prefix="${PREFIX:-$HOME/.local}"
    plat="$(aeboot_platform)"; [ -n "$plat" ] || return 1
    os="${plat% *}"; arch="${plat#* }"
    # aeb asset arch word is amd64/arm64 (NOT x86_64).
    case "$arch" in x86_64) aarch=amd64 ;; arm64) aarch=arm64 ;; *) return 1 ;; esac
    base="aeb-$os-$aarch"
    # Resolve the tag: AEB_REF (a tag only) > AEB_FETCH/AEB_MIN > latest.
    tag="$(aeboot_aeb_tag)"
    [ -n "$tag" ] || { say "  could not resolve an aeb release tag — will build from source"; return 1; }
    url="https://github.com/$AEBBOOT_AEB_REPO/releases/download/$tag/$base.tar.gz"
    tmp="$(mktemp -d)"
    say "trying aeb binary: $base.tar.gz @ $tag (with .sha256 verify)"
    if ! curl -fsSL "$url" -o "$tmp/aeb.tar.gz" 2>/dev/null; then
        rm -rf "$tmp"; say "  no aeb binary for $os-$aarch @ $tag — will build from source"; return 1
    fi
    # Verify sha256 (sidecar format: "<hash>  <filename>").
    if curl -fsSL "$url.sha256" -o "$tmp/aeb.sha256" 2>/dev/null; then
        want="$(awk '{print $1}' "$tmp/aeb.sha256")"
        got="$(aeboot_sha256 "$tmp/aeb.tar.gz")"
        if [ -z "$got" ]; then
            say "  no sha256 tool (sha256sum/shasum) — cannot verify; refusing the binary, building from source"
            rm -rf "$tmp"; return 1
        fi
        if [ "$want" != "$got" ]; then
            rm -rf "$tmp"; die "aeb binary checksum MISMATCH ($base.tar.gz @ $tag): expected $want, got $got. Refusing to install a corrupt/tampered binary."
        fi
        say "  sha256 OK"
    else
        say "  no .sha256 sidecar for $base @ $tag — building from source instead"
        rm -rf "$tmp"; return 1
    fi
    if ! tar -xzf "$tmp/aeb.tar.gz" -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"; say "  aeb tarball extract failed — will build from source"; return 1
    fi
    here="$tmp/$base"
    # The bundled install.sh copies files into PREFIX ("no compiler needed"),
    # but still needs GNU make for its `make install`. If make is absent, fall
    # back to source (which would fail the same way, but with a clearer path).
    if [ ! -f "$here/install.sh" ]; then
        rm -rf "$tmp"; say "  aeb bundle had no install.sh — will build from source"; return 1
    fi
    if ! command -v make >/dev/null 2>&1 && ! command -v gmake >/dev/null 2>&1; then
        rm -rf "$tmp"; say "  GNU make absent (the aeb bundle's installer needs it) — will build from source"; return 1
    fi
    if ! sh "$here/install.sh" "$prefix" >/dev/null 2>&1; then
        rm -rf "$tmp"; say "  aeb bundle install.sh failed — will build from source"; return 1
    fi
    rm -rf "$tmp"
    [ -x "$prefix/bin/aeb" ] || { say "  aeb not at $prefix/bin/aeb after install — will build from source"; return 1; }
    return 0
}

# aeboot_aeb_tag : resolve the aeb release tag to fetch a binary for. An
# explicit AEB_REF that looks like a tag wins; else AEB_FETCH/AEB_MIN mapped to
# the vX.Y aeb tag shape; else the latest v0.NNN tag from the GitHub API.
aeboot_aeb_tag() {
    local r
    r="${AEB_REF:-${AEB_FETCH:-${AEB_MIN:-}}}"
    case "$r" in
        v[0-9]*) printf '%s' "$r"; return 0 ;;                  # already vX.Y[.Z]
        [0-9]*.[0-9]*.[0-9]*) printf 'v%s' "${r%.*}"; return 0 ;; # 0.297.0 -> v0.297
        [0-9]*.[0-9]*) printf 'v%s' "$r"; return 0 ;;            # 0.297 -> v0.297
    esac
    # Nothing usable set (or a branch/SHA, which has no binary): ask GitHub for
    # the latest tag.
    curl -fsSL "https://api.github.com/repos/$AEBBOOT_AEB_REPO/tags?per_page=100" 2>/dev/null \
        | sed -n 's/.*"name": *"\(v0\.[0-9]\{1,\}\)".*/\1/p' | sort -V | tail -n1
}

# --- ae_ensure : guarantee `ae >= AE_PIN` is on PATH ------------------------
ae_ensure() {
    [ -n "${AE_PIN:-}" ] || die "aebboot: AE_PIN is unset — the caller must set the ae floor before ae_ensure."
    local prefix fetch ref have ver
    prefix="${PREFIX:-$HOME/.local}"; export PREFIX="$prefix"
    fetch="${AE_FETCH:-$AE_PIN}"
    export PATH="$prefix/bin:$PATH"

    if command -v ae >/dev/null 2>&1 && have="$(ae_version || true)" && [ -n "$have" ] && version_ge "$have" "$AE_PIN"; then
        say "ae $have already on PATH (>= $AE_PIN) — skipping"
        return 0
    fi

    ref="${AETHER_REF:-$fetch}"
    # BINARY first: only a bare/v-prefixed X.Y.Z has a matching release asset;
    # a branch or SHA forces source. AEBBOOT_NO_BINARY=1 skips binaries.
    ver=""
    case "$ref" in
        v[0-9]*.[0-9]*.[0-9]*) ver="${ref#v}" ;;
        [0-9]*.[0-9]*.[0-9]*)  ver="$ref" ;;
    esac
    if [ -z "${AEBBOOT_NO_BINARY:-}" ] && [ -n "$ver" ] && aeboot_install_ae_binary "$ver"; then
        have="$(ae_version || true)"
        [ -n "$have" ] && version_ge "$have" "$AE_PIN" \
            || die "installed ae binary $have is BELOW the floor $AE_PIN — set AETHER_REF/AE_FETCH to >= $AE_PIN."
        say "ae $have ready (binary)"
        return 0
    fi

    # SOURCE fallback (get.sh: fetch source tarball + make install).
    aeboot_preflight_cc
    case "$ref" in [0-9]*.[0-9]*.[0-9]*) ref="v$ref" ;; esac   # bare X.Y.Z -> vX.Y.Z tag
    say "installing ae via get.sh from source (AETHER_REF=$ref, PREFIX=$prefix)"
    AETHER_REF="$ref" fetch_run "$AEBBOOT_AETHER_GET_URL" || die "ae install failed (get.sh)."
    command -v ae >/dev/null 2>&1 || die "ae installed but not on PATH — ensure $prefix/bin is on PATH."
    have="$(ae_version || true)"
    if [ -n "$have" ] && ! version_ge "$have" "$AE_PIN"; then
        die "installed ae $have is BELOW the floor $AE_PIN (ref=$ref) — set AETHER_REF to a tag >= $AE_PIN."
    fi
    say "ae ${have:-installed} ready (source)"
}

# --- aeb_ensure : guarantee `aeb` is on PATH -------------------------------
aeb_ensure() {
    local prefix have ref
    prefix="${PREFIX:-$HOME/.local}"; export PREFIX="$prefix"
    export PATH="$prefix/bin:$PATH"

    if command -v aeb >/dev/null 2>&1; then
        have="$(aeb_version || true)"
        if [ "$have" = "0.0.0" ]; then
            say "aeb (source build, unversioned) already on PATH — skipping floor check"
        elif [ -n "${AEB_MIN:-}" ] && [ -n "$have" ] && ! version_ge "$have" "$AEB_MIN"; then
            say "WARNING: aeb $have is older than this repo's floor $AEB_MIN."
            say "  Its build files use the b-free Shape A grammar (bldr.build{}) that"
            say "  needs aeb >= $AEB_MIN; an older aeb fails on 'import bldr'. To upgrade:"
            say "    AEB_REF=v$AEB_MIN $0     # or install a newer aeb yourself"
        else
            say "aeb ${have:-(version unknown)} already on PATH — skipping"
        fi
        say "using aeb: $(command -v aeb)"
        return 0
    fi

    command -v ae >/dev/null 2>&1 || die "aeb_ensure: no \`ae\` on PATH — call ae_ensure first (or aeb_bootstrap); aeb's installer needs an ae to target."

    # BINARY first (download + sha256 verify + bundled install.sh).
    if [ -z "${AEBBOOT_NO_BINARY:-}" ] && aeboot_install_aeb_binary; then
        say "using aeb: $(command -v aeb) ($(aeb_version || echo version-unknown)) (binary)"
        return 0
    fi

    # SOURCE fallback (repo install.sh: fetch source tarball, build with ae).
    ref="${AEB_REF:-}"
    case "$ref" in
        [0-9]*.[0-9]*.[0-9]*) ref="v${ref%.*}" ;;   # 0.297.0 -> v0.297
        [0-9]*.[0-9]*)        ref="v$ref" ;;         # 0.297   -> v0.297
    esac
    say "installing aeb via install.sh from source (AEB_REF=${ref:-latest}, PREFIX=$prefix)"
    AEB_REF="$ref" AETHER="$(command -v ae)" fetch_run "$AEBBOOT_AEB_INSTALL_URL" || die "aeb install failed (install.sh)."
    command -v aeb >/dev/null 2>&1 || die "aeb installed but not on PATH — ensure $prefix/bin is on PATH."
    # No post-install floor re-check: a source build reports 0.0.0-dev
    # (unversioned), so a floor check would be meaningless or a false failure on
    # the aeb we just fetched. ae stamps its version; aeb-from-source does not.
    say "using aeb: $(command -v aeb) ($(aeb_version || echo version-unknown)) (source)"
}

# --- aeb_bootstrap : the convenience entry point ---------------------------
aeb_bootstrap() {
    ae_ensure
    aeb_ensure
    case ":$PATH:" in *":${PREFIX:-$HOME/.local}/bin:"*) : ;;
        *) say "tip: add '${PREFIX:-$HOME/.local}/bin' to your shell PATH permanently";; esac
}
