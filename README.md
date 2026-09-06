# aeb

> Your build is a graph whether you acknowledge it or not.

A build system for polyglot monorepos. Small declarative files replace
Makefiles, `pom.xml`, `package.json` scripts, `deps.edn`, `Cargo.toml`,
`.csproj`, and `pyproject.toml` — and replace them consistently across
languages. Convention does the work; you declare the intent.

(`aeb` was originally short for "Aether Build" — the runner is written
in Aether and was the project's first non-trivial Aether application.)

## What it looks like

A Java component with one dependency:

```aether
import build
import java

aeb(cap) {
    b = build.start()
    build.dep(b, "java/components/vowelbase/.build.ae")
    java.javac(b)
}
```

A Rust shared library that depends on a vendored `jni` crate:

```aether
import build
import rust
import rust (crate_name, edition, crate_type, lib_path, lib_name)

aeb(cap) {
    b = build.start()
    build.dep(b, "libs/rust/registry/vendor/jni/.jni.crate.ae")
    rust.cargo_project(b) {
        crate_name("vowelbase")
        edition("2021")
        crate_type("cdylib")
        lib_path("lib.rs")
        lib_name("libvowelbase.so")
    }
}
```

A JUnit test module with vendored `junit.jar`:

```aether
import build
import java

aeb(cap) {
    b = build.start()
    build.dep(b, "java/components/vowelbase/.build.ae")
    build.dep(b, "libs/java/junit/.junit.jar.ae")
    build.dep(b, "libs/java/hamcrest/.hamcrest.jar.ae")
    java.javac_test(b)
    java.junit(b)
}
```

A Spring Boot test module with Maven dependencies via a BOM:

```aether
import build
import java
import maven (load_bom_file)
import java (release, source_layout, enable_preview, parameters)

aeb(cap) {
    b = build.start()
    build.dep(b, "jpa/example/.build.ae")
    load_bom_file(b, "../../spring-boot.bom.ae")
    build.dep(b, "org.springframework.boot:spring-boot-starter-test")
    build.dep(b, "org.springframework.boot:spring-boot-data-jpa-test")
    java.javac_test(b) {
        release("25")
        source_layout("maven idiomatic")
        enable_preview()
        parameters()
    }
    java.junit5(b) {
        enable_preview()
    }
}
```

## How it works

A module's build intent lives in one or more dot-prefixed `.ae` files:

| File                       | Role                                      |
|----------------------------|-------------------------------------------|
| `.build.ae`                | compile the module                        |
| `.build-<tag>.ae`          | additional binary in the same module dir  |
| `.tests.ae`                | compile + run tests                       |
| `.tests-<tag>.ae`          | additional test binary in the same dir    |
| `.dist.ae`                 | package (fat jar, Docker image, wheel…)   |
| `.dist-<tag>.ae`           | additional packaging variant              |
| `.{name}.jar.ae`           | vendored JVM jar                          |
| `.{name}.crate.ae`    | vendored / registry Rust crate            |
| `.{name}.npm.ae`      | vendored / registry npm package           |
| `.{name}.nupkg.ae`    | vendored / registry NuGet package         |
| `.{name}.whl.ae`      | vendored / registry Python wheel          |

#### Multiple build files per directory

A module dir can hold more than one of each role using a `<tag>`
suffix. Useful when the same source tree produces multiple binaries
(e.g. a server and a paired seeder), or runs multiple test phases
against shared sources:

```
ae/myserver/
├── .build.ae           # → label "ae/myserver"
├── .build-seed.ae      # → label "ae/myserver:seed"
├── .tests.ae           # → label "test:ae/myserver"
└── .tests-it.ae        # → label "test:ae/myserver:it"
```

Each tagged file is its own graph node — `aeb --graph` shows them
separately, `aeb --since` walks them independently, and a downstream
`build.dep("ae/myserver/.build-seed.ae")` references just the seed
target. The labels appear in `[telemetry]` so you can see per-target
timing for each binary.

The runner (`aeb`) does four things:

1. **Scan** — walk the tree and collect every `.*.ae` file
2. **Graph** — grep each `dep(b, "…")` line to derive a file-based DAG
3. **Sort** — topologically order the files
4. **Generate + link** — produce a single orchestrator `.ae` file with one
   function per module, compile them all to C, link into a single native
   binary, run it

The generated binary is one process with one in-memory visited-module map.
Each module function calls its deps directly — no subprocesses, no
file-based coordination. Per-module artifacts (classpaths, library paths,
crate paths, NuGet refs, source paths) are written to `target/<module>/`
so downstream modules can read and compose them transitively.

File paths encode to C-safe function names:

```
java/components/vowelbase/.build.ae
→ java_components_vowelbase__D_build_D_ae
```

(`/` → `_`, `.` → `_D_`, `-` → `_H_`, `_` → `__`.)

## Installing

aeb is written in Aether, so it needs the [Aether toolchain](https://github.com/aether-lang-dev/aether)
(`ae`) first.

**Don't have Aether's `ae` yet?** One line installs it (Aether's own installer,
into `~/.local`; `PREFIX=` to override, `AETHER_REF=vX.Y.Z` to pin). Aether
compiles to C, so the only prerequisites are a C compiler and GNU make — no
chicken-and-egg toolchain:

```sh
curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aether/main/get.sh | sh
```

Make sure `~/.local/bin` is on your `PATH` (the installer prints a note if it
isn't):

```sh
command -v ae || export PATH="$HOME/.local/bin:$PATH"   # add to your shell rc to persist
```

**Then install aeb** the same way — one line into the same no-sudo prefix. Like
`ae`, this is binary-first: it downloads the prebuilt, **sha256-verified** aeb
release for your platform (no compile), falling back to a source build only when
no asset exists. Pin in CI with `AEB_REF=v0.297`:

```sh
curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh | sh
```

Or from a clone:

```sh
git clone https://github.com/aether-lang-dev/aeb.git && cd aeb && make install
```

`aeb --version` then reports the release tag it installed.

**Bootstrapping a repo that builds with aeb?** The same [`get.sh`](get.sh) is
*also a sourceable library* — the one helper that ensures **both** `ae` and
`aeb` in the right order (aeb's installer needs an `ae` to target). Executed
(`| sh`) it installs; **sourced** it just defines the functions, so a repo's
`bootstrap.sh` can call `aeb_bootstrap` (or `ae_ensure` / `aeb_ensure`) against
its own pin:

```sh
. <(curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh)
AE_PIN=0.645.0 aeb_bootstrap        # ensures ae (>= AE_PIN) THEN aeb
```

Both tools are binary-first — prebuilt gh-release tarballs (with a runtime
`.sha256` verify on aeb), falling back to the source installers for no-asset
platforms or `AEB_FROM_SOURCE=1`.

Full guide — pinning in CI, tracking HEAD, an automation recipe — in
[docs/guides/bootstrap-from-source.md](docs/guides/bootstrap-from-source.md).

## Setup

Initialize a repo to use aeb:

```bash
aeb --init
```

This creates symlinks in `.aeb/lib/` for every shipped SDK module and
adds `.aeb/` to `.gitignore`. Safe to re-run.

## Running

```bash
# Run one target (file-based — the primary form):
aeb jpa/example/.build.ae
aeb jpa/example/.tests.ae

# Or from inside the module directory:
cd jpa/example && aeb .tests.ae

# Synonym address (resolves to .build.ae, echoes the canonical path):
aeb jpa/example:build

# Scan mode — build every node matching a glob (the glob is REQUIRED):
aeb --scan '.tests.ae'              # every test target in the tree
aeb --since main --scan '.tests.ae' # only those impacted since `main`
```

A bare `aeb` with no target and no `--scan` is an error — aeb never builds
the whole tree implicitly; scoping is always explicit (name a target, or
`--scan '<glob>'`).

Build files declare their entrypoint as `aeb(cap)` (the capability the
trusted host injects; legacy `main()` also works) — see the examples above
and [docs/design/capability-entrypoint.md](docs/design/capability-entrypoint.md).

aeb auto-detects Podman's socket and sets `DOCKER_HOST` so TestContainers
works without a daemon.

### Sparse checkout (`aeb gcheckout`)

`aeb gcheckout` walks the `.ae`-file dependency DAG starting from a target
and adds each visited module's directory to the VCS sparse-checkout, so a
monorepo consumer can fetch only the modules they actually need.

```bash
aeb gcheckout --init                      # enable sparse-checkout, add scaffolding
aeb gcheckout add jpa/example/.tests.ae   # walk DAG from target, sparse-add each dir
aeb gcheckout add java/components/vowels  # directory form (resolves to .build.ae etc.)
aeb gcheckout --reset                     # disable sparse-checkout
```

The walk goes through the same `extract-deps` tool the rest of `aeb` uses,
so any `.jar.ae` / `.crate.ae` / `.npm.ae` / `.nupkg.ae` / `.whl.ae`
third-party dep file is followed automatically.

> **Note** — the implementation currently shells out to `git
> sparse-checkout` and is therefore Git-only. Mercurial support would need
> a small VCS abstraction layer (`narrowhg` extension on the hg side, or
> a different command per VCS). The dep-walking logic itself is
> VCS-agnostic and would be reused unchanged.

### Typical output

```
aeb: 18 build + 2 dist + 17 tests
  build: rust/components/vowelbase
  build: java/components/vowelbase
  ...
  dist: java/applications/monorepos_rule
  tests: javatests/components/vowelbase
  ...
javatests/components/vowelbase: tests PASSED
```

### Test output is preserved

Each test SDK that participates writes its full stdout+stderr to
`target/<module>/test_output.log` for failure diagnosis after the
build. Terminal scrollback isn't reliable (especially in CI), so
the persisted file is the authoritative record. Currently wired
in `java.junit5`, `java.junit`, `jest.test`, `python.pytest`, and
`dotnet.test`; other SDKs are tracked for follow-up.

### Build graph visualisation (`aeb --graph`)

`aeb --graph` emits the build-file DAG as a graphviz DOT description
on stdout. `aeb --graph mermaid` emits a Mermaid flowchart suitable
for Markdown.

```bash
# Render to SVG via graphviz
aeb --graph | dot -Tsvg > deps.svg

# Render to PNG
aeb --graph | dot -Tpng > deps.png

# Embed in Markdown via Mermaid (renders inline on GitHub)
aeb --graph mermaid > deps.md
```

The graph reflects exactly what the build pipeline sees: every
dot-prefixed `.ae` target under cwd, with edges drawn from each
`build.dep("path/.foo.ae")` line. No render-only data; this is the
authoritative DAG. Useful for debugging "why isn't X depending on
Y", reviewing dep changes in a PR, or onboarding someone to a
monorepo's structure.

### Build graph queries

`aeb query`, `aeb owners`, `aeb path`, and `aeb why` answer read-only
questions against the same build-file DAG that `aeb --graph` renders.
They scan the tree, write `target/_aeb/_edges.txt`, print the answer,
and exit before compiling or running any target.

```bash
# Transitive dependencies of a target
aeb query 'deps(apps/api/.build.ae)'

# Transitive reverse dependencies of a target
aeb query 'rdeps(libs/core/.build.ae)'

# Owning .ae target(s) for a source path, using the same nearest
# enclosing-build-file rule as --since / --print-affected.
aeb owners apps/api/src/main/java/com/acme/Api.java

# One dependency path from a target to another target
aeb path apps/api/.dist.ae libs/core/.build.ae

# Alias for path, intended for "why does this depend on that?"
aeb why apps/api/.dist.ae libs/core/.build.ae
```

The query expression should be quoted in a shell because unquoted
parentheses are shell syntax. `deps(...)` walks dependency edges
outward; `rdeps(...)` walks reverse edges to consumers.

### Seeing what's here (`aeb --list`)

A bare `aeb` deliberately does **not** build the whole tree — scoping is
always explicit. But it no longer dead-ends: it points at `--list`.

```bash
aeb --list
```

```
sets:
  .presubmit.ae
tests:
  libs/core/.tests.ae
  apps/api/.tests.ae
build:
  libs/core/.build.ae
```

Builds nothing, reads no edges — one tree scan, grouped by the target's
own type, with named target sets first because they answer "what do I
run?".

Scoping matches every other aeb verb: the scan is rooted at CWD, so
running it from a subdirectory lists that subtree only. Because that is
easy to misread as "this is the whole repo", the listing says so
explicitly when you are below the project root:

```
# Note: targets from parent directories omitted
#       (listing is scoped to this directory; run from /path/to/repo for all)
```

### Version from the working copy (`meta.version_from_vcs`)

`meta.version(b, "1.2.3")` is a literal, so the number lives in two places
— the tag and the build file — and drifts. `version_from_vcs` asks the
working copy instead:

```aether
import meta (version_from_vcs)

aeb(cap) {
    b = build.start()
    aether.program(b) { source("main.ae") output("hello") }
    meta.version_from_vcs(b, "0.0.0-dev")   // 2nd arg = fallback
}
```

Yields e.g. `v2.5.0` on a tagged commit, `v2.5.0-1-ge22998f-dirty` once
you have moved past it with local edits. The tag *is* the version — no
second copy, and no stamping commit polluting history.

**VCS-neutral.** aeb's root discovery already honours eight systems, and
this covers the same set rather than treating git as the default:

| Marker | Asks | Looks like |
|---|---|---|
| `.git` | `git describe --tags --dirty --always` | `v1.2.3-4-gabc1234` |
| `.hg` | `hg id -t` / `hg id -i` | `1.2.3` |
| `.svn` | `svnversion` | `1234M` |
| `.bzr` | `bzr revno` | `42` |
| `.fslckout` | `fossil info` | `abc1234567` |
| `.pijul` | `pijul log` | `abc1234567` |
| `.avn` | `avn id` | avn's own form |

Detection is by working-copy **marker**, so aeb runs one command, not
seven. Each string is that VCS's own idiom, deliberately not normalised
into a fake semver — a stamp identifies the tree it was built from, and
rewriting `r1234` as `0.0.1234` would invent precision that is not there.

The fallback (2nd argument) is used when the tree has no marker, the VCS
CLI is absent, or the command fails — an exported tarball, a fresh clone
with no tags. One-arg `version_from_vcs(b)` falls back to `""`.

### Post-build steps (`post_build`)

aeb has always had ways to act *before* the work — `pre_command` in
`lib/bash`, `regen(...)` in `lib/aether` (generate sources, tweak flags).
`post_build` is the other half of the sandwich: act on the **output**,
once the artifact exists.

```aether
import build (start, post_build, run_post_build)
import java (javac)

aeb(cap) {
    b = build.start()
    java.javac(b) { release("21") }

    post_build(b, "sha256sum {target_dir}/app.jar > {target_dir}/app.jar.sha256")
    post_build(b, "syft {target_dir}/app.jar -o spdx-json > {target_dir}/app.sbom")
    return build.run_post_build(b)
}
```

Generic and SDK-agnostic — it records on the build context, not a builder
map, so it works after any builder (or none). `{target_dir}` and
`{module_dir}` are substituted so a step can address what was just built
without hardcoding a path. Steps run in declaration order.

**A failing step fails the node** (and stops the remaining steps). That is
deliberate: embedding an SBOM or signing a binary is part of the artifact
being correct, so a silent failure would be a green build that proves
nothing.

Note `run_post_build(b)` is called by *your* build file, not by the SDK —
which keeps the SDKs unaware of it and the feature opt-in.

### Named target sets (`.presubmit.ae`)

A dot-prefixed `.ae` file whose body is nothing but `build.dep(...)`
lines is a **named set of targets**. Building it builds the set.

```aether
// .presubmit.ae — what must be green before you push
import build (start, dep)

aeb(cap) {
    b = build.start()
    build.dep(b, "libs/core/.tests.ae")
    build.dep(b, "apps/api/.tests.ae")
    build.dep(b, "apps/web/.tests.ae")
}
```

```bash
aeb .presubmit.ae
```

No flag, no registry, no special-casing — the existing rules already
allow it. Any dot-prefixed `.ae` file is a node, `build.dep()` is the
only edge mechanism, and the filename is the route, so `.presubmit.ae`
self-classifies as type `presubmit` and reports as
`aeb: 1 build + 1 tests + 1 presubmit`. Members run concurrently; if
one fails, the set exits non-zero.

The name is yours — `.merge-queue.ae`, `.smoke.ae`, `.release.ae`,
`.nightly.ae` all work identically, and sets may depend on sets.

Add `meta.desc(b, "Must be green before push")` to say what the set is
for — it's the highest-value line in the file for whoever reads it next.
A set may also carry an inline guard (failed via `build.fail`) for a
condition that belongs to the set rather than to any member — but only a
*reproducible* one, such as a missing tool the whole set needs. The doc
works through why the guard people ask for first, "fail if the working
tree is dirty", is the wrong thing to reach for.

> **Caveat.** A set is only as honest as its members. A hand-rolled
> node that discards its exit code (`_ = os.system("...")`) reports
> success regardless — which inside a presubmit set means a green
> result that proves nothing. Prefer an SDK builder for anything a set
> depends on.

Full write-up: [`docs/design/presubmit-target-sets.md`](docs/design/presubmit-target-sets.md).

### Affected-target detection (`aeb --since`, `aeb --print-affected`)

`aeb --since <git-ref>` builds only the targets transitively
impacted by changes since `<git-ref>`. `aeb --print-affected <ref>`
lists them without building.

```bash
# CI shape: in a PR, build/test only what the PR touched.
aeb --since main
aeb --since origin/main          # vs the merge base
aeb --since HEAD~10              # vs 10 commits back

# Inspect the impact set without building (one path per line).
aeb --print-affected main
```

The walk: `git diff --name-only <ref>` → list of changed paths →
each path's owning target (nearest enclosing dir with a build
file) → reverse-dep BFS → affected target set. Targets outside
the impact set don't run.

Source-to-target ownership uses **nearest enclosing dir with a
build file**. A change to `lib/foo/src/main.c` is owned by the
nearest `.build*.ae` walking up: `lib/foo/.build.ae` if present,
else `lib/.build.ae`, else nothing. Multiple build files in one
dir (the `.build-<tag>.ae` case) all share ownership of files in
that dir.

Combines well with cache integration: targets that are affected
but cache-hit on their inputs still skip work. Telemetry shows
what built and what hit the cache.

#### Scan mode (`aeb --scan <glob>`)

The main way to build is **target mode** — you name a leaf:
`aeb path/to/.build.ae` (or a directory that resolves to one).
**Scan mode** is the explicit, scoped counterpart: `aeb --scan
'<glob>'` walks the whole tree and builds every `.ae` node whose
basename matches the glob. The glob is **required** — a bare
`aeb` with neither a target nor `--scan` is an error, so aeb
never builds the whole tree implicitly (the un-scoped posture is
exactly what `--scan` exists to forbid, and the dangerous one
under `--vet`).

The glob is POSIX fnmatch (`*`, `?`, `[abc]`) on the basename,
so it doubles as a target-type filter — and composes with
`--since` to narrow an affected set. Designed for CI shapes where
you want only one *type* of target — typically tests on a PR
check, distributions on a release tag:

```bash
# PR check: run only tests impacted by the PR. Skip .build.ae,
# .dist.ae rebuild rows.
aeb --since main --scan '.tests.ae'

# Cover convention variations (.tests.ae, .tests-it.ae, etc.)
aeb --since main --scan '.tests*.ae'

# Release pipeline: build only impacted .dist.ae packagers.
aeb --since main --scan '.dist.ae'

# All matching targets in the tree (no diff filter).
aeb --scan '.tests.ae'

# Inspect the filtered set without running it.
aeb --print-affected main --scan '.tests.ae'
```

The match is against the file's basename, so `.tests.ae`
matches both `lib/foo/.tests.ae` and `apps/bar/.tests.ae`.
Empty intersection (pattern matched nothing in the affected
set) exits 0 with a clear note — distinct from "nothing was
affected at all," which is also exit 0 but a different message.

`--scan` composes with `--since`, `--coverage`, position-
agnostic. Build telemetry rolls up across the filtered set in
one `[telemetry]` block (vs. piping `--print-affected` through
`xargs aeb`, which would produce N separate blocks and re-scan
the tree N times).

#### Shard target sets for CI (`aeb --shard`)

`--shard N/M` deterministically partitions the current build set after
`--since` and `--scan` filtering. This lets CI fan out the same aeb
selection across multiple runners while keeping aeb responsible for
stable target assignment.

```bash
# Runner 2 of 8: impacted test targets only
aeb --since main --scan '.tests*.ae' --shard 2/8

# Four-way split of all test targets under cwd
aeb --scan '.tests*.ae' --shard 1/4
aeb --scan '.tests*.ae' --shard 2/4
aeb --scan '.tests*.ae' --shard 3/4
aeb --scan '.tests*.ae' --shard 4/4
```

The shard key is the sorted target path list. Shard `1/M` receives
positions `0, M, 2M...`; shard `2/M` receives `1, M+1...`, and so on.
Empty shards exit 0 with a clear note. CI owns runner allocation and
parallel job scheduling; aeb owns the deterministic partitioning.

#### Wall-clock cap + process reaping (`aeb --timeout`)

`--timeout N` (or `AEB_TIMEOUT=N`, seconds) caps the whole build's
wall-clock. On overrun aeb terminates the build and exits **124** (the
coreutils `timeout` convention):

```bash
aeb --timeout 600                 # fail the build if it runs > 10 min
AEB_TIMEOUT=600 aeb --since main  # same, via env (CI-friendly)
```

Independently of `--timeout`, aeb runs the whole build in its **own
process group** and group-reaps it on completion — so a step that
backgrounds a server or leaks a helper can't leave a process lingering
into aeb's exit (which, under a sandboxed agent/CI harness, can
otherwise poison the exit code). This reap is always on and is a no-op
when a build leaves nothing running. Per-*step* timeouts and isolation
are a deferred design (see `docs/plans/lifecycle-plan.md` §9) — today the cap and
reap are build-wide.

#### Per-node output, and `--in-process`

By default aeb runs each build node as its **own subprocess** and
redirects that node's tool output (javac, junit, jest, cargo, …) into a
**per-node log**, so aeb's own stdout carries only its framing + the
telemetry summary — chatty tools (an SLF4J binding warning, npm notices)
no longer interleave onto it:

```bash
aeb                              # tool output → target/.aeb/logs/<label>.log
cat target/.aeb/logs/<label>.log # inspect one node's full output
aeb --in-process                 # opt out: all-in-one, tool output on stdout
```

The summary, JSON dumps, and pass/fail are identical either way (same
renderers); only the *location* of tool output differs, and a failing
node's log is surfaced inline.

Per-node runs **in parallel**: aeb emits a Makefile (one target per node,
prerequisites from the dep DAG) and lets `make -jN` schedule it — so
independent nodes build concurrently while deps are respected. Job count
defaults to `nproc`; cap it with `AEB_JOBS=<n>` (`AEB_JOBS=1` forces
sequential). On the polyglot sim this is **~2× faster** than the
all-in-one path, not slower. If `make` isn't on PATH it falls back to a
sequential per-node loop — same artifacts, no warning, just serial. So
`make` is a dependency for *concurrency*, not for building at all.

> **Windows:** the emitted recipes are POSIX shell, so the `make` on
> `PATH` must be the **MSYS/MinGW** GNU make (aeb runs it via MSYS `sh`,
> never `cmd.exe`). Without it you get the serial path, which is a
> supported configuration. See
> [`docs/guides/windows-cross-platform-notes.md`](docs/guides/windows-cross-platform-notes.md) § 4.

**`AEB_SCHED=native`** (experimental) replaces `make` with an in-process
ready-queue scheduler built on Aether's `os.spawn_proc` / `os.wait_any`
— spawn up to N ready nodes, reap whichever finishes first, unblock its
dependents. Same DAG, same `.rc`/`.ms` markers, same telemetry; no
Makefile and no external `make` dependency, on any platform. Measured at
parity with `make -jN` (3 × 2 s nodes: 4487 ms native vs 4464 ms make,
against ~6000 ms serial). Needs `ae >= 0.442.0`.

```bash
AEB_SCHED=native aeb .presubmit.ae
```

Opt-in while it earns the default. `AEB_JOBS=1` still forces the
sequential loop.

**`AEB_NODE_TIMEOUT=<secs>`** caps each node's wall clock, which
`--timeout` cannot: the whole-build watchdog kills the entire process
group, so one hung node takes healthy siblings down with it. Per-node,
only the culprit dies:

```bash
AEB_SCHED=native AEB_NODE_TIMEOUT=600 aeb .presubmit.ae
```

```
aeb-driver: node slow/.tests.ae exceeded AEB_NODE_TIMEOUT=6s; terminating
```

The offender's `.rc` records **137** (128+SIGKILL), distinguishing a
timeout from an ordinary failure; siblings finish normally and the
`[telemetry]` block still renders — which the whole-build timeout path
does not do at all. Native scheduler only (it warns if set without it).

**`--in-process`** (or `AEB_IN_PROCESS=1`) runs the older all-in-one
orchestrator — one process, all nodes in-process, tool output streamed
inline. Simplest to debug, and fine for small builds. Design:
[`docs/design/nodes-as-subprocesses.md`](docs/design/nodes-as-subprocesses.md).

#### Composite targets via `build.scan()`

Where `--scan` is the imperative one-shot ("filter to .tests.ae
right now"), `build.scan()` is the declarative recurring form:
commit a composite `.ae` file once, point CI at it forever.

```aether
// .all-tests.ae at the repo root
import build
aeb(cap) {
    b = build.start()
    build.scan(b, "**/.tests.ae")
}
```

```bash
aeb .all-tests.ae --since main          # recurring CI shape
aeb .all-tests.ae --since main --coverage
```

`build.scan(b, "<glob>")` expands to every matching `.ae` file at
build-graph extraction time (the same grep pass that picks up
`build.dep` lines), so the DAG is still grep-extractable from the
source tree — `aeb --graph`, `aeb --since`, `aeb --print-affected`
all see the expanded set.

Composes naturally with manual deps and other scans:

```aether
// .smoke-tests.ae — narrower aggregator
aeb(cap) {
    b = build.start()
    build.scan(b, "javatests/components/**/.tests.ae")
    build.scan(b, "csharptests/components/**/.tests.ae")
}

// .integration.ae — compose scans with explicit deps
aeb(cap) {
    b = build.start()
    build.dep(b, ".smoke-tests.ae")
    build.dep(b, ".release-builds.ae")
    build.dep(b, "end-to-end/.tests.ae")
}
```

Implementation notes:

- Patterns are POSIX globs with `**` recursive marker (auto-prepended
  with `./` so the marker fires from depth 0). `*` is single-level.
- A `scan()` call's pattern matching its own file is silently
  excluded — self-loop avoidance.
- Zero matches is a hard error at runtime (typo protection — better
  to fail loudly than silently produce a green build that ran nothing).
- `build.dep` and `build.scan` interleave freely: dedup is automatic.

### Watch mode (`aeb --watch`)

`aeb --watch [target]` does an initial build, then watches every
source directory and re-runs aeb (against the affected-target
set) on every change. Save a file, the right things rebuild —
most cache-hit, telemetry shows what actually ran.

```bash
# Watch everything visible from cwd
aeb --watch

# Watch with an initial-build target
aeb --watch ae/myserver
```

Platform support:
- **Linux**: requires `inotifywait` from `inotify-tools` (apt:
  `inotify-tools`, dnf: `inotify-tools`).
- **macOS**: requires `fswatch` (`brew install fswatch`).

`target/`, `.aeb/`, and `.git/` are excluded from the watch (the
build itself writes there; including them would feedback-loop).
Per-target test output (`test_output.log`), cache markers
(`.aeb_cache`), and timestamps are also excluded.

The watch list is computed from the edges file at start; only
directories that *exist on disk* are watched, so it composes
cleanly with `aeb gcheckout`'s sparse-checkout (dirs that
sparse-checkout has hidden don't error). Re-running aeb-watch
after `aeb gcheckout add ...` picks up the newly materialised
dirs.

### Build telemetry (`[telemetry]` block)

Every `aeb` run prints a per-target summary at the end. No
configuration; no opt-in flag.

```
[telemetry]
  build:   java/components/vowelbase     1.21s [miss]
  build:   rust/components/vowelbase     0.01s [hit]
  tests:   javatests/components/vowelbase 3.03s [n/a] 17/17 PASS
  tests:   apptests/integration          5.40s [n/a] 28/30 FAIL
            - blame against demo	expected 'alice' got 'bob'
            - log shows three commits	exit 1
total: 9.65s wall
aeb: 2 build + 2 tests
```

Per-target row format: `<type>: <label> <wall>s [<cache>] <P>/<T> PASS|FAIL`

- **`<type>`** — the build file's name, verbatim: the stem between the
  leading `.` and trailing `.ae` (`.build.ae` → build, `.tests.ae` →
  tests, `.dist.ae` → dist, `.essais.ae` → essais, `.構築.ae` → 構築).
  No normalization — the summary speaks the repo's own filename
  vocabulary (see docs/design/filename-is-the-route.md).
- **`<label>`** — module path, with `:tag` suffix for tagged build
  files (see "Multiple build files per directory" above).
- **`<wall>s`** — wall time in seconds, two decimals.
- **`[<cache>]`** — content-addressed cache outcome:
  `hit` (used cached output, skipped work) /
  `miss` (cache key didn't match, ran the build) /
  `unavailable` (cache disabled or errored) /
  `n/a` (this SDK doesn't participate in caching yet).
- **`<P>/<T> PASS|FAIL`** — only on test rows. P passed of T total.
  Verdict is `FAIL` if any failed.

When a test target fails AND the SDK provides per-test detail
(currently `aether.driver_test` driven by `contrib.aeocha`),
failed test names are indented under the FAIL line with their
failure messages. Other test SDKs (jest, junit5, bash.test, etc.)
report counts only — adding per-test-name detail is per-SDK
follow-up.

The bottom-line summary (`total: 9.65s wall`) is wall-clock for
the whole build session. `aeb: 2 build + 2 tests` counts the
targets that ran (independent of cache outcome) — one `<n> <type>`
clause per distinct verbatim type, first-seen order; types with no
targets are simply not shown.

#### Machine-readable build outputs

CI systems can request JSON sidecar files without changing what aeb
prints to stdout:

```bash
aeb \
  --telemetry-json target/_aeb/telemetry.json \
  --artifacts-json target/_aeb/artifacts.json \
  --tests-json target/_aeb/tests.json
```

- **Telemetry JSON** contains the same per-target records that feed the
  `[telemetry]` block under a versioned schema: `version`, `aeb_version`,
  `since_ref`, `targets[]`, and `summary`. Each target row includes label,
  type, status, duration, cache outcome, rc, and nested test counts when
  present (`tests: null` otherwise).
- **Tests JSON** contains only test rows, with pass/fail counts,
  verdict, cache outcome, and failed-test detail when an SDK provides it.
- **Artifacts JSON** lists non-internal files found under each target's
  `target/<module>/` directory after the run, with target label, type,
  name, path, and target directory.

These files are intended for GitHub Actions, GitLab CI, Buildkite,
TeamCity, Jenkins, and other consumers that need structured data while
keeping aeb itself CI-agnostic.

### Content-addressed cache

aeb caches per-target build artifacts by hash of the inputs. Same
shape as Bazel's local cache or sccache. When inputs (sources +
flags + classpath + toolchain version) hash to a key already in
the cache, the cached artifact is restored and the build step is
skipped — `[hit]` in `[telemetry]`.

Storage:

- Default location: `~/.cache/aeb/` — XDG (`$XDG_CACHE_HOME/aeb` when set;
  override either with `$AEB_CACHE_DIR`).
- Content-addressed via sha256; entries are zlib-compressed.
- No size cap or eviction yet; users prune manually if needed.

Wired into every artifact-producing SDK (`lib/python` reports `[n/a]`
by design — a venv isn't portably cacheable):

- **`lib/aether`** — manual-path link binary
- **`lib/java`** / **`lib/kotlin`** / **`lib/scala`** — `classes/` and
  `test-classes/` trees (tar+zlib)
- **`lib/maven`** — resolved classpath (separate cache from per-target)
- **`lib/ts`** — tsc out-dir tree (excludes `*.tsbuildinfo`)
- **`lib/dotnet`** — `bin/<config>` (never `obj/`; test projects not cached)
- **`lib/go`** / **`lib/rust`** — the output binary/.so (single-file)
- **`lib/clojure`** — AOT `classes/` tree

When you run `aeb` twice in a row with no source changes, the
second run is mostly `[hit]` lines. When you change a single
source file, only its target and its direct downstream rebuild;
everything else stays cached. The `--coverage` flag is part of
the cache key, so coverage and non-coverage builds segregate
cleanly (you don't get a stale instrumented binary when you
asked for a clean build, or vice versa).

The cache works orthogonally to incremental-build mtimes (which
SDKs check independently). Incremental skips work that's
clearly redundant on this machine; the cache shares work across
machines via the remote cache below.

Set **`AEB_NO_CACHE=1`** to force a fresh build: aeb skips the cache
*read* (every manual-path target rebuilds) but still *writes* the
result back, so the run repopulates the cache correctly rather than
leaving a gap — unlike `rm -rf ~/.cache/aeb`, which also evicts every
unrelated good entry. Use it when the environment changed underneath a
key aeb can't see through (e.g. a system library swapped at the same
path).

#### Remote cache (shared, cross-machine)

Point `$AEB_REMOTE_CACHE_URL` at a shared store and `aeb` consults it
*behind* the local cache — transparently, with no SDK changes. On a
local miss it pulls the blob from the remote into the local store and
serves it (so the compiler never runs); on a build it writes local and
pushes the blob to the remote. The remote holds the same
zlib-compressed, sha256-sharded blobs as local, so the two are
interchangeable.

```bash
# CI runner — populate the shared cache:
AEB_REMOTE_CACHE_URL=file:///mnt/ci-cache AEB_REMOTE_CACHE_MODE=write aeb ...

# Developer — reuse CI's artifacts, read-only:
AEB_REMOTE_CACHE_URL=file:///mnt/ci-cache AEB_REMOTE_CACHE_MODE=read aeb ...
```

- **Backend (today):** a shared **filesystem** root — `file:///abs/path`
  or a plain `/abs/path` (an NFS mount, a shared CI volume, a container
  bind-mount). The equivalent of Bazel's `--disk_cache` / Buck2's disk
  cache. `http(s)://` URLs are recognised but not yet wired (HTTP/S3
  backend is next — see TODO.md).
- **Mode:** `AEB_REMOTE_CACHE_MODE` = `off` | `read` | `write` |
  `readwrite` (default `readwrite` when a URL is set). CI runners
  typically `write`; developer machines `read`.
- **Safety:** every remote operation is best-effort — a slow or
  unreachable remote degrades to a local miss / a skipped upload and
  **never fails the build**.

### Coverage (`aeb --coverage`)

Cross-cutting build flag — every SDK that knows what coverage
means for its language honors it; SDKs that don't (e.g. `bash.test`)
ignore it.

```bash
aeb --coverage                        # build everything with coverage
aeb --coverage <target>               # one target, with coverage
aeb --coverage --since main           # affected-targets, with coverage
```

Currently wired in `lib/aether/`:

- `aether.program`/`aether.program_test` shell-out path: appends
  `--coverage` to `ae build` (the Aether 0.115 feature). The
  driver injects `gcc --coverage` and forces `-O0 -g` for
  accurate `.ae.gcov` line attribution.
- `aether.program`/`aether.program_test` manual path (when
  `extra_source`/`link_flag`/`regen` is declared): swaps gcc's
  `-O2` for `-O0 -g --coverage`.

After running an instrumented binary, `.gcda` files appear next
to the binary. aeb does not render reports — delegate to your
preferred tool:

```bash
# graphviz / per-file gcov reports
gcov -p -b -c target/<module>/bin/<binary>-*.gcda

# HTML report via gcovr
gcovr -r . --html --html-details -o coverage.html
```

The cache key includes the coverage flag, so `aeb` and `aeb --coverage`
back-to-back both run real builds (no stale instrumented hit when
you wanted a clean build, or vice versa).

Other SDKs (java, jest, pytest, dotnet, go, rust, etc.) have
their own native coverage flows (jacoco, jest --coverage,
coverage.py, dotnet test --collect, `-cover`, llvm-cov, etc.) —
not yet wired through `aeb --coverage`. Tracked in TODO.md as
follow-up.

### Supply-chain veto & sandbox (`aeb --vet` / `--sandbox`)

A build script is itself an untrusted supply-chain surface. aeb can vet a
build before running it and contain it while it runs — enforced by the
*trusted harness*, so a `.build.ae` can't clear a verdict about itself. The
operator policy is always out-of-tree (an in-tree policy path is refused).

```bash
# Static veto before the build (AST deny-rules + coordinate allowlist):
aeb --vet [--veto-policy /etc/aeb/veto.ae] app/.build.ae

# Bring your own scanner (repeatable; non-zero exit vetoes):
aeb --vet --vet-tool 'semgrep --error .' app/.build.ae

# Vet the whole scanned set:
aeb --vet --scan '.build.ae'

# Runtime containment: run the build under a deny-by-default grant profile
# (no network, write only target/, exec only the toolchain). A denied syscall
# dies at the libc boundary regardless of how the build computed it.
aeb --sandbox [--sandbox-profile /etc/aeb/grants.ae] app/.build.ae
```

Layers (use any subset): a Tier-A tree/patch rule scan (secrets, `binding.gyp`,
`pre/postinstall` hooks, `curl|sh`, tree-size cap), an AST veto over `aetherc
--emit=ast` (deny extern/exec/net/import, a coordinate allowlist), an external
SAST hook (`--vet-tool`), and `spawn_sandboxed` runtime containment. Fail-closed
throughout. `--sandbox` is Linux-only (needs aether ≥ 0.230.0). Full design in
[docs/design/build-veto-and-sandbox.md](docs/design/build-veto-and-sandbox.md).

### Distribution metadata (`meta` SDK) and exporters (`brew`, …)

Distribution is just another target type. Declare metadata via
the `meta` SDK and an exporter closure (e.g. `brew.formula(b)`)
inside a `.dist.ae` file; `aeb` walks it like any other target,
running the exporter to emit the formula.

```aether
// lib/hello/.dist.ae
import build
import meta
import brew
import brew (aeb_target, binary)

aeb(cap) {
    b = build.start()
    meta.desc(b, "Tiny hello-world greeter")
    meta.homepage(b, "https://example.com/hello")
    meta.license(b, "MIT")
    meta.version(b, "0.1.0")
    meta.url(b, "https://example.com/dl/hello-0.1.0.tar.gz")
    meta.sha256(b, "0123...cdef")

    brew.formula(b) {
        aeb_target("lib/hello/.build.ae")  // what `def install` runs
        binary("hello-world")               // optional override
    }
}
```

```bash
aeb lib/hello/.dist.ae          # emits target/lib/hello/hello-world.rb
```

`meta.url` + `meta.sha256` are required (Homebrew won't accept a
formula without them); `aeb_target` is required (so `def install`
knows which target to build). Class name is auto-derived from the
binary name (hyphens become CamelCase: `hello-world` → `HelloWorld`,
overridable via `class_name(...)`). Custom test assertion via
`test_assertion("...")`.

Because distribution targets are real graph nodes, they compose
with everything else: `aeb --affected --since main` will surface
a `.dist.ae` whose upstream `meta.version` changed; `aeb --graph`
shows them; `aeb --watch` rebuilds them on file edits.

`meta.*` is the source-of-truth — future exporters
(`nix.derivation`, `deb.control`, `pkgsrc.makefile`) will read
the same fields, only adding their packaging-specific overrides
in their own closure.

### Approval checks

Approval checks are non-interactive go/no-go checks against an
external system of record. They do not pause for a human and aeb does
not store approval state. CI/CD remains responsible for human approval
UI; aeb only asks "is this artifact allowed to proceed right now?"

The evidence shape is deliberately common across backends:

```json
{
  "provider": "servicenow",
  "subject": "CHG123456",
  "ok": true,
  "approvals": [
    {"id": "person1", "approved_at": "2026-05-09T10:00:00Z", "status": "approved"},
    {"id": "person2", "approved_at": "2026-05-09T10:05:00Z", "status": "approved"},
    {"id": "person3", "approved_at": "2026-05-09T10:07:00Z", "status": "approved"}
  ],
  "failures": []
}
```

Jira status/label/field checks:

```aether
// apps/api/.dist.ae
import build
import approval
import approval (base_url, issue, require_status, require_label,
                 require_field, token_env)

aeb(cap) {
    b = build.start()
    build.dep(b, "apps/api/.tests.ae")

    approval.jira(b) {
        base_url("https://jira.example.com")
        issue("REL-1234")
        require_status("Approved")
        require_label("release-approved")
        require_field("Risk", "Accepted")
        token_env("JIRA_TOKEN")        // default if omitted
    }
}
```

At runtime the builder:

- reads the token from the named environment variable
- fetches `/rest/api/2/issue/<issue>` with `curl`
- checks issue status, labels, and requested fields
- writes evidence JSON to `target/<module>/jira-approval.json`
- fails the target if any requirement is missing

Optional setters:

- `evidence("path/to/evidence.json")` — override the evidence path.
- `timeout("30")` — curl max-time in seconds.

Use Jira field IDs such as `customfield_12345` for custom fields when
Jira's REST payload does not expose a friendly field name.

For systems that expose approval rows, use the common approval grammar:

```aether
approval.servicenow(b) {
    base_url("https://instance.service-now.com")
    issue("CHG123456")
    require_approver("person1")
    require_approver("person2")
    require_approver("person3")
    approval_status("approved")
    token_env("SERVICENOW_TOKEN")
}
```

The path setters map native JSON to normalized evidence:

```aether
approval.http(b) {
    url("https://release.example.com/api/approval/release-1")
    subject("release-1")
    bearer_env("RELEASE_TOKEN")
    require_json("change.status", "approved")
    approvals_path("approvals")
    approver_id_path("id")
    approved_at_path("approved_at")
    approval_status_path("status")
    approval_status("approved")
    require_approver("person1")
    require_approver("person2")
    require_approver("person3")
}
```

Backend entry points:

- `approval.jira(b)` — Jira/Jira Service Management issue checks.
- `approval.servicenow(b)` — ServiceNow approval rows for a change.
- `approval.github(b)` — GitHub approval JSON via `url(...)`, or
  environment metadata via `owner(...)`, `repo(...)`, `environment(...)`.
- `approval.gitlab(b)` — GitLab deployment approvals via `url(...)`, or
  `project(...)` + `deployment(...)`.
- `approval.azure_devops(b)` — Azure DevOps checks/approvals endpoint
  via `url(...)`.
- `approval.http(b)` — generic bearer-token JSON endpoint.
- `approval.command(b)` — command prints JSON to stdout, then aeb
  verifies the same paths/approvers:

  ```aether
approval.command(b) {
    subject_env("CHANGE_ID")
    run("scripts/check-release-approval.sh")
    arg_env("CHANGE_ID")
    approvals_path("approvals")
    approver_id_path("id")
    approved_at_path("approved_at")
    require_approver("person1")
    require_approver("person2")
    require_approver("person3")
  }
  ```

CI systems usually provide the change/release identifier as a job
parameter. Jenkins, TeamCity, GitHub Actions, or GitLab can export
`CHANGE_ID=CHG123456`; aeb reads it through `subject_env(...)`,
`issue_env(...)`, `url_env(...)`, or passes it to local scripts with
`arg_env(...)`.

Approval scripts can also emit a plain-text attestation claim and let
aeb normalize, hash, and verify it against a Live Verify-style endpoint:

```aether
approval.attestation(b) {
    subject_env("CHANGE_ID")
    attestation_command("scripts/approval-attestation.sh \"$CHANGE_ID\"")
    verify_via("https://verify.example.com/c")
}
```

The attestation claim is ordinary text containing the release/change
number, approver IDs, approval timestamps, and any other audit facts:

```text
Release: R-2026-05-09
Change: CHG123456
person1: approved at 2026-05-09T10:00:00Z
person2: approved at 2026-05-09T10:05:00Z
person3: approved at 2026-05-09T10:07:00Z
```

aeb canonicalizes the text (line endings, trailing whitespace, final
newline), computes SHA-256 with `std.cryptography`, verifies
`verify_via/<hash>` with `curl`, and writes evidence containing the
canonical claim, hash, and verify URL. Future systems of record can
emit this canonical approval claim directly; current firms can bridge
through scripts.

## Dependencies

Every dependency — local module, third-party library, Maven coordinate, npm
package, NuGet package, Cargo crate, or Python wheel — is declared with a
single `build.dep()` call. The form of the argument distinguishes them:

```aether
// Local module (reference the dep module's .build.ae file)
build.dep(b, "java/components/vowelbase/.build.ae")

// Vendored / registry third-party (reference its .{name}.jar.ae etc.)
build.dep(b, "libs/java/junit/.junit.jar.ae")
build.dep(b, "libs/rust/registry/vendor/jni/.jni.crate.ae")
build.dep(b, "libs/javascript/mocha/.mocha.npm.ae")
build.dep(b, "libs/dotnet/Shouldly/.Shouldly.nupkg.ae")
build.dep(b, "libs/python/pytest/.pytest.whl.ae")

// Maven coordinate (colon-separated; version from BOM if omitted)
build.dep(b, "org.springframework.boot:spring-boot-starter-data-jpa")
build.dep(b, "com.github.javafaker:javafaker:1.0.2")
```

All of these lines are greppable — the build graph is extracted by
scanning source files, not by compiling them. Same contract as Bazel's
`BUILD` files.

### Third-party dep files: `.ae-as-dep`

Rather than a dozen bespoke helpers (`build.npm_dep`, `build.cargo_dep`,
`build.lib`, …), each third-party dep is its own `.ae` file that registers
its contribution via a language-SDK builder. Examples:

```aether
// libs/java/junit/.junit.jar.ae — vendored jar
aeb(cap) {
    b = build.start()
    java.jar_vendored(b, "libs/java/junit/junit.jar")
}
```

```aether
// libs/rust/registry/vendor/jni/.jni.crate.ae — registry Rust crate
aeb(cap) {
    b = build.start()
    rust.crate_registry(b, "jni~0.21.1")
}
```

```aether
// libs/python/pytest/.pytest.whl.ae — pypi wheel
aeb(cap) {
    b = build.start()
    python.wheel_registry(b, "pytest~")
}
```

Each SDK has symmetric `X_vendored` / `X_registry` builders:

| Language | Vendored              | Registry / fetched     |
|----------|-----------------------|------------------------|
| Java     | `java.jar_vendored`   | `java.jar_registry`    |
| Rust     | `rust.crate_vendored` | `rust.crate_registry`  |
| TS       | `ts.npm_vendored`     | `ts.npm_registry`      |
| .NET     | `dotnet.nuget_vendored` | `dotnet.nuget_registry` |
| Python   | `python.wheel_vendored` | `python.wheel_registry` |

Consumers don't care which — they just `build.dep(b, "libs/.../.foo.bar.ae")`.

## Language SDKs

```aether
import java
java.javac(b) { release("25") source_layout("maven idiomatic") }
java.javac_test(b) { enable_preview() parameters() }
java.junit(b)          // JUnit 4
java.junit5(b)         // JUnit 5 / Jupiter
java.shade(b, "com.Main", "app.jar")
```

```aether
import kotlin
kotlin.kotlinc(b)
kotlin.kotlinc_test(b)
kotlin.kotlin_test(b, "pkg.TestClassKt")
```

```aether
import go
go.go_build(b, "c-shared", "libname.so")
go.go_test(b)
```

```aether
import rust
rust.cargo_project(b) { crate_name("…") edition("2021") crate_type("cdylib") }
rust.cargo_workspace(b) { … }    // root-level workspace Cargo.toml
rust.cargo_crate(b) { … }        // workspace member Cargo.toml
rust.check_workspace(b)
rust.test_workspace(b)
```

```aether
import ts
ts.tsc(b)
```

```aether
import scala
scala.scalac(b)
scala.scalac_test(b)
scala.munit(b)
```

```aether
import clojure
clojure.compile(b)
clojure.test(b)
```

```aether
import dotnet
dotnet.csproj(b) { … }      // generates .{name}.generated.csproj
dotnet.build(b)
dotnet.test(b)
```

```aether
import python
python.install(b)           // pip install deps into venv
python.pytest(b)
python.package(b) { … }     // generate pyproject.toml and build wheel
```

```aether
import bash
import bash (script, jobs, pre_command, post_command, on_failure,
              fixture_seed, fixture_server,
              path, seed_bin, bin, args, port, ready_after_ms)  // see note below

bash.test(b) {              // exit 0 = PASS, non-zero = FAIL
    script("test_a.sh")
    script("test_b.sh")
}
bash.test(b)                // no script(...) → auto-discover test_*.sh
bash.test(b) {              // run up to 4 scripts concurrently
    jobs(4)
}
bash.test(b) { jobs(0) }    // 0 = auto = nproc/2

bash.test(b) {              // pre/post commands run around every script.
    pre_command("source setup.sh")    // pres always run before each script
    post_command("source teardown.sh") // posts always run after, pass or fail
    script("test_acl.sh")
}                           // (forces sequential mode if jobs(N>1) also set)

bash.test(b) {              // on_failure fires ONCE if any script fails —
    script("test_acl.sh")   //   diagnostics / notification, not cleanup.
    on_failure("echo \"FAILED: \$AEB_MODULE_DIR (\$AEB_TEST_FAILED/\$AEB_TEST_TOTAL)\"")
    on_failure("curl -X POST \$SLACK_WEBHOOK -d \"text=tests broke\"")
}                           // env: $AEB_TEST_PASSED, $AEB_TEST_FAILED,
                            // $AEB_TEST_TOTAL, $AEB_MODULE_DIR.
                            // Compatible with parallel mode (fires after).

bash.test(b) {                                       // structured server fixtures —
    fixture_seed(b, "primary") {                     //   spawned per-script, env vars
        path("/tmp/myapp_data")                      //   exposed to the script,
        seed_bin("target/myapp-seed/bin/seed")       //   cleaned up after.
    }                                                //   $PRIMARY_PATH is exported
    fixture_server(b, "primary") {                   //   to the script.
        bin("target/myapp/bin/server")
        args("demo $PRIMARY_PATH 9540 --token X")    // shell-interpolates at run time
        port(9540)                                   //   ($PRIMARY_PATH from the seed
        ready_after_ms(1500)                         //   above is visible).
    }
    script("test_acl.sh")                            // sees $PRIMARY_PATH, $PRIMARY_PORT,
}                                                    // $PRIMARY_BIN, $PRIMARY_PID.

bash.test(b) {                                       // multi-fixture: declare each
    fixture_seed(b, "source")      { path("/tmp/r1") }      //   with a different name. Names
    fixture_seed(b, "destination") { path("/tmp/r2") }      //   become env-var prefixes
    fixture_server(b, "source")      {                       //   ($SOURCE_PORT,
        bin("target/myapp/bin/server"); port(9430); ready_after_ms(500)
    }                                                        //   $DESTINATION_PORT, …).
    fixture_server(b, "destination") {                       // Ports are caller-chosen;
        bin("target/myapp/bin/server"); port(9431); ready_after_ms(500)
    }                                                        //   ready-check is sleep-
    script("test_replication.sh")                            //   then-go (no real probe).
}

bash.run(b) {               // non-test runner: codegen, asset prep, etc.
    script("gen.sh")
}
```

```aether
import aether
import aether (source, output, caps, extra_source, extra_source_glob, link_flag, regen, regen_with, no_closure_regen)

aether.program(b) {                   // shells out to `ae build` by default —
    source("main.ae")                 //   honours aether.toml [[bin]].
    output("hello")
}
aether.program(b) {                   // declaring any of extra_source /
    source("main.ae")                 //   link_flag / regen opts into the
    output("hello")                     //   manual aetherc + gcc path (.build.ae
    regen("ae/client/accessors.ae")   //   becomes the single source of truth,
    regen("ae/client/handlers.ae")    //   aether.toml ignored for this target).
    link_flag("-pthread")
}
                                      // regen(X.ae) runs `aetherc --emit=lib`
                                      // when the paired X_generated.c is missing
                                      // or older than X.ae, then links it in.
                                      // Capabilities (--with=net|fs|os) are
                                      // auto-detected from the .ae's
                                      // `import std.X` lines: std.http /
                                      // std.tcp / std.net → net, std.fs → fs,
                                      // std.os → os.

aether.program(b) {                   // regen_with overrides auto-detection —
    source("main.ae")                 //   use when caps come in transitively
    output("hello")                     //   and the import scan misses them.
    regen_with("ae/client/auth.ae", "net,fs")
}

aether.csrc(b) {                      // C-SOURCE package (aether 0.357
    source("greet.ae")                //   `ae build --emit=csrc`): emits
    output("greet")                   //   greet.c + greet.h (catalog header)
    caps("net")                       //   under target/<module>/ — no gcc,
}                                     //   no host .so. Compile it anywhere:
                                      //   `cc -fPIC -shared greet.c $(ae cflags)`,
                                      //   WASM, or static-link. Publishes
                                      //   c_source / c_header / c_header_dirs /
                                      //   c_needs_aether_runtime, so a dependent
                                      //   c.program -I's the header dir and
                                      //   links libaether without extra wiring.
                                      //   caps("net,fs") → --with= opt-ins;
                                      //   omit when the module needs none.

aether.program(b) {                   // hand-written extras still work via
    source("main.ae")                 //   extra_source(...) — combine freely
    output("hello")                     //   with regen(...) entries.
    extra_source("legacy_helper.c")
    regen("ae/client/accessors.ae")
}
aether.program(b) {                   // extra_source_glob expands a glob at
    source("main.ae")                 //   build-time. Pattern is module-relative;
    output("hello")                     //   the matched files are content-hashed
    extra_source_glob("contrib/*.c")  //   into the cache key, so adding/removing
    extra_source_glob("gen/*.c")      //   matched files invalidates the cache.
}
aether.program(b) {                   // no_closure_regen() — for "thin Aether
    source("ui_live.ae")              //   over a C backend": the entry imports
    output("app")                       //   modules that are extern declarations
    no_closure_regen()                //   of a C ABI (ui.ae over GTK/AppKit/…).
    extra_source("backend_gtk4.c")    //   Such modules can't be --emit=lib'd, so
    extra_source("backend_extras.c")  //   the closure-regen pass is suppressed:
    link_flag("$(pkg-config --cflags --libs gtk4)")  // the entry is plain-
}                                     //   compiled, your extra_source C + flags
                                      //   link it. The closure still feeds the
                                      //   cache key; explicit regen(...) still runs.
aether.program_test(b) { ... }        // same as program, plus runs the binary

aether.driver_test(b) {                    // Aether driver program that
    driver("test_app_driver.ae")           //   exercises a *separate* compiled
    output("app_driver")                   //   binary built elsewhere in the
                                           //   graph (e.g. a server, a CLI).
    binary_under_test(b, "app") {          // The driver imports contrib.aeocha
        path("target/app/bin/app")         //   (or whatever), spawns $APP_BIN
    }                                      //   via os.run_capture, asserts
    fixture_seed(b, "primary") {           //   about its output. Same fixture
        path("/tmp/app_data")              //   grammar as bash.test — env vars
    }                                      //   exposed to the driver are
    fixture_server(b, "primary") {         //   $PRIMARY_PATH, $PRIMARY_PORT,
        bin("$APP_BIN")                    //   $PRIMARY_BIN, $PRIMARY_PID, plus
        args("demo $PRIMARY_PATH 9540")    //   $<NAME>_BIN (or env_var()
        port(9540)                         //   override) for each
        ready_after_ms(1500)               //   binary_under_test. Driver's exit
    }                                      //   code is the PASS/FAIL signal.
}

aether.driver_test(b) {                    // Custom env-var name override.
    driver("test_with_custom_env.ae")
    binary_under_test(b, "app") {
        path("target/app/bin/app")
        env_var("APP_BINARY")              // → $APP_BINARY (vs default $APP_BIN)
    }
}
```

> **Note on the two `import` lines.** Aether resolves identifiers
> inside a `receiver.method(args) { block }` body as plain top-level
> calls, not against the receiver's namespace. So `bash.test(b) {
> script("…") }` won't find `script` unless it's also in scope at the
> top level — hence the second `import bash (script, jobs)` line.
> The alternative is to fully qualify every setter
> (`bash.test(b) { bash.script("…") }`), which works but reads
> noisily.

## Maven / BOM support

A `.bom.ae` file at the repo root declares Maven BOMs and extra repos:

```aether
// spring-boot.bom.ae
maven_bom("org.springframework.boot:spring-boot-dependencies:4.0.4")
```

Modules load it via `load_bom_file(b, "../../spring-boot.bom.ae")`, then
use `build.dep(b, "group:artifact")` with version omitted — the BOM
supplies it. Resolution is performed by `tools/aeb-resolve.jar`, which
wraps the Maven Resolver API and caches to `~/.local/share/aeb/repo`
(XDG data dir; `$XDG_DATA_HOME/aeb/repo` when set).

## Cross-language dependencies

Modules in different languages can depend on each other:

```aether
build.dep(b, "rust/components/vowelbase/.build.ae")    // Java → Rust (JNI .so)
build.dep(b, "kotlin/components/sonorants/.build.ae")  // Java → Kotlin (JVM classpath)
build.dep(b, "go/components/nasal/.build.ae")          // Java → Go (shared library)
```

Each SDK writes artifact metadata to `target/<module>/`:

- `jvm_classpath_deps_including_transitive`
- `rust_path_deps_including_transitive` / `rust_registry_deps_including_transitive`
- `npm_deps_including_transitive` / `npm_registry_deps_including_transitive`
- `dotnet_nuget_deps_including_transitive`
- `python_pypi_deps_including_transitive` / `python_vendored_wheels_including_transitive`
- `ldlibdeps` / `shared_library_deps` (for JNI-style linking)

Downstream SDKs read these files to assemble classpaths, library paths,
Cargo.toml `[dependencies]`, `<PackageReference>`s, `pyproject.toml`
`[project.dependencies]`, and `tsconfig` path mappings.

Working cross-language chains include Java→Rust (JNI), Java→Kotlin,
Java→Go, TypeScript→Go, C#→Rust, Python→Rust (ctypes).

## Incremental builds

SDK builders check source file timestamps against a per-module timestamp
file before doing work. Unchanged modules are skipped at the compile
step; tests always re-run.

## Project layout

`aeb` itself is a bash trampoline (~600 lines — a thin dispatch core plus
opt-in feature arms for `--vet` / `--sandbox` / `--timeout` / remote-agent
dispatch and process-group reaping). It picks up `AETHER`, `AEB_HOME`, and the
working directory, optionally exports a Podman socket, and dispatches `--init` /
`gcheckout` / normal builds to the matching Aether-language tool under `tools/`.
Everything else — argument parsing, scan/target discovery, dep extraction, topo
sort, per-file compile, orchestrator generation, gcc link, exec — runs in
Aether.

A pure-Aether entrypoint, `tools/aeb-cli`, is a faithful facsimile of this bash
trampoline — full flag parity (including `--sandbox`, `--init`, `--version`), the
same supervised exec (own process group, signal forwarding, timeout, group-reap),
verified to produce identical exit code + artifacts + telemetry via the `ab.sh`
A/B harness, and it runs natively on Windows. **It may become the default `aeb`
in a future release** (retiring the bash trampoline, making `aeb` pure Aether end
to end); for now bash `aeb` is the default and `aeb-cli` the proven-equivalent
alternate. See `mingw_a_b_plan.md` and
[docs/plans/aether-runtime-needs.md](docs/plans/aether-runtime-needs.md).

```
aeb/
├── aeb                        # thin bash trampoline → tools/aeb-main
├── lib/                       # shipped SDK modules (symlinked into consumer repos)
│   ├── build/module.ae        # core: session, deps, context, artifact helpers
│   ├── java/module.ae         # language: javac, junit, junit5, shade, jar_vendored, jar_registry
│   ├── kotlin/module.ae
│   ├── go/module.ae
│   ├── rust/module.ae         # cargo_project / cargo_workspace / cargo_crate / crate_vendored / crate_registry
│   ├── ts/module.ae           # tsc, npm_vendored, npm_registry
│   ├── scala/module.ae
│   ├── clojure/module.ae
│   ├── dotnet/module.ae       # .csproj generation, nuget_vendored, nuget_registry
│   ├── python/module.ae       # pyproject.toml generation, wheel_vendored, wheel_registry
│   ├── aether/module.ae       # native Aether programs (program / program_test)
│   ├── bash/module.ae         # bash test runner (exit 0 = PASS) and non-test script runner
│   ├── approval/module.ae     # non-interactive external approval checks
│   ├── maven/module.ae        # BOM parsing, Maven resolution wrapper
│   ├── pnpm/module.ae         # pnpm-based npm resolution
│   ├── jest/module.ae
│   ├── webpack/module.ae
│   ├── angular/module.ae
│   └── container/module.ae    # OCI image builds, LXC
├── tools/                     # Aether-language tools that aeb dispatches to
│   │  # core build pipeline
│   ├── aeb-main.ae            # arg parsing, scan/target discovery, sort, exec aeb-link
│   ├── aeb-link.ae            # per-file compile + orchestrator + gcc link + exec
│   ├── aeb-driver.ae          # per-node parallel driver (emits the Makefile)
│   ├── gen-orchestrator.ae    # emits the single-binary orchestrator
│   ├── transform-ae.ae        # rewrites user .ae files for linking (pure-Aether
│   │                          #   transitive-import resolver, no shell)
│   ├── aeb-init.ae            # `aeb --init` symlink + .gitignore setup
│   ├── aeb-cli.ae             # pure-Aether entrypoint (facsimile of the bash `aeb`)
│   │  # graph / query / affected
│   ├── aeb-graph.ae           # `aeb --graph` DOT/Mermaid
│   ├── aeb-query.ae           # `aeb query/owners/path/why`
│   ├── affected-targets.ae    # `aeb --since` / `--print-affected` walk
│   ├── gcheckout.ae           # `aeb gcheckout` sparse-checkout DAG walker
│   │  # trust / containment
│   ├── aeb-vet.ae             # `aeb --vet` supply-chain veto
│   ├── aeb-sandbox.ae         # `aeb --sandbox` runtime containment (Linux)
│   ├── aeb-sbom.ae            # `aeb --resolve-only --sbom-json` dep-closure SBOM
│   ├── aeb-trace.ae           # `aeb --trace-intent` doppelganger intent trace
│   │  # remote agent (opt-in; built via `aeb tools/agent/.install.ae`)
│   ├── aeb-agent.ae           # remote build agent — RBE executor (HTTP listener; per-job toolchain container via --run-on podman)
│   ├── aeb-remote.ae          # `aeb --use-remote-agents` dispatch client
│   │  # helpers (lazy-built, pure-Aether)
│   ├── encode-name.ae         # path → C-safe identifier
│   ├── infer-type.ae          # filename suffix → build/test/dist
│   ├── file-to-label.ae       # file path → build.begin() module label
│   ├── resolve-dep.ae         # dep reference → file path
│   ├── extract-deps.ae        # parse a .ae file's dep(b, "...") lines (+ --prereqs)
│   ├── scan-ae-files.ae       # walk cwd for every .*.ae build file
│   ├── topo-sort.ae           # DFS post-order over the file dep graph
│   ├── mvn-to-aeb.ae          # pom.xml → .build.ae migration helper
│   ├── cargo-to-deps-ae.sh    # Cargo.toml → .crate.ae dep files (migration)
│   ├── cargo-crate-to-ae.sh   # one crate → .crate.ae (migration)
│   └── resolver/              # Maven Resolver wrapper (→ aeb-resolve.jar)
├── tools/container/           # aeb-ctr (compile-in-container/execute-on-host) + image
├── itests/                    # integration tests (real open-source projects)
├── README.md
└── TODO.md
```

## Example repo

[google-monorepo-sim](https://github.com/paul-hammant/google-monorepo-sim)
— a simulated Google-style monorepo with Java, Kotlin, Go, Rust, C#,
TypeScript, and Python modules, cross-language FFI, JNI, and per-language
third-party deps. Everything builds and tests from a single `aeb`
invocation.

## Unit tests (`tests/`)

Command-string builder tests for every SDK — `javac_cmd()`, `cargo_build_cmd()`,
`go_build_cmd()`, `kotlinc_cmd()`, `junit_cmd()`, `lxc_cmd()`,
`image_build_cmd()`, `dockerfile_content()`. Each test constructs a config
map and asserts the generated command string matches expectations. No
external tools needed — pure string-builder testing.

Run locally on macOS or Linux:

```bash
./tests/run.sh              # all tests
./tests/run.sh cargo        # pattern filter — runs test_cargo_cmd only
AETHER=/path/to/ae ./tests/run.sh   # override ae binary
```

Output classifies each test as `BUILD OK / RUN PASS`, `BUILD FAIL`, or
`RUN FAIL`, so it's obvious whether a failure is a regression in aeb
or an upstream Aether compiler issue. Exits non-zero on any failure.

## Integration tests (`itests/`)

Real-world open-source projects converted from their native build systems
to aeb. Upstream sources are fetched via `itests/fetch-upstream.sh`
and not committed — only the `.build.ae`, `.tests.ae`, `.dist.ae`,
`.bom.ae`, and migration-status docs are tracked. Some repositories are
pinned to a specific commit to avoid source drift against unreleased
upstream dependencies.

### spring-data-examples (Maven → aeb)

Source: [spring-projects/spring-data-examples](https://github.com/spring-projects/spring-data-examples)
(pinned to commit `cd0d2b36`)

~90 leaf modules across JPA, MongoDB, Redis, Cassandra, JDBC, R2DBC, REST,
Web, and multi-store scenarios. Replaces 107 `pom.xml` files. Uses
`java.javac(b)` + `java.junit5(b)` with a Spring Boot BOM for version
management, TestContainers for integration tests (Podman-compatible).

### nx-examples (Nx → aeb)

Source: [nrwl/nx-examples](https://github.com/nrwl/nx-examples)

13 TypeScript modules — Angular 21 (ngc), React 18 (tsc), shared
libraries, Web Components. Uses `ts.tsc` / `angular.ngc` / `jest.test`.
npm deps resolved via pnpm.

### clojure-multiproject-example (deps.edn → aeb)

Source: [adityaathalye/clojure-multiproject-example](https://github.com/adityaathalye/clojure-multiproject-example)

6 Clojure modules — shared library (grugstack), 4 Ring/Jetty/SQLite web
apps, 1 stub. Replaces `deps.edn` aliases and `build/build.clj`
orchestration. Clojure's source-path classpath model is chained
transitively via a `clojure_src_path` artifact.

### scala-cli-multi-module-demo (scala-cli → aeb)

Source: [VirtusLab/scala-cli-multi-module-demo](https://github.com/VirtusLab/scala-cli-multi-module-demo)

3 Scala 3 modules — shared library + 2 apps. The Scala 3 compiler is
invoked directly (`java -cp dotty.tools.dotc.Main`), same as javac. No
scala-cli, Bloop, Coursier, or sbt — `aeb-resolve.jar` + `java` replaces
the entire stack.

### dotnet-architecture-eShopOnWeb (.NET solution → aeb)

Source: [dotnet-architecture/eShopOnWeb](https://github.com/dotnet-architecture/eShopOnWeb)

10 .NET projects — ASP.NET Core MVC, Blazor WASM, REST API, EF Core,
xUnit. Upgraded from .NET 8 to .NET 10. aeb **generates**
`.{name}.generated.csproj` files from `.build.ae` declarations — NuGet
via `dotnet.nuget_registry`, project refs via `build.dep()`.

### fyne-io/fyne (Go workspace → aeb)

Source: [fyne-io/fyne](https://github.com/fyne-io/fyne)

Multi-module Go workspace. Uses `go.go_build` / `go.go_test`.

### Oxen-AI/Oxen (Rust workspace → aeb)

Source: [Oxen-AI/Oxen](https://github.com/Oxen-AI/Oxen)

Large Rust workspace; exercises `rust.cargo_workspace` and
`rust.cargo_crate`, with `Cargo.toml` generation for both the workspace
root and every member crate. `crate_registry` handles dozens of
dependencies with feature flags.

### python-monorepo-demo (Pants → aeb)

Source: [SystemCraftsman/pants-python-monorepo-demo](https://github.com/SystemCraftsman/pants-python-monorepo-demo)

A small Python monorepo. Uses `python.install` / `python.pytest` with
`.whl.ae` dep files (`python.wheel_registry` / `wheel_vendored`).
`python.package(b)` generates `pyproject.toml` at build time — no
hand-written packaging metadata.

### mrhdias_rust_store (Tokio → aeb)

Source: [mrhdias/store](https://github.com/mrhdias/store)

A small Tokio/axum Rust project. Single-crate `Cargo.toml` generation.

## Requirements

- [Aether](https://github.com/AetherLang/aether) compiler (`ae`) —
  recent enough to include the `hoist_loop_vars` and parameter-redeclare
  fixes in `codegen/`.
- Language toolchains for whatever you build: `javac`, `kotlinc`, `go`,
  `cargo`, `tsc`/`node`, `scala` (Scala 3 compiler jar), `clojure`,
  `dotnet` SDK, `python3`, `pnpm`, `dart` SDK, `moon` (MoonBit),
  `gleam`, `c++`/`clang++`/`g++`, `swift`, `zig`.
- For Java projects with Maven deps: build the resolver jar once —

### macOS notes

`aeb` itself works on macOS — the bash trampoline uses only POSIX-level
features and the orchestration has been ported to Aether, so nothing in
the runner path requires GNU bash or GNU coreutils. You can run
`./tests/run.sh` (the unit-test runner) straight from a vanilla macOS
install.

There is one known limitation for full multi-module builds: the link
step in `tools/aeb-link.ae` passes `-Wl,--allow-multiple-definition`,
which is GNU ld only. Apple's ld64 rejects it, and a full `./aeb` run
that links more than a handful of modules will fail with duplicate
symbol errors until that flag is platform-gated or the underlying
duplicate-symbol emission is fixed upstream in the Aether compiler.
See `TODO.md` for tracking.

Container-related SDKs also have reduced functionality on macOS:
Docker Desktop or Podman is required for image builds, and LXC is
Linux-only. All other SDKs (Java, Kotlin, Go, Rust, TypeScript, Scala,
Clojure, .NET) work identically to Linux.

  ```bash
  mvn -f tools/resolver/pom.xml package
  mv tools/resolver/target/aeb-resolve-1.0.0.jar tools/aeb-resolve.jar
  rm -rf tools/resolver/target
  ```
- For TestContainers-based tests: Docker or Podman. aeb auto-detects the
  user-level Podman socket.
