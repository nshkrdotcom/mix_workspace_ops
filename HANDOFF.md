# MWO P9 runtime-correction checkpoint

Updated 2026-09-07. P9 remains open; P10 has not started.
The checkpoint commit containing this file supersedes the August vNext handoff.

Programme continuation:
`/home/home/p/g/n/brainstorms/nshkrdotcom/docs/20260823/mwo_portfolio_registry_weld_architecture_review/00_CONTINUATION_PROMPT.md`

Read that file first. It records scope, exact verification, remaining acceptance,
and the operator's instruction to pause after committing this checkpoint.

## Current implementation

- Registry/view v2 only; portable operation plan v3; source context v4; probe
  metadata cache v4. No legacy schema reader or migration.
- Stable external dependency contexts and project-specific build contexts.
  Mix owns extraction, checkout and compilation. Cooperating processes share a
  private temporary root and Mix's path-scoped lock namespace.
- First-class `setup`, `compile`, and `test` share the plan/fanout path.
  Population runs once per dependency context. Compile/test wait for population,
  then run in dependency order. Test defaults to the test environment.
- Binding/execution preserve independent successes and block dependants.
  Fresh-plan failure isolation still needs work; see the continuation.
- Successful operational locks persist. Failed command mutations are discarded;
  private peer lockfiles and retained context locks are installed atomically.
  The checkout lockfile is not implicitly modified.
- Authoritative metadata persists by exact source, environment/target, dependency
  scope, toolchain and schema. Nonexcluded ignored source participates in the
  digest. Prewarming shares one repository stage and invocation source snapshot.
  Probes receive replacement environments and disposable source trees.
- Central root projection reaches unmodified transitive declarations, retaining
  original requirements and semantic options. Unfulfilled transitive optional
  dependencies are not promoted into required root dependencies.
- Hex archives are retained by repo/package/version/outer checksum and copied
  into native context cache views. Different checksums coexist; malformed objects
  are quarantined. Mix/Hex retain resolution and extraction responsibility.
- Git mirrors retain pinned commits. Installed origins and reports omit URL
  credentials; refresh uses the remote supplied by the current operation.
- ResourceBudget derives defaults from detected schedulers/load/memory.
  Propagating one snapshot across the full CLI invocation remains unfinished.
- Complete child logs and a detailed report persist outside repositories; normal
  stdout is a compact summary. State listing/GC includes command reports.
- Client code stays at the tuple-first `workspace_dep(committed)` seam with
  normal standalone defaults. This correction adds no application-repo code.

## Verification and compatibility

Local verification uses Elixir/Mix 1.20.3 and OTP 29.0.5. Exact results and failed
attempts are in the programme checkpoint report. Fixture success does not imply
live portfolio acceptance.

At this checkpoint: 445 tests passed, 1 intentional skip, in 133.5 seconds;
format, warnings-as-errors compile, strict Credo, Dialyzer, docs, escript,
CLI help/version and diff checks passed. One earlier preparation timeout did not
reproduce in the 80-test affected pass or the final full run; its cause remains
unproven and its evidence is preserved in the programme report.

Private Mix boundaries are explicit: `Mix.Sync.Lock`,
`Mix.ProjectStack.post_config/1`, and `Mix.ProjectStack.merge_config/1`.
The declared minimum Elixir 1.19 compatibility run remains required before release.

Blitz is pinned to source commit
`5dfbeae6a75ea91ca0b05239c0bad98614861f19` for complete output-path support.
This is the actual dependency pin; tests do not bake in that version.

## Next work

Finish the remaining review and focused performance gates in the continuation.
Then run representative live lifecycle operations and the gated whole-selection
setup/compile acceptance. Close P9 only after rollout reconciliation, review and
re-verification. P10 consumes accepted MWO behavior and must not add a second
scheduler, resolver, cache or failure model.
