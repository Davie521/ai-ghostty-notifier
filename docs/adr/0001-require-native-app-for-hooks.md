# ADR-0001: Require the native app for hooks

**Date**: 2026-09-16
**Status**: accepted
**Deciders**: Yifan, with Codex implementation/review support

## Context

Shell is a suitable stable command entrypoint for Claude/Codex hooks, but the
notification implementation had accumulated JSON parsing, state, locks, process
watchers and terminal recovery logic there. Moving only the resident path to
Swift left a second complete shell implementation to maintain and test. The
project already packages a native macOS app, whose executable can also run as a
short-lived hook process and a temporary worker.

## Decision

Require installation of ClaudeGhosttyNotify.app and keep shell only as thin,
stable launchers. Use the app's same Swift executable for resident, hook and
fallback-worker modes; do not install or execute a complete pure-shell fallback.
The user explicitly accepted this installation contract on 2026-09-16.

Installed does not mean always running: a hook can invoke the executable without
a resident process. When resident delivery is unavailable, native fallback needs
an available external notification backend. If the app itself is missing, hooks
drain stdin, report the missing runtime and exit successfully without notifying.

## Alternatives Considered

### Keep an optional app and complete shell fallback

- Pros: source-only hook installations remain usable without the native app.
- Cons: duplicate state, concurrency, terminal and delivery behavior persists.
- Why not: this prevents the requested substantive reduction in shell logic.

### Replace shell business logic with a Python hook client

- Pros: convenient JSON and general-purpose language support.
- Cons: adds a per-hook interpreter and still needs macOS-specific integration.
- Why not: the existing Swift executable can own both native and fallback paths
  without adding another runtime client.

## Consequences

### Positive

- One typed implementation owns policy, process identity, terminal binding,
  journals and cleanup, with injectable boundaries and native executable tests.
- Existing launcher names and hook definitions remain stable where possible.
- jq, Python and business-shell helpers are absent from per-hook execution.

### Negative

- Installing/upgrading requires a built and signed native app before the hooks.
- Removing the app disables notifications; there is no source-only fallback.
- Private focus/clear script substitutions are retired in favor of native
  operations. Build/install glue can still use shell; the Codex installer can
  still use Python.

### Risks

- Mixed versions: require the native-hook capability marker during installation
  and check the live resident's PID-bound protocol capability before handoff.
- Failed installation: stage and verify the bundle before replacement; restore
  the previous copy if publication fails. Install to Application Support so a
  moved checkout does not invalidate the runtime path.
- No available delivery backend: report diagnostics; do not claim that merely
  having the app installed guarantees visible notifications without permissions
  or a usable resident/external backend.
- Automated checks do not establish real banner, sound or tab-jump behavior;
  those remain manual release acceptance checks.

The settings the native runtime honors, and the ones it retired, are listed
under [configuration](../reference.md#configuration).
