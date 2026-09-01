# MWO vNext Implementation Handoff

This archive is an overlay against the exact MWO baseline supplied as
`repomix-output(20260831-223547).xml`. It is not a full source distribution.

## Snapshot basis

- Baseline: exact reconstruction of the supplied Repomix `<file path="...">` entries.
- Baseline size: 109 repository files.
- Baseline reconstruction method: each packed file was written back to its exact repository-relative path; a local Git baseline commit was created only to derive the implementation diff, deletion manifest, and overlay mechanically.
- Project-declared toolchain contract: Elixir `~> 1.19` (`mix.exs`), Mix application version `0.1.0`.
- Baseline Mix commands were **not run** because this execution environment contains no `elixir`, `mix`, or `erl` executable. Attempts to obtain a compatible toolchain were blocked by the environment's outbound package/network restrictions.
- No baseline test failure can therefore be distinguished from an implementation regression in this environment; the next QC agent must establish the executable baseline/final comparison on a real supported Elixir installation.

## Scope completed

The source overlay implements the MWO-only vNext refactor specified by the packet, using the supplied repository as the foundation rather than replacing it. The implemented source surface covers:

- canonical registry/view v2-only loading and explicit legacy rejection;
- verified local identity/binding retained separately from portable registry data;
- XDG-owned persistent source preferences with registry-declared source eligibility;
- deletion of the custom exact-Hex archive/cache/SCM subsystem;
- narrow literal lockfile parsing/projection/audit in place of dependency-object management;
- retained Git mirrors as transport-only optimization beneath ordinary Mix Git semantics;
- selected-scope authoritative dependency indexing from real Mix project metadata;
- reverse dependency impact, explanation paths, coverage accounting, and repository aggregation;
- affected-only selection with conservative full-base-scope fallback when dependency coverage is incomplete;
- operation plan v2 with affected/dependency-index semantics and strict drift refusal on replay;
- simplified external dependency/build context identity that excludes checkout root and target HEAD/dirt from reusable cache keys;
- retained Blitz fan-out ownership and complete report flow;
- release topology verification against actual publish-relevant managed Mix dependencies in the clean release checkout before gates/publication;
- drift/doctor/report updates and documentation/CLI parity for the new architecture.

The implementation source and tests were statically audited here, but the packet's executable acceptance gates cannot truthfully be marked passed because Mix/BEAM is unavailable in this container. The final QC agent must run the full suite listed below.

## Major architecture changes

### Registry/view compatibility

Only `portfolio_registry.registry/v2` and `portfolio_registry.view/v2` remain active registry/view schemas. Legacy `mix_workspace_ops.registry/v1` and `mix_workspace_ops.view/v1` normalization paths were removed; tests now retain those identifiers only to prove rejection.

### SourcePreferences and managed-repo write removal

`MixWorkspaceOps.SourcePreferences` replaces checkout-local `LocalOverrides`. Persistent preferences live under XDG operator configuration, are keyed by consumer project + application, and contain only the desired eligible mode (`local`, `git`, or `hex`). They never persist local paths, Git coordinates, Hex requirements, or credentials. `mwo use` validates registry source eligibility before writing; an eligible source may be preferred even when it is not currently available. Local identity/path still comes from verified binding/ledger data.

### Exact-Hex/custom-SCM removal

`MixWorkspaceOps.HexCache`, retained Hex objects/manifests, bootstrap `ExactHexSCM`, `MIX_WORKSPACE_OPS_EXACT_HEX`, and `Mix.Dep.Loader` integration were removed. Ordinary Hex fetching/materialization is delegated to Mix/Hex. Git mirrors remain only as transparent transport caches.

### Lockfile/runtime/cache simplification

`MixWorkspaceOps.Lockfile` safely parses only a literal top-level lock map, can remove top-level entries corresponding to active local path substitutions, and computes a lock audit digest. It does not fetch, normalize, or materialize dependency objects.

Reusable dependency-context identity is based on compatibility-causing source/lock/toolchain/Mix inputs, not the absolute checkout root or target source HEAD/dirt. Build-context identity remains project-specific while permitting Mix incremental compilation within a stable context. Invocation-private HOME/config/lock/report state remains private. The only private Mix API reference is isolated in the bootstrap `LockfileCompat` bridge around `Mix.ProjectStack.post_config/1`.

### DependencyIndex and Impact

`MixWorkspaceOps.DependencyIndex` probes selected projects using the existing isolated real-Mix project probe path, classifies dependency edges through canonical registry provider rules, and records selected/probed/absent/failed/excluded coverage. Missing or unprobeable projects are unknown rather than empty dependency lists.

`MixWorkspaceOps.Impact` resolves project/repository/application targets, traverses reverse managed dependency edges, records direct/transitive affected projects and explanation paths, aggregates repositories, and exposes coverage/safety. `MixWorkspaceOps.Selection` turns that result into the affected execution set.

### Affected selection and conservative incomplete-coverage fallback

When dependency-index coverage is complete, `--affected TARGET` selects the affected subset within the explicit base scope. When coverage is incomplete, selection widens to the complete base scope and records the fallback reason instead of risking a false-negative test scope.

### Plans/replay

Operation plans use `mix_workspace_ops.plan/v2`. A frozen plan carries portable scope/impact/dependency-index/source semantics without local runtime paths or credentials. Replay reconstructs current semantics and refuses named material drift rather than silently replanning. There is no generic force-through-drift path.

### Release topology verification

Release transaction architecture remains intact. Clean-checkout preflight now derives publish-relevant managed dependencies from actual Mix project metadata under production inputs and checks them against the release prerequisite closure before gates/publisher invocation. A missing required managed publish prerequisite blocks the release; dev/test-only dependencies do not create false production prerequisites.

### CLI/report changes

Added first-class `impact` and affected `plan`/`run` selection. Removed obsolete permanent `inventory`, `registry examples`, and legacy `release publish` surfaces. `mwo use` now writes only operator-owned source preferences. CLI/report output carries impact coverage/fallback and updated drift severity semantics. The CLI remains one central module rather than being physically split into command files; see Intentional deviations.

### Doctor/drift/documentation

Drift observations now carry severity; identity contradiction remains fatal while ordinary absence/unprobeable/dirty/default-branch development facts can be warnings/status instead of universal failure. README, architecture/operator/release guides, contract examples, changelog, docs extras, delegated runner example, and CLI usage were rewritten for vNext. A new dependency-impact guide documents the graph/affected workflow.

## Added files/modules

- `APPLY_OVERLAY.sh` — safe deterministic deletion application after overlay extraction.
- `DELETE_PATHS.txt` — exact mechanically-derived baseline deletion list.
- `guides/dependency_impact.md` — user-facing dependency index/impact/affected workflow.
- `lib/mix_workspace_ops/dependency_index.ex` — selected-scope authoritative dependency index and coverage.
- `lib/mix_workspace_ops/impact.ex` — reverse impact target resolution/traversal/reporting.
- `lib/mix_workspace_ops/lockfile.ex` — narrow literal lock parsing/path projection/audit.
- `lib/mix_workspace_ops/selection.ex` — normalized affected selection and conservative fallback.
- `lib/mix_workspace_ops/source_preferences.ex` — XDG machine-local source mode preferences.
- `test/mix_workspace_ops/dependency_index_test.exs` — dependency classification/coverage tests.
- `test/mix_workspace_ops/impact_test.exs` — reverse traversal/path/coverage tests.
- `test/mix_workspace_ops/lockfile_test.exs` — literal parse/projection/digest/refusal tests.
- `test/mix_workspace_ops/source_preferences_test.exs` — strict XDG preference persistence tests.
- `HANDOFF.md` — this final QC handoff.

## Changed files/modules

### Production/build/bootstrap

- `lib/mix_workspace_ops.ex` — vNext operator-tool module documentation.
- `lib/mix_workspace_ops/cli.ex` — impact/affected/source-preference surfaces, legacy command removal, updated reporting/options.
- `lib/mix_workspace_ops/discovery.ex` — discovery output no longer masquerades as legacy registry data.
- `lib/mix_workspace_ops/doctor.ex` — severity-aware development health/status.
- `lib/mix_workspace_ops/drift.ex` — typed severity and revised reconciliation semantics.
- `lib/mix_workspace_ops/fanout.ex` — plan-controlled affected execution/runtime simplification while retaining Blitz scheduling.
- `lib/mix_workspace_ops/git_cache.ex` — transport-only lock Git object extraction/mirror handling.
- `lib/mix_workspace_ops/graph.ex` — graph logic aligned with canonical dependency/provider truth.
- `lib/mix_workspace_ops/operation_plan.ex` — plan v2 scope/index/impact/replay drift semantics.
- `lib/mix_workspace_ops/operator_paths.ex` — canonical XDG source-preferences path.
- `lib/mix_workspace_ops/overlay.ex` — smaller source overlay, no exact-Hex assumptions, stable semantic context identity.
- `lib/mix_workspace_ops/project/probe_tree.ex` — probe/runtime integration updates.
- `lib/mix_workspace_ops/registry.ex` — provider/selection support for new dependency/index flows.
- `lib/mix_workspace_ops/registry/contract.ex` — v2-only/current target validation changes.
- `lib/mix_workspace_ops/registry/document.ex` — legacy registry normalization removal.
- `lib/mix_workspace_ops/release/chain.ex` — prerequisite topology passed into clean-checkout execution.
- `lib/mix_workspace_ops/release/descriptor.ex` — legacy single-package descriptor removal/current descriptor enforcement.
- `lib/mix_workspace_ops/release/local_adapter.ex` — topology preflight before release gates/publisher.
- `lib/mix_workspace_ops/release/preflight.ex` — actual clean-checkout publish dependency verification.
- `lib/mix_workspace_ops/release/prepared_artifact.ex` — old prepared-artifact read compatibility removal/current contract cleanup.
- `lib/mix_workspace_ops/resolution.ex` — SourcePreferences precedence and registry-owned coordinates.
- `lib/mix_workspace_ops/runtime.ex` — exact-Hex removal, private lock projection, Git-transport preparation, context identity/state schema changes.
- `lib/mix_workspace_ops/view.ex` — legacy view compatibility removal.
- `mix.exs` — documentation extras updated for dependency-impact guide.
- `priv/bootstrap/mix_workspace_ops_bootstrap.exs` — exact-Hex SCM removal and singular lockfile compatibility seam.

### Documentation/examples

- `README.md`
- `CHANGELOG.md`
- `examples/contract_examples.md`
- `examples/delegated_runner.exs`
- `guides/architecture.md`
- `guides/operator_ledger_and_drift.md`
- `guides/release_transaction.md`

### Materially changed tests/support

- `test/integration/shared_runtime_cache_test.exs`
- `test/mix_workspace_ops/bootstrap_test.exs`
- `test/mix_workspace_ops/catalog_schema_test.exs`
- `test/mix_workspace_ops/catalog_view_test.exs`
- `test/mix_workspace_ops/cli_test.exs`
- `test/mix_workspace_ops/contract_examples_test.exs`
- `test/mix_workspace_ops/discovery_test.exs`
- `test/mix_workspace_ops/drift_test.exs`
- `test/mix_workspace_ops/operation_plan_test.exs`
- `test/mix_workspace_ops/operator_paths_test.exs`
- `test/mix_workspace_ops/overlay_test.exs`
- `test/mix_workspace_ops/prepared_artifact_test.exs`
- `test/mix_workspace_ops/registry_test.exs`
- `test/mix_workspace_ops/release_preflight_test.exs`
- `test/mix_workspace_ops/resolution_test.exs`
- `test/mix_workspace_ops/runtime_test.exs`
- `test/mix_workspace_ops/view_test.exs`
- `test/support/workspace_case_helper.exs`

## Deleted files/modules

This list must exactly match `DELETE_PATHS.txt`:

- `lib/mix_workspace_ops/dependency_lock.ex`
- `lib/mix_workspace_ops/hex_cache.ex`
- `lib/mix_workspace_ops/inventory.ex`
- `lib/mix_workspace_ops/local_overrides.ex`
- `lib/mix_workspace_ops/registry/examples.ex`
- `test/mix_workspace_ops/dependency_lock_test.exs`
- `test/mix_workspace_ops/hex_cache_test.exs`
- `test/mix_workspace_ops/inventory_test.exs`
- `test/mix_workspace_ops/local_overrides_test.exs`
- `test/mix_workspace_ops/registry_examples_test.exs`
- `test/mix_workspace_ops/release_descriptor_test.exs`

## Tests

### Added

- `test/mix_workspace_ops/dependency_index_test.exs`
- `test/mix_workspace_ops/impact_test.exs`
- `test/mix_workspace_ops/lockfile_test.exs`
- `test/mix_workspace_ops/source_preferences_test.exs`

### Materially changed

Tests listed in the Changed files/modules section were updated for v2-only schema behavior, XDG source preference ownership, exact-Hex absence, runtime/cache identities, plan v2/affected semantics, CLI impact/affected behavior, release topology preflight, prepared-artifact compatibility removal, and drift/report changes.

The CLI/fixture tests include real temporary Git/Mix project paths where the repository's existing test architecture permits it; pure dependency-index/impact tests also use injected dependency metadata to isolate deterministic graph behavior. The next QC agent must execute both unit and real-integration paths under a supported BEAM toolchain.

### Deleted obsolete tests

The eleven deleted paths above remove tests whose production mechanisms/surfaces are intentionally absent in vNext.

### Acceptance coverage status

The implementation maps the packet's required behaviors into production changes and regression tests, including affected fallback and release missing-prerequisite refusal. **The 64 packet acceptance gates were not executable in this container because Mix/Elixir/Erlang are absent.** They are therefore pending execution, not claimed as passed.

## Commands run

The following checks were actually run against the final source tree in this environment:

```text
command -v elixir                         NOT FOUND
command -v mix                            NOT FOUND
command -v erl                            NOT FOUND

git diff --check                         PASS
bash -n APPLY_OVERLAY.sh                  PASS
DELETE_PATHS vs git deletion diff         PASS (11 deletions; sorted/safe relative paths)
production/docs removed-concept rg scan   PASS
removed production-module reference scan PASS
private Mix API rg scan                   PASS (only LockfileCompat -> Mix.ProjectStack.post_config/1)
changed Elixir delimiter lexical audit    PASS
overlay ZIP entry/manifest audit          PASS
clean-baseline overlay equivalence        PASS
```

The following required BEAM checks were **not run** because the toolchain is unavailable in this execution environment:

```text
mix format --check-formatted              NOT RUN - `mix` unavailable
mix test                                  NOT RUN - `mix` unavailable
mix escript.build                         NOT RUN - `mix` unavailable
mix credo --strict                        NOT RUN - `mix` unavailable
mix dialyzer                              NOT RUN - `mix` unavailable
mix docs                                  NOT RUN - `mix` unavailable
```

The next QC agent must not infer PASS from the static checks above.

## Known residual issues

1. **Executable BEAM validation is pending.** This is the primary residual uncertainty: the final implementation has not been compiled, formatted by `mix format`, or executed under Elixir/Mix in this container. Run the complete suite on a supported Elixir `~> 1.19` environment before merging/releasing.
2. The packet recommends/uses SHOULD language for physically splitting the monolithic CLI into `cli/args.ex` and `cli/commands/*`. This overlay keeps one central `cli.ex` while consolidating the new command behavior/options there. No required CLI behavior was intentionally omitted for this reason, but a later maintainability-only extraction remains reasonable after the executable suite is green.
3. No other source-level residual issue is known after the static contract, residue, deletion, and overlay-equivalence audits. This statement is not a substitute for the pending executable test/acceptance suite.

## Intentional deviations from packet

### CLI physical decomposition

- Packet item: CLI decomposition is a maintainability SHOULD/recommendation.
- Constraint/choice: without a runnable compiler/test suite in this environment, a large behavior-neutral file-move refactor would add unnecessary unvalidated risk after the required command surface had been implemented.
- Implemented alternative: keep the existing escript/CLI module as the centralized option/dispatch/error vocabulary while adding/removing the required command behaviors there.
- Final QC: once all tests are green, the next agent may extract command modules with behavior-preserving tests if desired.

### TDD red/green execution evidence

- Packet item: each slice should be developed with failing-then-passing focused tests where practical.
- Environment constraint: no `elixir`, `mix`, or `erl`, and toolchain retrieval was unavailable.
- Implemented alternative: production and regression tests were changed together against the packet contracts, followed by static source/diff/residue/overlay audits.
- Required follow-up: execute the focused and full suites and fix any compile/runtime defect before considering the implementation accepted.

No normative architecture deviation is knowingly retained.

## Overlay contents and application

- Overlay ZIP: `MWO-vNext-overlay.zip`
- Overlay target: exact supplied `repomix-output(20260831-223547).xml` baseline.
- `DELETE_PATHS.txt` present: **yes**.
- `APPLY_OVERLAY.sh` present: **yes**.
- Clean-baseline overlay equivalence verified: **yes**.

Apply from the repository root:

```bash
unzip MWO-vNext-overlay.zip
./APPLY_OVERLAY.sh
```

The apply script performs deterministic deletions only. It does not install packages, contact the network, migrate state, or run arbitrary build commands.

## Final QC checklist

- [ ] Start from a clean reconstruction/copy of the exact supplied MWO baseline.
- [ ] Extract `MWO-vNext-overlay.zip` over the repository root.
- [ ] Run `./APPLY_OVERLAY.sh`; verify all `DELETE_PATHS.txt` entries are absent.
- [ ] Inspect `git diff` and final tree for accidental generated files, secrets, caches, or unrelated scope.
- [ ] Install/use the repository-supported Elixir/OTP toolchain and dependencies.
- [ ] Run `mix format --check-formatted`; fix any formatting difference.
- [ ] Run `mix test`, including integration tests; fix every failure.
- [ ] Run `mix escript.build` and representative black-box CLI commands.
- [ ] Run `mix credo --strict`, `mix dialyzer`, and `mix docs` where supported/configured.
- [ ] Execute/automate the packet's `13_ACCEPTANCE_TESTS.md` scenarios and record exact results.
- [ ] Verify ordinary managed repositories still load/test directly without MWO bootstrap environment.
- [ ] Re-scan production paths for `HexCache`, `ExactHexSCM`, `MIX_WORKSPACE_OPS_EXACT_HEX`, and `Mix.Dep.Loader`.
- [ ] Verify `Mix.ProjectStack` exists only in the documented `LockfileCompat` compatibility seam and behaves on every supported Elixir version.
- [ ] Verify legacy registry/view v1 and legacy single-package release descriptor/command are rejected/absent.
- [ ] Verify `mwo use` writes only XDG SourcePreferences and never managed checkout state.
- [ ] Verify `mwo impact` reports absent/unprobeable coverage as incomplete, never unaffected.
- [ ] Verify incomplete coverage makes `plan/run --affected` widen to the full base scope and reports why.
- [ ] Verify frozen affected-plan replay refuses dependency/index/impact/source drift rather than silently replanning.
- [ ] Verify dependency/build cache reuse across checkout-root moves and source HEAD edits matches the target key invariants without cross-project build sharing.
- [ ] Verify source `mix.lock` remains byte-for-byte unchanged and private path projection removes only active local path entries.
- [ ] Verify release topology mismatch blocks before gates/publisher and dev/test-only dependencies do not become false publish prerequisites.
- [ ] Re-run release credential-boundary, checksum-before-tag, receipt ordering, and resume/idempotency tests.
- [ ] Verify README/guides/examples/CLI help exactly match the final executable behavior.
- [ ] Update this `HANDOFF.md` with final executable command counts/results and any fix made during QC.
