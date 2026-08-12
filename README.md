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

The default repository integration is zero code. Repositories without
switchable cross-repository internal dependencies need no MWO file, module,
task, or dependency. Existing `mix.exs` files remain authoritative; only a
project whose dependency tuple must switch between Hex and an explicit operator
overlay needs the minimal Mix-load seam. Exceptional repository configuration,
if ever required, is limited to one declarative manifest rather than a copied
helper subsystem.

## Registry-driven usage

The portable registry contains GitHub identities and relative Mix-project
coordinates. The operator supplies a checkout root at runtime; every checkout is
then verified against its Git origin and Git common directory.

```bash
./mix_workspace_ops registry validate --registry /path/to/registry.json
./mix_workspace_ops registry discover \
  --checkout-root /path/to/checkouts \
  --github-owner example-org \
  --output /path/to/discovery.json
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
  --mode local --mix-state managed -- mix test
```

Local and Git overlays are stored beneath operator-owned XDG state and passed
only to the child command through `MIX_WORKSPACE_OPS_OVERLAY`. No source-mode
state is written into managed repositories. A direct `mix` invocation with no
overlay environment variable uses the ordinary dependency declarations.

MWO materializes its bootstrap in operator state and supplies its path through
`MIX_WORKSPACE_OPS_BOOTSTRAP`; it does not install executable helper code into
the repository. `MIX_WORKSPACE_OPS_CONTEXT_DIGEST` identifies the normalized,
path-independent dependency-source selection for cache-aware callers.

Managed Mix-state mode supplies content-addressed, operator-owned
`MIX_DEPS_PATH`, `MIX_BUILD_ROOT`, `HEX_HOME`, and lockfile state for one Mix
graph. Delegated mode supplies only the source/bootstrap context so a workspace
runner can retain ownership of its child state:

```bash
./mix_workspace_ops run ... --mix-state delegated -- runner command
```

Publication is refused through `run`; it is available only through the release
transaction below.

Discovery is also generic. It accepts the owner explicitly, deduplicates by Git
identity, rejects worktrees and wrongly named clones, prunes generated and
fixture trees, and records unloadable or duplicate Mix applications as
unresolved evidence rather than guessing an identity. A real project is not
discarded merely because it lives beneath `examples` or `support`.

Release publication is a separate, fail-closed transaction over an already
committed and pushed revision:

```bash
./mix_workspace_ops release publish \
  --descriptor /path/to/untracked-release-descriptor.json
```

The transaction never stages or commits source. It builds from a detached clean
checkout, persists every transition, exposes credentials only to its publisher
step, verifies the Hex checksum, and creates the tag only afterward.

See [Architecture](guides/architecture.md) for the ownership split and safety
model, [Contract examples](examples/contract_examples.md) for the synthetic runner seam,
and [Fail-closed release transaction](guides/release_transaction.md) for the
publication state machine.
