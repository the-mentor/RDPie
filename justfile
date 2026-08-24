# cargo-installed tools (cbindgen) live here; not every shell has it on PATH.
export PATH := env_var('HOME') + "/.cargo/bin:" + env_var('PATH')

default:
    @just --list

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
