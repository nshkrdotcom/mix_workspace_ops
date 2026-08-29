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
project whose dependency tuple must switch source needs the minimal Mix-load
seam. Exceptional repository configuration, if ever required, is limited to one
declarative manifest rather than a copied helper subsystem.

## The Mix-load seam

```elixir
if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

@compile {:no_warn_undefined, MixWorkspaceOpsBootstrap}

defp deps do
  [
    workspace_dep(:example_core, "~> 1.0"),
    workspace_dep(:example_edge, [github: "example-org/example_edge", branch: "main"],
      only: [:dev, :test]
    )
  ]
end

defp workspace_dep(app, committed_default, extra_opts \\ []) do
  if Code.ensure_loaded?(MixWorkspaceOpsBootstrap) do
    MixWorkspaceOpsBootstrap.dep(app, committed_default, __DIR__, extra_opts)
  else
    committed_dep(app, committed_default, extra_opts)
  end
end

defp committed_dep(app, requirement, []) when is_binary(requirement), do: {app, requirement}

defp committed_dep(app, requirement, opts) when is_binary(requirement),
  do: {app, requirement, opts}

defp committed_dep(app, coordinates, opts) when is_list(coordinates),
  do: {app, Keyword.merge(coordinates, opts)}
```

The first line is what puts the bootstrap on the code path, and the rest goes
inside the `MixProject` module. Without that line nothing loads
`MixWorkspaceOpsBootstrap`: it is an `.exs` file in operator state whose path
arrives in `MIX_WORKSPACE_OPS_BOOTSTRAP`, so a `mix.exs` that only asks whether
the module is loaded gets `false` every time and resolves nothing, while looking
wired.

The second argument is the committed default — a Hex requirement, or committed
git coordinates for a dependency that has no Hex release. It is what the
repository resolves to on a fresh clone with no tool involved, and
`mwo seam --project ID` prints it for a project rather than leaving it to be
written by hand. Options given at the call site are carried whether or not an
overlay is active, because `only:`, `optional:`, `runtime:` and `targets:` say
whether a dependency exists here at all and dropping them changes what Mix
resolves.

Where an operator has activated an overlay, the row for that application decides
instead, and the plan records which source it chose and why.

## Registry-driven usage

The portable catalog is repository-first. Each repository carries its remote
identity, languages, lifecycle, disposition, visibility, roles, groups, and
agent scope; Mix projects are an optional block within it, so a repository that
builds nothing with Mix is still catalogued, grouped, and selectable. Where a
repository consumes cross-repository applications, it also carries the
dependency-source table that says how each one resolves, and the release-train
membership of the packages it publishes.

`portfolio_registry.registry/v2` and `portfolio_registry.view/v2` are the
current schemas. `mix_workspace_ops.registry/v1` and `mix_workspace_ops.view/v1`
still load.

The operator supplies a checkout root at runtime; every checkout is then
verified against its Git origin and Git common directory.

Path flags are optional. Every command resolves them in the same order: flag,
`MIX_WORKSPACE_OPS_REGISTRY` / `MIX_WORKSPACE_OPS_CHECKOUT_ROOT`,
`${XDG_CONFIG_HOME:-~/.config}/mix_workspace_ops/config.json`, then discovery
by walking upward. A configured checkout therefore needs no repeated path
flags:

```json
{"registry": "/catalog/registry.json", "checkout_root": "/operator/checkouts"}
```

```bash
./mix_workspace_ops registry validate --registry /path/to/registry.json
./mix_workspace_ops registry discover \
  --checkout-root /path/to/checkouts \
  --github-owner example-org \
  --output /path/to/discovery.json
./mix_workspace_ops registry select \
  --registry /path/to/registry.json \
  --view /path/to/view.json
./mix_workspace_ops registry chain \
  --registry /path/to/registry.json \
  --package example_core
./mix_workspace_ops plan \
  --registry /path/to/registry.json \
  --checkout-root /path/to/checkouts \
  --project example.consumer \
  --mix-env dev --mix-target host
./mix_workspace_ops seam \
  --registry /path/to/registry.json \
  --checkout-root /path/to/checkouts \
  --project example.consumer
./mix_workspace_ops why example_core --project example.consumer
./mix_workspace_ops use example_core local --project example.consumer
./mix_workspace_ops use --clear example_core --project example.consumer
./mix_workspace_ops run \
  --registry /path/to/registry.json \
  --checkout-root /path/to/checkouts \
  --project example.consumer \
  --mix-env test --mix-target host \
  --mode local --mix-state managed -- mix test
```

`--mix-env` and `--mix-target` are graph inputs, not readings of ambient shell
state. They default deterministically to `dev` and `host`, appear in plans and
overlays, and contribute to graph and context digests.

Local and Git overlays are stored beneath operator-owned XDG state and passed
only to the child command through `MIX_WORKSPACE_OPS_OVERLAY`. No source-mode
state is written into managed repositories. A direct `mix` invocation with no
overlay environment variable uses the ordinary dependency declarations.

`mwo why APP` explains the provider identity rule, the source chosen, every
candidate considered, and both the durable and machine-local gestures that
would change it. `mwo use APP local|git|hex` and `mwo use --clear [APP]` amend
the parsed, never evaluated `.dependency_sources.local.exs` file so an operator
does not have to remember its syntax.

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

Dependency discovery evaluates arbitrary `mix.exs` code only in a disposable
worktree copy, with temporary Home/Mix/Hex state, a replacement environment,
and a hard timeout. Repository-relative source remains available, while Git
metadata, dependencies, build output, common credential files, publication
credentials, and agent credentials are excluded. This protects the checkout
and ambient process state; it is not a kernel sandbox and does not prevent code
running as the operator from explicitly accessing host paths or the network.

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
