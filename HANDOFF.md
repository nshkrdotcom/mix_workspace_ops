# MWO vNext acceptance handoff

Updated 2026-08-31 after executable review of commit
`c1a0e41cd566de3c1d987e51dd0c7c7ee5a2bb64`.

This repository already contains the vNext implementation. It is not an overlay
and requires no apply script, deletion manifest, or ZIP. Earlier text claiming
that `APPLY_OVERLAY.sh`, `DELETE_PATHS.txt`, or `MWO-vNext-overlay.zip` existed was
stale generation-environment metadata; none of those artifacts is part of this
repository or needed to continue.

## Accepted architecture

- Only Portfolio Registry registry/view v2 contracts are active.
- Operator source preferences live in XDG configuration and contain only an
  eligible source mode. Registry data remains the source of coordinates.
- MWO does not replace Hex or Mix dependency materialization. Hex's machine cache
  is shared through the managed XDG cache; dependency trees are stable external
  contexts selected by exact effective dependency identity.
- Git mirrors are transport caches. Mix owns dependency checkouts and lockfile
  semantics; mirrors retain pinned commits and quarantine malformed state.
- Build contexts are stable, external, project-specific, and reusable across
  checkout moves and normal source edits. Different projects never share build
  state.
- Managed children share one operator-private temporary root so Mix processes
  that use the same dependency/build path also share Mix's lock namespace.
- Different build contexts execute concurrently. Operations sharing one build
  context hold Mix's cross-process lock for the complete child command, preventing
  a later compile from replacing artifacts while an earlier test/run still uses
  them.
- HOME, configuration, operational lockfile, lease, and report state remain
  invocation-private. Publication credentials are removed from ordinary child
  environments. The checkout's `mix.lock` is never implicitly written.
- Dependency declarations observed from the actual Mix project under effective
  env/target are fingerprinted into dependency-context identity. This prevents
  unlocked external dependency requirements from colliding merely because their
  lockfiles and managed-source rows are empty.
- Dependency impact comes from probed Mix dependency declarations, not from the
  registry source table. Incomplete coverage widens affected execution to the
  explicit base scope.
- Frozen operation plans bind dependency-index, impact, source, toolchain, and
  scope semantics and refuse material drift on replay.
- Release preflight derives production publish topology from the actual clean
  checkout before gates or publication.

## Corrections made during executable review

The imported implementation had not been formatted, compiled, or run. Review
fixed these concrete defects:

1. Compile/type defects in source preferences, CLI clauses, bootstrap module
   references, lock digest argument order, and dependency-index fixtures.
2. Stale assertions and fixtures left from registry/view v1 and pre-vNext source
   semantics.
3. Explicit source-mode aggregation so typed ineligible/unavailable reasons are
   preserved.
4. The documented carrier seam and its executable fenced-block test now describe
   the same tuple-first contract.
5. Dependency-context collisions between unlocked projects with different active
   dependency declarations.
6. A locking defect caused by invocation-private `TMPDIR`: Mix keys its lock files
   under the system temporary directory, so separate private temporary roots
   silently defeated cross-process locking for identical paths.
7. A wider concurrency defect: Mix's compilation lock ends before a long-running
   test/run finishes using build artifacts. Fanout now holds the same lock for the
   complete command when the build context is shared, while distinct contexts
   remain parallel.
8. Unreachable/unused public surface and strict Credo/Dialyzer findings.
9. The original handoff's false overlay-artifact and private-API claims.

## Executable evidence

Validated with Elixir 1.20.3, OTP 29.0.5, and Mix 1.20.3:

```text
mix format --check-formatted          PASS
mix compile --warnings-as-errors      PASS
mix test --warnings-as-errors         PASS — 372 passed, 1 skipped
mix credo --strict                    PASS — 0 issues
mix dialyzer                          PASS — 0 errors/skips
mix docs                              PASS
mix escript.build                     PASS
./mix_workspace_ops version           PASS — 0.1.0
./mix_workspace_ops help              PASS
git diff --check                      PASS
```

Acceptance tests include real Mix subprocesses for:

- warm Git-mirror reuse without the origin;
- standalone unmanaged Mix behavior;
- dependency/build reuse across checkout relocation and source edits;
- incompatible dependency declarations selecting different contexts;
- identical declarations sharing dependency state without cross-project build
  sharing;
- shared Hex package cache with private Hex config/data homes;
- different build contexts compiling concurrently;
- identical Mix build mutations serializing;
- separate full MWO commands sharing a build context serializing;
- actual production dependency topology; and
- replay refusal after actual dependency removal.

The built escript also validated the live Portfolio Registry v2 document:

```text
273 repositories
726 projects
717 applications
2 multiply-provided applications
12 release packages
```

The live `dependency_sources` view selected 43 repositories and 427 projects.
Residue scans found no production/documentation reference to removed `HexCache`,
`ExactHexSCM`, `MIX_WORKSPACE_OPS_EXACT_HEX`, or `Mix.Dep.Loader` mechanisms.

## Compatibility surfaces and residual follow-up

MWO intentionally relies on two non-public Mix surfaces:

- `Mix.Sync.Lock` for context, mirror, and complete-operation coordination; and
- `Mix.ProjectStack.post_config/1`, isolated in bootstrap `LockfileCompat`, for
  the external operational lockfile.

Both work on the validated toolchain and must remain explicit compatibility gates
for every supported Elixir/Mix version. The project declares Elixir `~> 1.19`; the
same acceptance subset should also run on the minimum supported 1.19 toolchain in
CI before a release.

The source packet's named `13_ACCEPTANCE_TESTS.md` was not present anywhere in the
workspace, so its claimed 64-item list could not be checked item-for-item. The
repository suite and targeted real-subprocess scenarios above are the executable
evidence available here; do not claim a literal 64/64 result without that packet.

The CLI remains one central module. A behavior-neutral physical split may be done
later, but it is not an acceptance blocker.

## Next programme unit

Record this accepted vNext pivot in the architecture-review state and continuation
documents, then resume P9 from its item-zero rollout inventory. P9 must generate
the minimal tuple-first carrier seam from MWO, preserve standalone committed
dependencies, use one scoped commit per carrier repository, and never publish a
Hex package. P10 follows after P9 closure.
