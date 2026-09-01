# Operator ledger and registry drift

Portable portfolio identity and machine-local checkout reality are separate
facts. The registry/view can be shared; the operator ledger cannot.

## Ledger

The operator ledger records explicit local observations such as:

- an exact repository id -> checkout path binding;
- an intentionally ignored scratch clone/worktree observation and its remote
  evidence.

It must not become a second portfolio registry. It contains no source-selection
policy and no publication credentials.

Source mode preferences are a different XDG file managed by
`MixWorkspaceOps.SourcePreferences`; they are keyed by consumer project and
application and contain only `local`, `git`, or `hex`.

## Binding

A candidate checkout is accepted only after Git evidence identifies it as the
registry repository. Canonical bindings must refer to the ordinary Git root/common
directory; linked worktrees do not masquerade as the canonical checkout.
Contradictory remote evidence or multiple canonical bindings fail closed.

## Discovery and drift

```bash
mix_workspace_ops registry drift \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --ledger ~/.config/mix_workspace_ops/operator-ledger.json
```

Drift reconciles catalog identity, discovered local repositories/worktrees, and
ledger observations. It never mutates the portable registry.

Rows carry a severity independent of their discovery status:

### Error

- malformed/contradictory exact binding evidence;
- wrong identity for an exact binding;
- ambiguous portfolio identity.

Errors make the drift report unhealthy and the command fail.

### Warning

- unexplained scratch/extra checkout;
- stale ignore observation or remotes;
- broken/unprobeable discovered checkout where no exact identity contradiction
  has been established;
- other development-state gaps that require operator attention.

Warnings remain in `warnings` and `unexplained` but do not by themselves make the
report unhealthy.

### Info

- canonical healthy checkout;
- explicitly ignored/dispositioned worktree or clone;
- non-repository observations as applicable.

This distinction lets development diagnostics remain useful without weakening
identity safety. Release performs separate fail-closed clean/upstream checks.
