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

The project is under active pilot development. Its protocols and examples are
ecosystem-neutral: a registry is supplied at invocation time, and no operator's
repository inventory is compiled into the tool.

## Build

```bash
mix deps.get
mix escript.build
./mix_workspace_ops version
```

Install the built escript on an operator-owned path; do not copy it into a
managed application's repository or invoke it through `sudo`.

## Boundary

Mix Workspace Ops owns generic registry validation, explicit local dependency
overlays, graph planning, release preconditions, clean-checkout verification,
and publication receipts. It does not own a user's ecosystem registry,
application runtime configuration, product acceptance, package projection
semantics, or workspace impact scheduling.

## Registry-driven usage

The portable registry contains GitHub identities and relative Mix-project
coordinates. The operator supplies a checkout root at runtime; every checkout is
then verified against its Git origin and Git common directory.

```bash
./mix_workspace_ops registry validate --registry /path/to/registry.json
./mix_workspace_ops registry select \
  --registry /path/to/registry.json \
  --view /path/to/view.json
./mix_workspace_ops plan \
  --registry /path/to/registry.json \
  --checkout-root /path/to/checkouts \
  --project example.consumer
./mix_workspace_ops run \
  --registry /path/to/registry.json \
  --checkout-root /path/to/checkouts \
  --project example.consumer \
  --mode local -- mix test
```

Local and Git overlays are stored beneath operator-owned XDG state and passed
only to the child command through `MIX_WORKSPACE_OPS_OVERLAY`. No source-mode
state is written into managed repositories. A direct `mix` invocation with no
overlay environment variable uses the ordinary dependency declarations.

See [Architecture](guides/architecture.md) for the ownership split and safety
model.
