# Fail-closed release transaction

Start with the catalog-only semantic plan:

```bash
mix_workspace_ops release plan \
  --registry /path/to/portfolio_registry/registry.json \
  --package sample_package
```

The report is `mix_workspace_ops.release_plan/v1`. It freezes the catalog digest,
requested package, derived and explicit prerequisite edges, topological order, and portable
project/repository identities. Planning reads no checkout, queries no package registry, and
needs no publication credential.

`mix_workspace_ops release publish` consumes an untracked
`mix_workspace_ops.release/v1` descriptor. It never stages or commits source.
The release commit must already be clean, pushed, and equal to its upstream.

The transaction persists a synced append-only receipt and advances through:

1. repository, branch, upstream, package/version, tag, and overlay preflight;
2. a clean detached checkout of the already-pushed commit;
3. structured gate commands, beginning with dependency hydration in a clean checkout;
4. archive construction and SHA-256 calculation;
5. the one credential-bearing publisher invocation;
6. Hex API version and checksum verification;
7. local tag creation at the unchanged release commit;
8. explicit tag push.

Every transition writes `started` and `succeeded` or `failed` evidence before a
later transition can run. A failed staging, gate, archive, publisher, registry
verification, or receipt write prevents all later actions. Credentials are not
accepted as descriptor fields and are never written to receipts; the publisher
prefix is invoked only at the publish transition. `HEX_API_KEY` is inherited by
that one subprocess only and is absent from gate, archive, verification, and
tag subprocess environments.

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
  "gates": [["mix", "deps.get"], ["mix", "ci"], ["mix", "docs", "--warnings-as-errors"]],
  "publisher_prefix": ["/operator/bin/with_secrets"]
}
```

The absolute repository and publisher paths make this descriptor operator
state, not portable registry data. A package repository or ecosystem registry
must not commit it.

The checkout deliberately contains no inherited `_build` or `deps`. The first
gate must therefore hydrate dependencies explicitly; no ambient source tree or
shared cache is treated as release evidence.

## Prepared-artifact owner seam

A projection tool may add a `handoff` object to its release metadata using
`mix_workspace_ops.prepared_artifact/v1`. The bounded object identifies the
package/version, source revision, relative prepared-project and archive paths,
and SHA-256 digests. `MixWorkspaceOps.Release.PreparedArtifact` validates that
portable data without depending on the producer or interpreting its manifest.

The producer retains projection and preparation ownership. MWO retains the
eventual clean-checkout transaction. Consuming this handoff in a real projected
package release is deferred until a product release requires it; synthetic
inputs exercise the schema now.
