# FIXED: `aeb --version` reported 0.0.0-dev+<sha> even on a tagged release

**From:** the selaenium/html-sanitizer line (2026-09-06). A released aeb binary
could not self-report its release tag; only the fetcher's own
`ci/toolchain.sh` ("installed aeb v0.294 from the verified prebuilt release
binary") knew the version, because it knew which tag it had fetched.

## Root cause

The release workflow knows `$TAG` (e.g. `v0.294`) when it builds the
`aeb-bootstrap` payload, but never wrote it into the payload. `make install`
stamps `AEB_STAMP` from `git describe`, which returns `unknown` in the
`.git`-less payload, and the `--version` handler (the bash trampoline `aeb`,
lines ~288) hardcoded `aeb 0.0.0-dev+${src}`. Confirmed by unpacking the real
v0.294 `aeb-bootstrap.tar.gz`: the string `v0.294` appears nowhere in it.

## Fix (three coordinated changes)

1. **`.github/workflows/release.yml`** — write the tag into the stage:
   `printf '%s' "$TAG" > "$STAGE/VERSION"`.
2. **`Makefile`** (install) — new AEB_STAMP `version` field:
   `VER=$( [ -f VERSION ] && tr -d '[:space:]' < VERSION || echo 0.0.0-dev+$SRCH )`,
   written as `version %s`.
3. **`aeb`** (bash trampoline `--version`) and **`tools/aeb-cli.ae`** (the
   telemetry `AEB_VERSION` line, via `_aeb_stamp_summary`) — read the `version`
   field; use it when present, else `0.0.0-dev+<src>`.

Source `make install` ships no VERSION file, so a dev build still correctly
reports `0.0.0-dev+<sha>`. `/VERSION` is gitignored so it never leaks into the
source tree.

Verified locally on ae 0.643.0: a VERSION-stamped install →
`aeb v0.295   (git …, installed …)`; a source install →
`aeb 0.0.0-dev+<sha>`. Regression test: `tests/test_aebcli_parse.ae` covers the
`version` field extraction. Lands in the next release (forward-only — v0.294 and
earlier can't be retroactively re-stamped).
