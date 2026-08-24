# Spike: does OpenPAM authenticate a local macOS account from an unprivileged process?

**Hardware:** Mac mini (Macmini9,1), Apple M1
**macOS:** 26.5.1 (build 25F80)
**Date:** 2026-08-24

## Procedure

Built a small C/Swift bridge (`pam-bridge.c`/`.h`, `main.swift`) calling
`pam_start("login", username, &conv, &handle)` then `pam_authenticate(handle,
0)`, with a conversation callback that hands PAM the password already
collected (echo disabled) on stdin — no PAM prompting/logging of the
password itself. Ran as a plain, unsigned, unprivileged CLI binary from an
interactive terminal session (no elevated privileges, no special
entitlements).

## Result

- **Works.** A deliberately wrong password returned PAM error code `9`
  (`PAM_PERM_DENIED`), not a crash or an "operation not permitted"-style
  failure — confirming PAM itself ran the real authentication check rather
  than failing before it got that far.
- The real account password returned `0` (`PAM_SUCCESS`).

## Answer to spec §3.5 / Phase 3 open question

`pam_authenticate()` against the `login` PAM service genuinely verifies a
local macOS account's password from an ordinary unprivileged, unsigned
process — no special entitlement, code signature, or elevated privilege was
needed on this macOS version. This is the mechanism spec §3.5's optional PAM
gate (before granting input control) can build on directly.

## Caveats

- Single data point: one Mac, one macOS version, one local (non-managed,
  non-MDM) account. Not verified against an MDM-managed account, a
  Mobile/network account, or with SIP/other hardening profiles that might
  restrict PAM differently.
- Only the `login` PAM service was tried. RDPie's actual implementation
  should confirm this is the appropriate service name to use (vs. e.g.
  `authorization`, `sudo`, or a dedicated custom PAM service file) —
  `login`'s policy is a reasonable default but wasn't compared against
  alternatives.
- The daemon's eventual real identity (signed, running via `SMAppService`
  as a LaunchAgent, Phase 7) is not what was tested here — this spike ran
  as a raw terminal process. PAM's local-account policy is not expected to
  differ by caller identity the way TCC does, but this wasn't re-verified
  under the packaged daemon's actual runtime identity.
