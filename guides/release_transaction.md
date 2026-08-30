# Fail-closed release chains

Release starts with a catalog-only semantic plan:

```bash
mix_workspace_ops release plan \
  --registry /path/to/portfolio_registry/registry.json \
  --package sample_package
```

The `mix_workspace_ops.release_plan/v1` report contains the catalog digest,
requested package, complete prerequisite map, topological order, and portable
project and repository identities for every unit. Its `digest` covers all of
those fields. Planning reads no checkout, queries no package registry, and
requires no publication credential. `registry chain` uses the same derivation
for its compatibility report.

## Chain descriptor

Create one untracked, operator-owned descriptor for the exact plan:

```json
{
  "schema": "mix_workspace_ops.release_descriptor/v2",
  "release_plan_digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "registry_digest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "publisher_prefix": ["/operator/bin/with-publish-capability"],
  "packages": {
    "sample_core": {
      "version": "1.2.0",
      "tag": "v1.2.0",
      "gates": [["mix", "deps.get"], ["mix", "ci"]],
      "prepared_artifact": null
    },
    "sample_package": {
      "version": "2.0.0",
      "tag": "sample_package-v2.0.0",
      "gates": [["mix", "deps.get"], ["mix", "ci"]],
      "prepared_artifact": null
    }
  }
}
```

The package keys must equal the planned order in both directions. Repository,
project path, prerequisite edges, and default branch are deliberately absent:
they come only from the catalog. The loader rejects missing or unknown keys,
invalid versions, tags other than `vVERSION` or `PACKAGE-vVERSION`, empty gate
lists, relative publisher executables, and credential-like gate, preparation,
or wrapper arguments. A wrapper executable may naturally have a name such as
`with_secrets`; credential values still remain outside descriptor data.

Run the chain with verified operator checkouts:

```bash
mix_workspace_ops release chain \
  --registry /path/to/portfolio_registry/registry.json \
  --checkout-root /operator/checkouts \
  --binding /operator/bindings.json \
  --package sample_package \
  --descriptor /operator/release-chain.json \
  --state-root /operator/mwo-state
```

`--binding` and `--state-root` are optional. All other options shown are
required. MWO rebuilds the canonical plan from the loaded catalog before
execution; a self-consistent but reordered or otherwise invented plan is not
accepted. The chain stops at its first blocked unit.

## Transaction and resume

Each package advances through these transitions:

1. repository, branch, upstream, package/version, dependency, tag, registry,
   and overlay preflight;
2. detached checkout of the already-pushed revision;
3. the descriptor's structured gates;
4. archive construction or prepared-archive verification;
5. the one credential-bearing publisher invocation;
6. exact package/version/checksum registry verification;
7. local tag creation at the unchanged release revision;
8. explicit tag push.

Every transition records a synced `started` event followed by `succeeded` or
`failed`. Receipts are strict JSONL under
`STATE_ROOT/releases/TRANSACTION/events.jsonl`; a system `flock` guard permits
one writer across OS processes. A truncated, malformed, reordered, foreign, or
descriptor-drifted receipt is refused.

The result reports the chain `transaction_id`. Resume that identity, not an
individual unit suffix:

```bash
mix_workspace_ops release chain \
  --registry /path/to/portfolio_registry/registry.json \
  --checkout-root /operator/checkouts \
  --package sample_package \
  --descriptor /operator/release-chain.json \
  --state-root /operator/mwo-state \
  --resume sample_package-2.0.0-TRANSACTION
```

Resume verifies completed external state before skipping it. In particular,
an exact published checksum recovers a crashed or failed publisher return
without publishing again; changed checksums stop. Existing local and remote
tags must target the recorded source revision. A completed chain performs no
new publish, tag, or push.

Preflight checks only managed dependencies the current Mix project actually
declares. A non-Hex `publish_order` is respected. Missing exact releases block;
registry transport failures are distinguished from absence and also stop an
executable chain because publication readiness was not proved.

## Credential and tool state boundary

All release children receive a replacement environment and transaction-private
`HOME`, `MIX_HOME`, `HEX_HOME`, Rebar cache, and temporary directory. Installed
Mix archives are copied once into that private Mix home. The operator's Hex and
Mix state is therefore neither inherited nor writable by gates. `HEX_API_KEY`
is preserved only for the absolute publisher wrapper, which receives the
appended argv `mix hex.publish --yes`. Registry queries send only MWO's fixed
user-agent header.

Receipt evidence excludes environment maps, credential values, tokens,
authorization headers, and wrapper output. It binds the normalized descriptor
and digest, semantic-plan and registry digests, source revision, package and
version, gate argv/results, archive checksum, verified registry checksum, and
tag target.

`mix_workspace_ops run -- mix hex.publish` remains refused; only a release
transaction may cross the publication boundary.

## Prepared-artifact owner

A projection owner may emit `mix_workspace_ops.prepared_artifact/v2` inside its
release metadata. The handoff contains package/version, source revision,
repository-relative manifest path and digest, bundle-relative project path and
tree digest, and archive path and digest. The v1 schema remains readable as
compatibility data but is incomplete and cannot authorize publication.

A prepared unit adds this descriptor object:

```json
{
  "expected_handoff": "/operator/evidence/release.json",
  "prepare": ["mix", "weld.release.prepare", "packaging/weld/sample.exs"],
  "rebuilt_handoff": "dist/release_bundles/sample/2.0.0-digest/release.json"
}
```

The expected path is absolute; the rebuilt path is relative to the clean
checkout. MWO loads the expected handoff, executes `prepare` inside the detached
checkout, loads the rebuilt handoff, and requires equality of package, version,
source revision, manifest identity, projected-tree digest, and archive digest.
It then verifies the actual files and publishes from the rebuilt project. It
never publishes the operator's expected bundle or teaches MWO to parse the
owner's manifest. The prepared tree and archive are checked again on resume and
immediately before publication.

Weld emits this v2 handoff and constructs a reproducible prepared project from
package inputs rather than `_build`, fetched dependencies, generated docs, or
nested tarballs. The cross-repository integration proof runs Weld's real
preparation task in MWO's clean checkout and completes through a local fake
publisher and registry; acceptance never publishes a real package.

## Single-package compatibility

The older command remains available for an ordinary non-projected package:

```bash
mix_workspace_ops release publish \
  --descriptor /operator/release.json \
  --state-root /operator/mwo-state

mix_workspace_ops release publish \
  --descriptor /operator/release.json \
  --state-root /operator/mwo-state \
  --resume TRANSACTION
```

It loads strict `mix_workspace_ops.release/v1`, executes the same transaction
and adapter, persists the full normalized descriptor, and has the same resume,
receipt, checksum, tag, and credential rules. Catalog-derived multi-package
publication should use `release chain`.
