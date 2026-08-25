# Running RDPie — Phase 4 (NLA/CredSSP)

## What changed

`crates/rdpie-core/src/server.rs` switches the RDP listener from plain TLS
security to Hybrid (CredSSP/NLA): `.with_hybrid(acceptor, identity.pub_key)`
instead of `.with_tls(acceptor)`, and `server.set_credentials(...)` instead
of `.with_credential_validator(...)` (TLS-mode-only per upstream's own doc
comment).

This was found live during Phase 3 testing: every RDP client offers
`SSL | HYBRID | HYBRID_EX`, but the server always responded with plain
`SSL` only. Windows' own `mstsc` client never showed a credential prompt
at all under that — instead of asking for RDPie's username/password, it
silently attempted a non-interactive auto-logon with the current Windows
session's identity, which was never going to match RDPie's dedicated
credential and always failed with "Credential validation rejected".

No NT-hash precomputation was needed, unlike the fuller design in the
spec's §3.5 (deriving and Keychain-storing an NT hash ahead of time):
upstream's own CredSSP/NTLM implementation derives what it needs from the
plaintext password internally, the same `Credentials{ username, password,
domain }` value already used for the old TLS-mode validator.

## Build

```sh
just build
```

## Run

```sh
RDPIE_PASSWORD=<password> RDPIE_USERNAME=<username> RDPIE_BIND_ALL=1 RUST_LOG=debug just run
```

## Verification checklist for a live pass

- [x] Connect from Windows' native Remote Desktop Connection (`mstsc`). A
      Windows Security credential prompt should appear *before* the RDP
      handshake proceeds — that's the tell CredSSP is actually being
      offered, not falling back to plain TLS. Enter the RDPie
      username/password there. Confirmed live: the prompt appeared,
      RDPie's credentials were accepted, and the session came up showing
      the real desktop.
- [ ] Confirm a wrong password is rejected (no session established).
- [x] Confirm the right password connects successfully and the session
      behaves as it did before this change (display works — confirmed
      live; input/EGFX not re-verified in this pass).
- [ ] Confirm a non-Windows client that was working before (e.g. the
      Android client from Phase 3 testing) still connects fine.

Automated coverage (`cargo test -p rdpie-core`, including the
`connect.rs` integration test) passes as of this change, but none of it
exercises a real CredSSP handshake against a real client — the checklist
above is the actual verification this feature needs.
