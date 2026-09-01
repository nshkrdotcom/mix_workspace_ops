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

Mix Workspace Ops (MWO) is an operator-side development and release control
plane for a portfolio of independent Elixir/Mix repositories. It makes a
polyrepo portfolio behave like an optionally composed workspace while every
managed repository remains an ordinary standalone Mix project.

MWO is an escript, not a Hex dependency. It decides **which** repositories and
projects to operate on, verifies local identity, derives cross-repository
relationships from real Mix metadata, chooses eligible dependency sources,
arranges private/external execution state, delegates fan-out to Blitz, and
coordinates release transactions. Mix remains authoritative for dependency,
build, and task semantics; Hex and Git remain authoritative for their ordinary
package/repository behavior.

## Build

The repository currently declares Elixir `~> 1.19`.

```bash
mix deps.get
mix format --check-formatted
mix test
mix escript.build
./mix_workspace_ops version
```

Install the built escript on an operator-owned path. Do not add MWO as a runtime
dependency of managed applications and do not copy generated MWO state into
managed repositories.

## Product boundary

MWO owns generic portfolio operations:

- canonical portable registry/view validation;
- verified local Git binding and local drift/health reporting;
- authoritative Mix project probing;
- managed dependency indexing and reverse impact analysis;
- local/Git/Hex source policy and process-scoped overlays;
- bounded command fan-out through Blitz;
- portable plans and strict replay;
- stable external dependency/build contexts and lease-aware GC;
- fail-closed cross-repository release transactions.

It does **not** own organization `.github` automation, profile README generation,
site generation/synchronization, application runtime composition, a generic
workflow engine, or a replacement package manager/scheduler.

## Registry, views, and local binding

MWO consumes only:

- `portfolio_registry.registry/v2`
- `portfolio_registry.view/v2`

The registry is repository-first, so repositories without Mix projects remain
representable. Portable registry/view data contains identities and policy, not
machine-local checkout paths or credentials.

At invocation time MWO joins portable repository identity to local reality. A
path is accepted only when Git remote/common-directory evidence matches the
registry identity; a matching directory name is not sufficient. Scratch clones,
worktrees, explicit local bindings, and ignored observations remain
operator-owned state.

Path resolution is centralized. Explicit flags win over matching environment
variables, then `${XDG_CONFIG_HOME:-~/.config}/mix_workspace_ops/config.json`,
then documented discovery/defaults.

Typical inspection commands:

```bash
./mix_workspace_ops registry validate --registry /portfolio/registry.json
./mix_workspace_ops registry select \
  --registry /portfolio/registry.json \
  --view /portfolio/governed-stack.json
./mix_workspace_ops registry discover \
  --checkout-root ~/src \
  --github-owner example-org \
  --output /tmp/discovery.json
./mix_workspace_ops registry drift \
  --registry /portfolio/registry.json \
  --checkout-root ~/src
./mix_workspace_ops doctor \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --view /portfolio/governed-stack.json
```

## Real Mix dependency truth

Whether project A depends on application B comes from real `mix.exs` metadata
observed under explicit `MIX_ENV`/`MIX_TARGET` inputs. Registry
`dependency_sources` rows are **source-resolution declarations**, not dependency
declarations.

MWO evaluates project metadata in a disposable, time-limited probe tree with
private Mix/Home state. That contains incidental writes and protects MWO's own
process state, but it is not a kernel security sandbox: arbitrary `mix.exs` code
still runs with the operator's OS authority.

The selected-scope DependencyIndex classifies observed edges as managed,
known-but-unselected, or external and carries coverage for selected, probed,
absent, and failed/unprobeable projects.

## Impact and affected execution

Reverse impact is derived from the same managed dependency edges:

```bash
./mix_workspace_ops impact core \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --view /portfolio/governed-stack.json \
  --mix-env test --mix-target host
```

The report includes direct consumers, transitive affected projects,
repository aggregation, explanation paths, and dependency-index coverage.

Affected-only execution is a safe optimization. With complete coverage, MWO
runs the affected closure. With incomplete coverage, it widens automatically to
the full base selection and records the fallback rather than silently treating
missing/unprobeable projects as unaffected:

```bash
./mix_workspace_ops run \
  --affected core \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --view /portfolio/governed-stack.json \
  --mix-env test \
  -- mix test
```

See [Dependency index and impact](guides/dependency_impact.md).

## Source resolution and the Mix-load seam

A managed repository's committed dependency tuple is always the standalone
default. Repositories with no switchable cross-repository dependency need no
MWO integration. A project that does need source substitution uses only the
minimal bootstrap + wrapper seam:

```elixir
if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defp deps do
  [
    workspace_dep({:example_core, "~> 1.0"})
  ]
end

defp workspace_dep(committed) do
  if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
    do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
    else: committed
end
```

Without MWO activation, `workspace_dep/1` returns the committed tuple unchanged.
With an active overlay, only source coordinates are substituted; call-site
semantics such as `only`, `targets`, `optional`, and `runtime` remain owned by
the committed Mix declaration.

Source policy has four inputs with explicit precedence:

1. committed `mix.exs` default;
2. portable registry eligibility/order;
3. operator SourcePreferences;
4. one-command CLI overrides.

Persistent SourcePreferences live at
`${XDG_CONFIG_HOME:-~/.config}/mix_workspace_ops/source_preferences.json` (or an
explicit operator configuration path). They contain only `local`, `git`, or
`hex` preferences keyed by consumer project and application; they never contain
checkout paths or Git coordinates.

```bash
./mix_workspace_ops why core --project app.web
./mix_workspace_ops use core local --project app.web
./mix_workspace_ops use core git   --project app.web
./mix_workspace_ops use core hex   --project app.web
./mix_workspace_ops use --clear core --project app.web
```

`use` validates that the consumer and source declaration exist and that the
requested mode is eligible. A persisted explicit preference is intentional: if
that source is temporarily unavailable, resolution fails until the preference
is changed/cleared rather than silently falling through. Automatic mode, by
contrast, walks the declared source order and can fall through unavailable
candidates.

`seam` and `sources` expose the generated/actual source behavior:

```bash
./mix_workspace_ops seam \
  --project app.web \
  --registry /portfolio/registry.json \
  --checkout-root ~/src

./mix_workspace_ops sources \
  --project app.web \
  --registry /portfolio/registry.json \
  --checkout-root ~/src
```

Ordinary Hex dependencies are resolved/materialized by standard Mix/Hex. MWO
does not install a custom Hex SCM or retain its own Hex package object store.
Bare Git mirrors are retained only as a transport optimization; Mix still owns
Git dependency checkout and lock semantics.

## Portable plan v2 and strict replay

`plan` computes semantic intent but never executes the requested command:

```bash
./mix_workspace_ops plan \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --view /portfolio/governed-stack.json \
  --mix-env test \
  --output /tmp/plan.json \
  -- mix test
```

The portable artifact is `mix_workspace_ops.plan/v2`. It is self-digested and
contains no local checkout/runtime paths or credentials. It binds registry/view
identity, normalized scope, Mix inputs, command/policy/toolchain, unit source
state, source decisions, and dependency-index/impact facts where applicable.

Replay rebuilds current semantics and refuses named material drift before
allocating runtime state:

```bash
./mix_workspace_ops run \
  --plan /tmp/plan.json \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --view /portfolio/governed-stack.json
```

There is no generic force-through-drift mode. Produce a new plan when the
intended operation changes.

## Execution, runtime contexts, and lock isolation

Project units are the default; repository units remain available where useful.
Blitz owns bounded concurrency. Continue-on-failure is the default and
`--fail-fast` is explicit. Structured run output preserves deterministic logical
unit order and records passed, failed, absent, and not-run outcomes.

Different build contexts execute concurrently. When separate operations select
the same build context, MWO holds Mix's cross-process lock for the complete child
command. This prevents a later compile from replacing artifacts while an earlier
test or run is still using them; the waiting operation then reuses the completed
work.

MWO keeps generated state outside managed repositories:

- stable external dependency contexts;
- project-specific stable external build contexts;
- one persistent operational lock per dependency context;
- one operator-private temporary root so Mix processes share their lock namespace;
- invocation-private HOME/config/report/lease state;
- an invocation-private working copy of the context lock;
- content-addressed source overlays/bootstrap state;
- credential-free shared Hex/Rebar/archive caches;
- Git mirrors.

Reusable dependency/build identity excludes the absolute checkout root and does
not create a new build directory just because the target project's HEAD or dirty
source digest changed. Normal Mix incremental compilation remains authoritative.
Incompatible dependency/source/lock contexts still select different dependency
state.

The checkout's committed `mix.lock` is never mutated. If local path substitution
requires it, MWO projects only the corresponding top-level lock entries into the
dependency context's operational lock. Each invocation receives a private
working copy. A command allowed to mutate the lock promotes a valid result
atomically, so a later managed command reuses it; disallowed or conflicting
changes are not promoted. Malformed retained locks are quarantined and rebuilt
from the source projection. The lock parser accepts literal data only and does
not interpret package objects.

Runtime GC is lease-aware:

```bash
./mix_workspace_ops state list
./mix_workspace_ops state gc --older-than 7d --dry-run
```

Ordinary `run` children have private Home/config state and publication
credentials are scrubbed. Publication belongs to the release capability.

## Release transactions

Release planning remains portable and credential-free:

```bash
./mix_workspace_ops release plan \
  --registry /portfolio/registry.json \
  --package sample_package

./mix_workspace_ops release chain \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --package sample_package \
  --descriptor /operator/release.json
```

Each release unit runs from the exact already-pushed revision in a detached clean
checkout. Before gates or publication, MWO probes that clean source and verifies
that actual managed publishable Mix dependencies are represented by the declared
release prerequisite topology. A missing prerequisite blocks before publisher
invocation; dev/test-only dependencies observed outside the publish environment
do not create false release prerequisites.

The retained transaction then executes structured gates, exposes credentials
only to the publisher path, verifies the exact package/version/checksum in the
registry, tags only after verification, persists ordered non-secret receipts,
and supports externally revalidated safe resume.

See [Fail-closed release transaction](guides/release_transaction.md).

## Documentation

- [Architecture](guides/architecture.md)
- [Operator ledger and drift](guides/operator_ledger_and_drift.md)
- [Dependency index and impact](guides/dependency_impact.md)
- [Release transaction](guides/release_transaction.md)
- [Contract examples](examples/contract_examples.md)
