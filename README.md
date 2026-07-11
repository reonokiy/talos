# Talos + Cilium + Flux + Backblaze B2

This repository bootstraps Cilium on a Talos/Omni cluster, installs Flux without
a Git source, and then lets Flux reconcile a single rendered manifest bundle
from Backblaze B2's S3-compatible API.

Tool versions used to build and verify this cluster are pinned in
[.mise.toml](.mise.toml). With `mise` installed, run `mise install` before
using the Make targets.

[.env.example](.env.example) lists every B2 setting used by the local
publisher and Flux bootstrap. Copy it to `.env`; the scripts load it
automatically. Never commit the populated `.env` file.

## Data flow

```text
GitHub main -> GitHub Actions -> kubectl kustomize -> one bundle.yaml
                                            |
                                            v
                                  Backblaze B2 (write key)
                                            |
                                            v
Talos cluster <- Flux Bucket source <- B2 read-only key
```

The live cluster has no GitHub deploy key or GitHub token. `bundle.yaml` is one
object, so publishing the active revision is one S3 `PutObject`, rather than a
multi-file sync which Flux could observe halfway through. An immutable copy is
stored under a separate releases prefix for auditing; Flux only lists the
`current` prefix. Both copies carry the Git commit and bundle SHA-256 as S3
object metadata. Flux Bucket artifacts retain the complete B2 object key, so
the generated Flux `Kustomization` points at `./clusters/production/current`.

## 1. Talos / Omni prerequisite

Apply [`talos/cluster-patch.yaml`](talos/cluster-patch.yaml) as a cluster-level
Omni Config Patch before cluster creation. Cluster scope ensures future workers
inherit KubeSpan and the resolver policy. Enable Omni's embedded discovery service
for KubeSpan. The patch disables Flannel and kube-proxy, so nodes remain
`NotReady` until Cilium is installed. It also removes Netcup's `hotsrv.de`
resolver search domain. Without this override, Kubernetes' `ndots:5` lookup can
resolve `quay.io` as the wildcard `quay.io.hotsrv.de` address and prevent Flux
from reaching Helm/OCI/B2 endpoints.

For an existing Omni cluster, add the `ResolverConfig` document from that file
as a cluster-level Config Patch (preferred) or control-plane Config Patch. The
current cluster was updated manually in Omni Web; the checked-in copy is the
rebuild source of truth. After Omni applies it, recreate one
ordinary Pod and confirm its resolver no longer contains `hotsrv.de`:

```bash
kubectl run resolver-check --image=busybox:1.37 --restart=Never -- sleep 60
kubectl exec resolver-check -- cat /etc/resolv.conf
kubectl exec resolver-check -- nslookup quay.io
kubectl delete pod resolver-check
```

## 2. Bootstrap Cilium

The bootstrap install and the Flux `HelmRelease` use exactly the same values and
release identity (`cilium` in `kube-system`). Helm Controller therefore upgrades
the existing release in place; **do not uninstall Cilium during hand-off**. The
chart comes from Cilium's public, official OCI repository on Quay; this is an
upstream dependency and does not require you to operate an OCI registry. Both
the bootstrap chart archive and Flux `OCIRepository` are digest-pinned; Flux
also verifies Cilium's keyless Cosign signature against the Cilium GitHub
Actions identity before exposing the chart to Helm Controller.

```bash
make bootstrap-cilium
```

With the pinned tool environment installed, run:

```bash
mise x -- cilium status --wait
mise x -- cilium connectivity test \
  --ip-families ipv4 \
  --namespace-labels 'pod-security.kubernetes.io/enforce=privileged,pod-security.kubernetes.io/warn=privileged,pod-security.kubernetes.io/audit=privileged'
```

Those labels apply only to the disposable connectivity-test namespaces. The
test uses host networking, host ports and `NET_RAW`, which the cluster's
default Pod Security policy otherwise rejects.

## Encrypted workload DNS

The production bundle takes ownership of Talos' bootstrap `coredns` ConfigMap
and forwards recursive queries to Cloudflare using DNS-over-TLS on TCP 853.
Pod-to-CoreDNS DNS remains cluster-local; cross-node traffic is protected by
KubeSpan. Talos host/bootstrap DNS is still ordinary DNS because
`ResolverConfig` does not support DoT/DoH transports.

The CoreDNS object has Flux's `prune: disabled` annotation so accidentally
removing it from this repository cannot delete cluster DNS. Do not enable this
component until the Talos ResolverConfig has removed provider search domains;
DoT encrypts a query but cannot correct a malformed `quay.io.bestsrv.de` query.

## Kubelet serving certificates

The bundle installs `kubelet-serving-cert-approver` v0.11.0 with its multi-arch
image pinned by digest. Talos rotates kubelet serving certificates, but
Kubernetes intentionally does not approve these CSRs by default. The approver
validates node identity and SANs before approval so `kubectl logs`, exec and
metrics-server do not fail again at the next certificate rotation.

## 3. Configure B2

Create one private, S3-compatible bucket and two bucket-scoped application keys:

- GitHub: write access, restricted to `clusters/production/`.
- Flux: read-only access, restricted to `clusters/production/current/`. Keep
  the trailing slash in both the key restriction and `B2_PREFIX`, and enable
  “List All Bucket Names” for Flux's bucket-existence check.

The publisher key needs B2 `writeFiles` access to
`clusters/production/`. The Flux key needs `listFiles` and `readFiles` access;
it does not need delete or write permission. This bootstrap also preflights
bucket listing, so enable “List All Bucket Names” on the Flux key. Do not use
the B2 master key.

Set these GitHub Environment (`production`) values:

| Type | Name | Example |
|---|---|---|
| Variable | `B2_ENDPOINT` | `s3.eu-central-003.backblazeb2.com` |
| Variable | `B2_REGION` | `eu-central-003` |
| Variable | `B2_BUCKET` | `my-flux-artifacts` |
| Variable | `B2_PREFIX` | `clusters/production/current/` |
| Variable | `B2_ARCHIVE_PREFIX` | `clusters/production/releases/` |
| Secret | `B2_WRITE_KEY_ID` | B2 application key ID |
| Secret | `B2_WRITE_APPLICATION_KEY` | B2 application key |

Protect the Environment with required reviewers if changes should not deploy
immediately after merging to `main`.

After the GitHub repository exists and `.env` is populated, create the
`production` Environment and load all Variables/Secrets without echoing the
keys:

```bash
make configure-github
```

Push once or manually run `Publish Flux bundle to B2`. Confirm that
`clusters/production/current/bundle.yaml` exists before the next step.

The same publisher can be tested locally with the GitHub write key exported as
standard AWS credentials:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export B2_ENDPOINT=s3.eu-central-003.backblazeb2.com
export B2_REGION=eu-central-003
export B2_BUCKET=my-flux-artifacts
make publish-b2
```

## 4. Install Flux and point it at B2

Use a separate read-only key locally; it is written only to a Kubernetes Secret:

```bash
export B2_ENDPOINT=s3.eu-central-003.backblazeb2.com
export B2_REGION=eu-central-003
export B2_BUCKET=my-flux-artifacts
export B2_PREFIX=clusters/production/current/
export B2_READ_KEY_ID=...
export B2_READ_APPLICATION_KEY=...
make bootstrap-flux
```

Then verify the hand-off:

```bash
flux get sources bucket -n flux-system
flux get kustomizations -n flux-system
flux get helmreleases -A
helm status cilium -n kube-system
cilium status --wait
```

## Normal operation and rollback

Every merge to `main` renders and publishes a new active object. Flux detects
the changed object ETag/digest and reconciles it. Roll back by reverting the Git
commit and merging; the workflow publishes the reverted desired state.

For emergency rollback, use a third, offline read-only key restricted to
`clusters/production/releases/`. The rollback script downloads with that key,
then uploads with the existing write-only publisher key. This avoids granting
GitHub read access merely to make S3 `CopyObject` work:

```bash
make rollback-b2 RELEASE_ID=<git-sha>
flux reconcile source bucket cluster-config -n flux-system
flux reconcile kustomization cluster-config -n flux-system --with-source
```

## Security boundary

B2 `Bucket` sources are checksummed by Flux, but unlike signed OCI artifacts
they do not provide Cosign signature verification. B2 is used here because it
is the requested runtime source; compensate with a private bucket, separate
prefix-scoped read/write keys, GitHub Environment approval, branch protection,
and B2 object versioning/retention. If cryptographic admission is required,
publish a signed OCI artifact to an OCI registry and use Flux `OCIRepository`
instead of B2.

The root Flux `Kustomization` uses `deletionPolicy: Orphan`, and the Cilium
`HelmRelease` plus CoreDNS ConfigMap opt out of pruning. An accidental deletion
of the B2 source therefore cannot cascade into uninstalling the CNI or cluster
DNS; intentional Cilium removal is a separate manual operation.
