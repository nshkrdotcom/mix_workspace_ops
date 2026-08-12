# Fail-closed release transaction

`mix_workspace_ops release publish` consumes an untracked
`mix_workspace_ops.release/v1` descriptor. It never stages or commits source.
The release commit must already be clean, pushed, and equal to its upstream.

The transaction persists a synced append-only receipt and advances through:

1. repository, branch, upstream, package/version, tag, and overlay preflight;
2. a clean detached checkout of the already-pushed commit;
3. structured gate commands;
4. archive construction and SHA-256 calculation;
5. the one credential-bearing publisher invocation;
6. Hex API version and checksum verification;
7. local tag creation at the unchanged release commit;
8. explicit tag push.

Every transition writes `started` and `succeeded` or `failed` evidence before a
later transition can run. A failed staging, gate, archive, publisher, registry
verification, or receipt write prevents all later actions. Credentials are not
accepted as descriptor fields and are never written to receipts; the publisher
prefix is invoked only at the publish transition.

`mix_workspace_ops run -- mix hex.publish` is rejected. The ordinary workspace
runner owns isolated development state; only this release transaction may cross
the publication boundary.

Example descriptor:

```json
{
  "schema": "mix_workspace_ops.release/v1",
  "repository": "/operator/checkouts/sample_package",
  "project_path": ".",
  "package": "sample_package",
  "version": "1.2.0",
  "tag": "v1.2.0",
  "default_branch": "main",
  "gates": [["mix", "ci"], ["mix", "docs", "--warnings-as-errors"]],
  "publisher_prefix": ["/operator/bin/with_secrets"]
}
```

The absolute repository and publisher paths make this descriptor operator
state, not portable registry data. A package repository or ecosystem registry
must not commit it.
