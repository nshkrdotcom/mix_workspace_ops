# Changelog

## Unreleased

### Breaking vNext architecture

- Support only `portfolio_registry.registry/v2` and
  `portfolio_registry.view/v2`; legacy MWO registry/view schemas are rejected.
- Move persistent source choices out of managed checkouts into XDG
  `SourcePreferences`, keyed by consumer project/application and limited to
  eligible `local`, `git`, or `hex` modes. `mwo use` no longer edits managed
  repository state.
- Remove the custom retained-Hex package/materialization path. Ordinary Hex
  resolution and caching are delegated to Mix/Hex; Git mirrors remain a
  transparent transport optimization beneath ordinary Mix Git checkout
  semantics.
- Replace broad dependency-object lock parsing with the narrow literal-only
  `Lockfile` contract used for private path-entry projection and lock audit.
- Simplify runtime dependency/build context identity so reusable paths do not
  vary solely with absolute checkout root, target HEAD, or dirty source digest;
  build contexts remain project-specific and dependency/source incompatible
  contexts remain isolated.
- Add selected-scope `DependencyIndex` coverage from real Mix metadata and
  first-class reverse `impact` analysis with deterministic explanation paths.
- Add `--affected TARGET` planning/execution. Complete dependency coverage uses
  the affected subset; incomplete coverage conservatively widens to the full
  base selection and records the fallback.
- Introduce strict portable `mix_workspace_ops.plan/v2`, including normalized
  scope and dependency-index/impact facts, and reject material drift during
  replay rather than silently replanning.
- Retain Blitz as the fan-out scheduler and preserve complete deterministic run
  reporting for passed, failed, absent, and not-run units.
- Harden release preflight by verifying declared release prerequisites against
  actual managed publishable dependencies observed in each clean exact checkout
  before gates or publisher invocation.
- Remove permanent legacy `inventory`, registry-example validation, and
  single-package release-publish CLI surfaces; example validation remains a test
  concern and one-package publication goes through `release chain`.
- Align doctor/drift/runtime reports and documentation with the vNext ownership
  boundaries and add `guides/dependency_impact.md`.
