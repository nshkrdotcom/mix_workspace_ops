# Dependency index and impact

MWO answers cross-repository dependency questions from authoritative Mix
metadata, not from registry source-policy declarations.

## Dependency truth

For each selected Mix project MWO evaluates `mix.exs` in a disposable probe tree
under explicit `MIX_ENV` and `MIX_TARGET` values. One index records edges of the
form:

```text
consumer project --depends on application--> provider project
```

An observed dependency is classified as:

- **managed** — a selected provider project is known;
- **known_unselected** — the portfolio knows provider candidates but the active
  selection does not contain one;
- **external** — no managed provider is known.

`dependency_sources` rows do not create edges. They only describe eligible
source coordinates for dependencies that Mix actually declares.

## Coverage

Every index carries selected, successfully probed, absent, and failed/unprobeable
projects plus a completeness flag. An absent or failed project is an unknown
surface, not a dependency-free project.

## Impact

```bash
mix_workspace_ops impact TARGET \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --view /portfolio/governed-stack.json \
  --mix-env test --mix-target host
```

`TARGET` may resolve to one exact project, repository, or provided application.
Ambiguous names fail rather than being guessed.

The impact result contains direct consumers, the transitive reverse closure,
affected repositories, at least one known dependency path for each affected
project, and index coverage.

## Safe affected execution

```bash
mix_workspace_ops run \
  --affected core \
  --view /portfolio/governed-stack.json \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --mix-env test -- mix test
```

Affected selection is a performance optimization, never a correctness gamble.
When index coverage is complete, the selected unit set is the affected closure.
When coverage is incomplete, MWO widens automatically to the full base view and
records `dependency_index_incomplete` as the fallback reason.

The same scope and dependency-index facts are frozen into
`mix_workspace_ops.plan/v2`. Replay therefore refuses dependency/coverage drift
instead of silently producing a different affected set.
