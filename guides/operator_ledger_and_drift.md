# Operator Ledger and Registry Drift

The portable registry records shared remote identity and portfolio disposition. It cannot
record where one operator cloned a repository or which extra checkout that operator has
deliberately excluded. Those machine-local facts live together in one strict ledger.

The conventional location is
`${XDG_CONFIG_HOME:-~/.config}/mix_workspace_ops/operator_ledger.json`. Pass it explicitly
with `--ledger`, set `MIX_WORKSPACE_OPS_LEDGER`, or name it as `ledger` in MWO's operator
configuration. Existing commands that document `--binding` accept the same versioned
ledger at that option; the legacy id-to-path JSON binding map remains readable.

## Format

```json
{
  "schema": "mix_workspace_ops.operator_ledger/v1",
  "bindings": [
    {
      "repository": "alpha",
      "path": "/operator/other-root/alpha",
      "remotes": ["git@github.com:example-org/alpha.git"]
    }
  ],
  "ignores": [
    {
      "path": "/operator/checkouts/scratch-proof",
      "remotes": ["https://github.com/example-org/scratch-proof.git"],
      "reason": "temporary local proof, not part of this portfolio"
    }
  ]
}
```

Every top-level and row key is required and unknown keys fail. Paths are absolute. Remote
lists are non-empty, exact, unique observations of origin's fetch and push URLs. Repository
ids in bindings must exist in the supplied registry. Duplicate binding ids, paths, ignore
paths, or ignored remote identities fail. A path cannot be both bound and ignored.

An ignore is intentionally not a glob or a directory name. Drift compares its absolute
path and exact remote list with current Git evidence; moving another repository into that
path or changing origin makes the ledger stale and the gate fails. A missing ignored path
also fails. This prevents yesterday's exception from concealing today's repository.

A binding ordinarily verifies the catalogued remote identity. An exact ledger row may also
bind a checkout whose origin is a machine-local mirror and therefore has no portable
GitHub identity. It cannot bind a checkout that names a different hosted repository.

The ledger is operator-owned and untracked. Never add it to the portable registry or an
application repository.

## Discovery and drift

`registry discover` inventories every direct child, independent of programming language.
Mix is an optional inspector: a repository with no `mix.exs` is still a repository. The
snapshot date comes from the command's UTC clock; there is no observation-date CLI option.
Git, identity, inspector and task failures are evidence rather than skips.

Run the gate with:

```bash
mwo registry drift \
  --registry /catalog/registry.json \
  --checkout-root /operator/checkouts \
  --ledger /operator/config/mix_workspace_ops/operator_ledger.json \
  --output /operator/reports/registry-drift.json
```

Each direct child is classified as:

- `dispositioned`: its identity is in the catalog, or an exact ledger binding accounts for
  it;
- `ignored`: its exact checkout observation is in the ledger;
- `discovered`: it is a valid repository that neither artifact explains;
- `not_a_repository`: it is an ordinary direct child rather than a Git checkout;
- `failed`: Git, identity, inspector, task, binding or ledger evidence could not be proved.

`discovered` and `failed` make the command exit non-zero. The full report is still written
when `--output` is present and is printed as JSON by the escript. `not_a_repository`,
`ignored`, and `dispositioned` are explained states. Catalog repositories with no checkout
on this machine are listed separately as `absent_catalog`; absence is not confused with an
uncatalogued checkout and does not by itself fail the gate.
