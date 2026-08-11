<p align="center">
  <img src="assets/mix_workspace_ops.svg" width="200" alt="Mix Workspace Ops logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/mix_workspace_ops">
    <img alt="GitHub: nshkrdotcom/mix_workspace_ops" src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Fmix__workspace__ops-0b0f14?logo=github" />
  </a>
  <a href="https://github.com/nshkrdotcom/mix_workspace_ops/blob/main/LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# Mix Workspace Ops

Operator-first Elixir workspace tooling for safe local sibling dependency
overlays, dependency-DAG planning, isolated Mix execution, reproducible Hex
verification, and fail-closed releases across standalone projects and ponchos.

Mix Workspace Ops is deliberately not a Hex package and never enters an
application runtime dependency graph. It is an operator-built escript for
coordinating independent source repositories while keeping each published
package's `mix.exs` as the compatibility authority.

## Status

The project is under active pilot development. The initial acceptance surface
is Blitz, Execution Plane, CLI Subprocess Core, Codex SDK, Weld, and the
Inference release-incident replay.

## Build

```bash
mix deps.get
mix escript.build
./mix_workspace_ops version
```

Install the built escript on an operator-owned path; do not copy it into a
managed application's repository or invoke it through `sudo`.

## Boundary

Mix Workspace Ops owns repository cataloging, explicit local dependency
overlays, graph planning, release preconditions, clean-checkout verification,
and publication receipts. It does not own application runtime configuration,
product acceptance, Weld projection semantics, or Blitz impact scheduling.

See [Architecture](guides/architecture.md) for the ownership split and safety
model.
