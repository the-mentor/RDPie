# cargo-installed tools (cbindgen) live here; not every shell has it on PATH.
export PATH := env_var('HOME') + "/.cargo/bin:" + env_var('PATH')

default:
    @just --list

# Resets the ironrdp submodule to its pinned upstream commit, discarding any
# applied patches (or other local edits) in the checkout. Safe to re-run any
# time; aborts a half-finished `git am` first so a previous failed patch
# apply never lingers. Useful on its own to get back to a clean, vanilla
# upstream tree -- e.g. to confirm a bug isn't caused by a local patch, or
# per third_party/ironrdp-patches/README.md's "Adding a new patch" step 3.
ironrdp-patches-reset:
    #!/usr/bin/env bash
    set -euo pipefail
    pin=$(git rev-parse HEAD:third_party/ironrdp)
    cd third_party/ironrdp
    git am --abort >/dev/null 2>&1 || true
    git checkout -f "$pin"

# Resets the ironrdp submodule (see ironrdp-patches-reset above), then
# applies this repo's local patches on top (third_party/ironrdp-patches/)
# via `git am`. Safe to re-run any time. Run this after `git submodule
# update` (including the first `--init`) and before building: the submodule
# itself stays pinned to a clean, fetchable upstream commit; these patches
# are what actually put the local fixes (e.g. TCP_NODELAY, middle-click) in
# the tree you build against. See third_party/ironrdp-patches/README.md.
ironrdp-patches: ironrdp-patches-reset
    #!/usr/bin/env bash
    set -euo pipefail
    cd third_party/ironrdp
    shopt -s nullglob
    patches=(../ironrdp-patches/*.patch)
    if [ ${#patches[@]} -gt 0 ]; then
        git am "${patches[@]}"
    fi

# Build the Rust core (release) and regenerate the C header for Swift.
build-rust:
    cargo build -p rdpie-core --release
    cbindgen --config crates/rdpie-core/cbindgen.toml --crate rdpie-core \
        --output macos/Sources/CRdpieCore/include/rdpie_core.h

# Build the Swift package. Always forces a relink first, since SwiftPM
# doesn't track librdpie_core.a as a build input and will silently skip
# relinking against a freshly rebuilt Rust core otherwise. Filters out the
# expected, harmless "was built for newer macOS version" linker warnings —
# the Rust build targets the host OS, the Swift package targets 14.0, and
# that mismatch is not a real problem (see docs/running-phase-1.md).
build-swift: build-rust
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f macos/.build/debug/rdpied macos/.build/arm64-apple-macosx/debug/rdpied
    swift build --package-path macos 2>&1 | grep -v "was built for newer 'macOS' version"

build: build-swift

# Generate a self-signed dev cert/key under macos/, if not already present.
cert:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f macos/cert.pem ] || [ ! -f macos/key.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout macos/key.pem -out macos/cert.pem \
            -days 365 -subj "/CN=rdpie"
    fi

# Run against the real display. Requires RDPIE_PASSWORD in the environment.
run: build cert
    cd macos && RDPIE_PASSWORD="${RDPIE_PASSWORD:?set RDPIE_PASSWORD}" ./.build/debug/rdpied

# Run against a synthetic colour-changing feed instead of the real screen —
# useful for isolating protocol issues from capture issues.
run-synthetic: build cert
    cd macos && RDPIE_SYNTHETIC=1 RDPIE_PASSWORD="${RDPIE_PASSWORD:?set RDPIE_PASSWORD}" ./.build/debug/rdpied

test-rust:
    cargo test -p rdpie-core

test-swift:
    swift test --package-path macos

test: test-rust test-swift

clean:
    cargo clean
    rm -rf macos/.build
