# Spike: ScreenCaptureKit frame delivery while locked

**Hardware:** Mac mini (Macmini9,1), Apple M1
**macOS:** 26.5.1 (build 25F80)
**Date:** 2026-08-24

## Procedure

Ran `spikes/locked-capture/locked-capture` from a terminal with Screen
Recording permission granted. Once capturing at the configured ~10fps cap,
locked the screen with Ctrl-Cmd-Q, left it locked, then unlocked with the
account password.

## Result

**Frames continued while the screen was locked.** The per-second frame count
stayed steady at the configured ~10/sec cap across the entire lock/unlock
cycle — no drop to zero, no `SCStreamErrorDomain` error, no gap in the log.

## Answer to spec §8 open question (1)

On this hardware/OS combination, `ScreenCaptureKit` delivers frames while the
screen is locked without any special entitlement or configuration. Task 10 can
set `isAvailableWhileLocked = true` without needing a restart-on-unlock path or
a second capture backend for this case.

## Caveats

- Single data point: one Mac mini (M1) on macOS 26.5.1. Not verified on other
  chip generations or macOS versions — behavior here may be a `26.5.1`-era
  ScreenCaptureKit policy that differs from Sonoma (14.0, the plan's floor).
- Locked with the account password from a terminal session already granted
  Screen Recording; login-window / pre-authentication capture was not tested.
- Only observed continuity, not any timing/resolution changes ScreenCaptureKit
  might apply while locked (e.g. reduced frame rate under other conditions).
