#!/usr/bin/env sh
# aeb remote installer — install a prebuilt release binary, or build from source.
#
# The one-command, no-clone human path for aeb, mirroring aether's get.sh. aeb
# is written in Aether, so it needs `ae` on PATH first — install that with
# aether's get.sh (curl -fsSL .../aether/main/get.sh | sh), or let a consumer
# repo's bootstrap.sh source aebboot.sh (which ensures BOTH ae and aeb, pinned).
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh | sh
#   curl -sSL .../get.sh | sh -s -- v0.297             # a specific release (piped)
#   sh get.sh v0.297                                  # a specific release (downloaded)
#   AEB_REF=v0.297 sh get.sh                           # same, via env var
#   PREFIX=/usr/local sh get.sh v0.297                # system-wide (needs sudo)
#   AEB_FROM_SOURCE=1 sh get.sh                       # force a source build
#
# The version may be the FIRST POSITIONAL ARGUMENT (`sh get.sh v0.297`, or piped
# as `| sh -s -- v0.297`) or via AEB_REF. The argument wins if both are set.
# With neither, the latest release is used.
#
# Env knobs:
#   AEB_REF          release tag (vX.Y or vX.Y.Z) to install (same as the
#                    positional argument; the argument takes precedence).
#                    Default: the latest release. A branch or commit SHA is also
#                    accepted, but forces a source build (no prebuilt exists).
#   AEB_FROM_SOURCE  set to 1 to skip the prebuilt binary and build from the
#                    source tarball even when a prebuilt exists.
#   PREFIX           install prefix. Default: $HOME/.local  (no sudo).
#   AETHER           the ae to build with on the SOURCE path. Default: `ae` on PATH.
#
# The prebuilt aeb bundle needs NO C compiler (its tools are already target-native
# and bin/aeb is a script), but its bundled installer runs `make install`, so GNU
# make is required either way. A source build additionally needs `ae` on PATH.
# The prebuilt tarball is sha256-verified (a .sha256 sidecar ships beside it);
# a mismatch is fatal. Tests are NOT run.
#
# How this resolves "latest" without tripping GitHub's rate limits: it reads the
# `Location:` header of the plain web redirect at /releases/latest (a 302, not
# the 60-req/hr JSON API). Asset downloads at /releases/download/<tag>/<file>
# are likewise unauthenticated and un-throttled.
set -eu

REPO="aether-lang-dev/aeb"
PREFIX="${PREFIX:-$HOME/.local}"
FROM_SOURCE="${AEB_FROM_SOURCE:-0}"
INSTALL_SH_URL="https://raw.githubusercontent.com/$REPO/main/install.sh"

say()  { printf 'aeb-install: %s\n' "$*"; }
die()  { printf 'aeb-install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || die "curl is required."
have tar  || die "tar is required."

# --- resolve the release tag to install ------------------------------------
# Precedence: first positional argument, then AEB_REF, then latest. The ref may
# be a tag (vX.Y / vX.Y.Z), a branch, or a SHA. Only a vX.Y[.Z] tag has a
# prebuilt; branches/SHAs fall through to a source build. aeb tags are vX.Y
# (e.g. v0.297); a bare X.Y.Z is mapped to vX.Y.
REF="${1:-${AEB_REF:-}}"
case "$REF" in
    [0-9]*.[0-9]*.[0-9]*) REF="v${REF%.*}" ;;   # 0.297.0 -> v0.297
    [0-9]*.[0-9]*)        REF="v$REF" ;;         # 0.297   -> v0.297
esac
if [ -z "$REF" ]; then
    loc=$(curl -fsSI "https://github.com/$REPO/releases/latest" 2>/dev/null \
        | tr -d '\r' \
        | sed -n 's#^[Ll]ocation:[[:space:]]*.*/releases/tag/\(.*\)$#\1#p' \
        | tail -1)
    if [ -n "$loc" ]; then
        REF="$loc"
        say "latest release is $REF"
    else
        say "could not read /releases/latest; trying the tags API"
        REF=$(curl -fsSL "https://api.github.com/repos/$REPO/tags?per_page=100" 2>/dev/null \
            | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(v0\.[0-9][0-9]*\)".*/\1/p' \
            | sort -V | tail -1)
        if [ -z "$REF" ]; then
            REF="main"
            say "no vX.Y tag found; falling back to 'main' (source build, not pinned)."
        fi
    fi
fi

# Is this ref a release tag (prebuilt candidate)?
is_release_tag=0
case "$REF" in
    v[0-9]*.[0-9]*) is_release_tag=1 ;;
esac

# --- detect the platform slug used in aeb asset names ----------------------
# aeb assets are named: aeb-<os>-<arch>.tar.gz  — NOTE arch word is amd64/arm64
# (NOT x86_64, which is what aether's assets use). e.g. aeb-linux-amd64.tar.gz.
detect_slug() {
    os_raw=$(uname -s 2>/dev/null || echo unknown)
    arch_raw=$(uname -m 2>/dev/null || echo unknown)
    case "$os_raw" in
        Linux)   os=linux ;;
        Darwin)  os=macos ;;
        FreeBSD) os=freebsd ;;
        MINGW*|MSYS*|CYGWIN*) os=windows ;;
        *)       os="" ;;
    esac
    case "$arch_raw" in
        x86_64|amd64)  arch=amd64 ;;
        arm64|aarch64) arch=arm64 ;;
        *)             arch="" ;;
    esac
    [ -n "$os" ] && [ -n "$arch" ] && printf '%s-%s' "$os" "$arch"
}

# --- sha256 (tool-agnostic) ------------------------------------------------
sha256_of() {
    if have sha256sum; then sha256sum "$1" | awk '{print $1}'
    elif have shasum;   then shasum -a 256 "$1" | awk '{print $1}'
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

install_prebuilt=0
if [ "$FROM_SOURCE" != "1" ] && [ "$is_release_tag" = "1" ]; then
    slug=$(detect_slug || true)
    if [ -n "${slug:-}" ]; then
        asset="aeb-$slug.tar.gz"
        aurl="https://github.com/$REPO/releases/download/$REF/$asset"
        say "trying prebuilt binary: $asset @ $REF (with .sha256 verify)"
        if curl -fSL "$aurl" -o "$tmp/aeb-bin.tar.gz" 2>/dev/null; then
            # Verify the sha256 sidecar (format: "<hash>  <filename>"). A missing
            # sidecar or a missing local sha256 tool means we CANNOT verify — refuse
            # the binary and fall back to source rather than install unverified.
            if curl -fsSL "$aurl.sha256" -o "$tmp/aeb-bin.sha256" 2>/dev/null; then
                want=$(awk '{print $1}' "$tmp/aeb-bin.sha256")
                got=$(sha256_of "$tmp/aeb-bin.tar.gz")
                if [ -z "$got" ]; then
                    say "no sha256 tool (sha256sum/shasum) to verify — building from source instead."
                elif [ "$want" != "$got" ]; then
                    die "prebuilt checksum MISMATCH ($asset @ $REF): expected $want, got $got. Refusing a corrupt/tampered binary."
                else
                    say "sha256 OK"
                    install_prebuilt=1
                fi
            else
                say "no .sha256 sidecar for $asset @ $REF — building from source instead."
            fi
        else
            say "no prebuilt for $slug at $REF — will build from source."
        fi
    else
        say "no prebuilt for this platform ($(uname -s)/$(uname -m)) — building from source."
    fi
fi

# --- prebuilt path: run the bundle's own installer -------------------------
if [ "$install_prebuilt" = "1" ]; then
    have make || have gmake || die "GNU make is required (the prebuilt bundle's installer runs 'make install')."
    tar -xzf "$tmp/aeb-bin.tar.gz" -C "$tmp" || die "extract failed (prebuilt)."
    # The tarball has a single top dir aeb-<slug>/ with a bundled install.sh.
    here=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'aeb-*' | head -1)
    [ -n "$here" ] && [ -f "$here/install.sh" ] || die "prebuilt bundle missing install.sh — is the asset correct?"
    say "installing prebuilt @ $REF  ->  PREFIX=$PREFIX"
    sh "$here/install.sh" "$PREFIX" || die "the bundle's install.sh failed."
else
    # --- source path: delegate to the repo install.sh (fetch source + build) ---
    have ae || die "aeb builds from Aether, so 'ae' must be on PATH for a source build. Install it first: curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aether/main/get.sh | sh"
    src_ref="$REF"
    say "installing aeb @ $src_ref from source via install.sh  ->  PREFIX=$PREFIX"
    tmp2=$(mktemp)
    if curl -fsSL "$INSTALL_SH_URL" -o "$tmp2"; then
        AEB_REF="$src_ref" PREFIX="$PREFIX" AETHER="${AETHER:-$(command -v ae)}" sh "$tmp2" \
            || { rm -f "$tmp2"; die "aeb source install failed (install.sh)."; }
        rm -f "$tmp2"
    else
        rm -f "$tmp2"; die "could not fetch install.sh."
    fi
fi

bin="$PREFIX/bin/aeb"
[ -x "$bin" ] || die "install finished but $bin is missing."
say "installed: $bin"
"$bin" --version 2>/dev/null | head -1 || true

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) say "note: $PREFIX/bin is not on your PATH — add it to use 'aeb' directly." ;;
esac
say "done. Pin this in CI with: AEB_REF=$REF"
