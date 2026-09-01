# Fail-closed release chains

MWO publication is a separate transaction capability. Ordinary `run` refuses
recognized direct publication tasks.

## Portable release plan

```bash
mix_workspace_ops release plan \
  --registry /portfolio/registry.json \
  --package leaf_package
```

`mix_workspace_ops.release_plan/v1` contains portable package order and portfolio
identity only. It contains no credentials, local checkout paths, or concrete
operator authorization.

## Chain descriptor

An operator supplies `mix_workspace_ops.release_descriptor/v2` for the exact
release operation. It binds concrete package versions/tags, structured gates,
publisher command policy, and optional prepared-artifact ownership.

Example shape:

```json
{
  "schema": "mix_workspace_ops.release_descriptor/v2",
  "packages": {
    "core": {
      "version": "1.4.0",
      "tag": "v1.4.0",
      "gates": [["mix", "test"]],
      "publisher_prefix": ["/operator/publish-wrapper"],
      "prepared_artifact": null
    }
  }
}
```

Credential values remain outside descriptor data.

Run the chain:

```bash
mix_workspace_ops release chain \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --package leaf_package \
  --descriptor /operator/release-chain.json \
  --state-root ~/.local/state/mix_workspace_ops
```

## Clean source and topology verification

For every package, MWO resolves the intended already-pushed revision and works
from a clean detached checkout. Before gates can run,
`Release.Preflight.verify_topology/5` evaluates that checkout's project under
`MIX_ENV=prod` and classifies actual managed dependencies through the canonical
portfolio provider mapping.

Any managed publishable dependency represented by code must be covered by the
declared release prerequisite closure. If package B now depends on package A but
the release policy omits A, the transaction stops before gates and before the
publisher. Dependencies excluded by prod Mix semantics do not create false
prerequisites. Internal dependencies whose declared publishing strategy does not
reach Hex are recorded but do not create a Hex package-order requirement.

This check keeps release order (portable policy) separate from dependency truth
(actual code) without trusting either one alone.

## Gates, publisher, verify, tag

The transition order is intentionally fail closed:

```text
clean exact checkout
  -> topology verification
  -> structured gates
  -> prepare/verify artifact
  -> publisher capability
  -> exact registry checksum verification
  -> tag + push
  -> durable receipt
```

Publication credentials are injected only into the publisher process/path that
requires them. Ordinary gates and MWO run children do not inherit publication
secrets.

A successful or ambiguous publisher return is not enough to tag. The transaction
first verifies the exact package/version and expected checksum from the package
registry. Only then may it create/push the release tag.

## Prepared artifacts

An external projection owner may provide
`mix_workspace_ops.prepared_artifact/v2`. The handoff binds source revision,
manifest identity, projected project tree identity, and optional archive identity.
MWO re-verifies those identities at the release boundary and on resume.

Older prepared-artifact schemas are not compatibility surfaces.

## Receipts and resume

Release transitions append durable non-secret evidence. Resume validates
transaction identity and rechecks relevant external state before skipping a
completed transition. Malformed, reordered, foreign, or descriptor-drifted state
is refused.

```bash
mix_workspace_ops release chain \
  --registry /portfolio/registry.json \
  --checkout-root ~/src \
  --package leaf_package \
  --descriptor /operator/release-chain.json \
  --resume TRANSACTION_ID
```

Resume must not duplicate publication or tagging merely because the prior process
ended at an awkward point.
