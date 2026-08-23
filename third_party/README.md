# third_party

Vendored dependencies tracked as git submodules.

## ironrdp

Upstream: https://github.com/Devolutions/IronRDP (MIT OR Apache-2.0)

Pinned to tag `ironrdp-server-v0.13.0`, which matches the `ironrdp-server`
0.13.0 release on crates.io.

### Why a submodule and not just a crates.io dependency

RDPie depends on `ironrdp-server` for its RDP protocol stack. Under normal
circumstances a plain crates.io dependency would be enough. The submodule
exists for two reasons:

1. **Patchability.** Prior art (MacRDP) had to fork `ironrdp-server` to add
   GFX/AVC444 support. Having upstream source in-tree means a patch is a local
   edit rather than a fork-and-republish exercise.
2. **Readability.** `ironrdp-server` is an extension skeleton — implementing
   `RdpServerDisplay`, `RdpServerDisplayUpdates` and `RdpServerInputHandler`
   correctly means reading upstream source regularly.

Note that as of 0.13.0 the fork rationale above is largely historical: upstream
now ships an `egfx` feature with `send_avc420_frame()` / `send_avc444_frame()`,
so the capability MacRDP forked for is available without patching. The submodule
is insurance, not a requirement.

### How this is wired into Cargo

The workspace declares a normal crates.io dependency, with the submodule bound
in via `[patch.crates-io]`:

```toml
[dependencies]
ironrdp-server = "0.13"

[patch.crates-io]
ironrdp-server = { path = "third_party/ironrdp/crates/ironrdp-server" }
```

This keeps routine version bumps a one-line change to the version requirement,
while local patches to the submodule take effect immediately. Dropping the
`[patch.crates-io]` block falls back to stock upstream with no other edits.

Keep the submodule tag and the declared version in sync — `[patch.crates-io]`
only applies when the patched crate's version satisfies the requirement.

### Updating

```sh
cd third_party/ironrdp
git fetch --tags
git checkout ironrdp-server-vX.Y.Z
cd ../..
git add third_party/ironrdp
```

Then bump the `ironrdp-server` version requirement to match.
