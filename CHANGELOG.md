# Changelog

## Unreleased

- Establish the non-Hex operator escript, portable registry protocol, local source
  overlays, dependency planning, and fail-closed release transaction.
- Keep ordinary repositories zero-integration by materializing the Mix bootstrap
  in operator state instead of installing copied helper code.
- Separate machine-local overlay integrity from a path-independent semantic
  source-context digest and support explicit managed/delegated Mix-state owners.
- Accept non-application workspace roots and discover real example projects.
- Validate a portable prepared-artifact handoff without depending on the
  projection tool that produced it.
- Restrict `HEX_API_KEY` inheritance to the credential-bearing publish
  transition instead of accepting it in release descriptors.
- Resolve every managed dependency through an ordered list of candidate sources
  — local sibling, GitHub at a revision, published Hex — falling through to the
  next where one is unavailable, and record which candidates were considered and
  why each was rejected.
- Decide only the applications a dependency-source table declares. An
  application no table declares keeps whatever its `mix.exs` call site committed
  to.
- Detect publishing from the task the command names and resolve through the
  publish order, refusing an override that would put a non-Hex source into a
  published package.
- Parse only task positions Mix actually recognizes, so commas and plus signs
  in ordinary task arguments cannot be mistaken for a publishing command.
- Add per-run `--mode`, per-dependency `--source APP=SOURCE`, and the operator's
  `.dependency_sources.local.exs`, which is parsed and never evaluated.
- Give the seam a committed default, so a repository resolves without this tool
  on a fresh clone, and `mwo seam` to derive those call sites from publish
  resolution.
- Add `mix deps.sources`, defined by the bootstrap and costing a repository no
  files.
- Record a selection beside the catalog instead of pruning it, and report the
  three sets — what the catalog holds, what the selection permits, what is
  materialized here — in `doctor`, `plan`, `sources`, `registry select` and every
  run.
