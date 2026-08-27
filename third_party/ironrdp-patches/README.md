# Local patches for third_party/ironrdp

The `third_party/ironrdp` submodule stays pinned to a clean, unmodified
upstream commit (see `third_party/README.md`) so a fresh clone can always
fetch it. Local fixes that haven't made it upstream yet live here instead,
as ordinary `git am`-compatible patch files, applied on top at build/setup
time by `just ironrdp-patches`.

## Why not just commit the fix into the submodule?

A commit made directly in the submodule's local checkout only exists in
that one clone -- `.gitmodules` still points at
`https://github.com/Devolutions/IronRDP.git`, so `git submodule update` on
any other machine (a fresh clone, CI) would try to fetch a commit that was
never pushed there and fail. Keeping the pin on a real upstream commit and
carrying the diff as a patch file in this repo instead means the fix
travels with `git clone` like any other tracked file, no fork or extra
remote required.

## Applying

```sh
just ironrdp-patches
```

Resets the submodule to its pinned commit and applies every `*.patch` file
here, in order. Safe to re-run any time. Run it after any
`git submodule update` (including the first `--init`) and before building.

## Resetting

```sh
just ironrdp-patches-reset
```

Resets the submodule to its pinned commit *without* reapplying the
patches -- back to a plain, vanilla upstream checkout. Useful to confirm a
bug isn't caused by one of these patches, or as step 3 below when adding a
new one. `just ironrdp-patches` itself is just this plus `git am`.

## Adding a new patch

1. Make the fix as a normal commit inside `third_party/ironrdp` (write a
   real commit message -- it becomes the patch's own commit message, and
   ideally becomes the commit message of the eventual upstream PR).
2. `git format-patch --zero-commit --no-signature -1 <commit> --start-number N -o third_party/ironrdp-patches`,
   where `N` is one more than the highest existing patch number.
3. `just ironrdp-patches-reset`, so the parent repo's gitlink stays on the
   clean upstream commit, not on your local patch commit.
4. Commit the new `.patch` file (and nothing else under
   `third_party/ironrdp`) in the parent repo.

## Upstreaming

Each patch here is a candidate for a real PR against
`Devolutions/IronRDP`. To upstream one: apply it on a fresh clone of
upstream (`git am path/to/000N-*.patch`), push that branch to a fork, and
open the PR there. Once it's merged and released, bump the pin in
`third_party/README.md` / `.gitmodules` past that release and delete the
now-redundant patch file from this directory.

## Current patches

| File | What it fixes |
|---|---|
| `0001-fix-set-TCP_NODELAY-on-accepted-server-connections.patch` | Sets `TCP_NODELAY` on accepted server connections (found live-testing Phase 4). |
| `0002-fix-translate-the-middle-button-flag-on-the-standard.patch` | `impl From<MousePdu> for MouseEvent` never checked the middle-button flag on the standard pointer PDU, so a middle click was silently reinterpreted as a mouse move. |
