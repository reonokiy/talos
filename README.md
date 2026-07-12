# Talos + Cilium + Flux + Backblaze B2

This repository bootstraps Cilium on a Talos/Omni cluster, installs Flux
without a Git source, and lets Flux reconcile an immutable repository snapshot
from Backblaze B2's S3-compatible API.

`mise` pins tools and exposes all operator tasks. `fnox` resolves secrets from
1Password only for the subprocess that needs them. No populated `.env`, B2
credential, GitHub deploy key, or 1Password token is committed to this source.

## Data flow and trust boundaries

```text
1Password Publisher vault ── fnox on operator machine
                                      │
                                      ▼
                        GitHub Environment B2 writer
                                      │
GitHub main ── GitHub Actions ── immutable repository snapshot ── Backblaze B2
                                                                  │
1Password Runtime vault ── fnox on operator machine               │
                            │                                     │
                            ▼                                     ▼
                 flux-system/b2-flux-reader ─────── Flux Bucket source
                                                                  │
                                                                  ▼
                                                      Talos Kubernetes cluster
```

GitHub Actions does not connect to 1Password. GitHub Environment holds the B2
publisher Variables/Secrets provisioned by a local fnox task. The cluster stores
only the bucket-scoped, read-only B2 key required by source-controller; it never
receives a publisher key or any 1Password authentication material.

Each release mirrors the repository's `clusters/` and `infrastructure/` trees
under `clusters/production/releases/<git-sha>/`. GitHub Actions uploads that
immutable snapshot first, then atomically replaces the single
`clusters/production/current/entrypoint/release.yaml` object. The entrypoint
pins Flux to the completed release prefix, so it cannot observe a partially
published multi-file revision.

The entrypoint creates independent `cluster-network`, `cluster-certificates`
and `cluster-system` Kustomizations over the same immutable Bucket artifact.
Their dependency chain is network -> certificates -> system. Health, inventory,
pruning and failure reporting are isolated per layer while all layers advance
to the same Git commit.

## 1. Install locked tools

Tool versions are pinned in [`.mise.toml`](.mise.toml) and checksums are stored
in `mise.lock`:

```bash
MISE_IGNORED_CONFIG_PATHS="$HOME/.config/mise/config.toml" mise install --locked
mise tasks
mise run validate
```

The ignored path keeps a user's global mise tool list out of this repository's
lockfile check. Omit the variable when no global mise config exists.

The supported integration is `mise` for tools/tasks plus `fnox exec` for
secrets. This deliberately does not use the experimental mise fnox environment
plugin. fnox has `env = "exec"`, so secrets do not enter the ambient shell.

For local use, enable 1Password Desktop CLI integration and authenticate once:

```bash
mise exec -- op vault list
```

## 2. Talos / Omni prerequisite

Apply [`talos/cluster-patch.yaml`](talos/cluster-patch.yaml) as a cluster-level
Omni Config Patch before cluster creation. Cluster scope ensures future workers
inherit KubeSpan and resolver policy. Enable Omni's embedded discovery service.
The patch disables Flannel and kube-proxy, so nodes remain `NotReady` until
Cilium is installed.

The patch also removes Netcup's `hotsrv.de`/`bestsrv.de` resolver search
domains. Their wildcard records made Kubernetes' `ndots:5` lookup resolve
`quay.io` as a provider-domain address, which was the original OCI pull
failure. For an existing cluster, add its `ResolverConfig` document through
Omni Web and recreate a test Pod:

```bash
kubectl run resolver-check --image=busybox:1.37 --restart=Never -- sleep 60
kubectl exec resolver-check -- cat /etc/resolv.conf
kubectl exec resolver-check -- nslookup quay.io
kubectl delete pod resolver-check
```

## 3. Bootstrap Cilium

The bootstrap releases are declared in
[`bootstrap/helmfile.yaml.gotmpl`](bootstrap/helmfile.yaml.gotmpl). Cilium and
Flux versions, namespaces, chart sources, ordering labels, timeouts and Flux
controller settings are reviewable there instead of being embedded in shell
commands. The scripts only verify external prerequisites, inject the one
out-of-band B2 credential, apply the declarations and wait for health.

The bootstrap Cilium release and Flux `HelmRelease` share the same values and
release identity (`cilium` in `kube-system`). Helm Controller adopts and
upgrades that release in place; **never uninstall Cilium during hand-off**.

The chart comes from Cilium's official OCI repository on Quay. Both bootstrap
and Flux are digest-pinned, and Flux verifies the chart's keyless Cosign
signature against Cilium's GitHub Actions identity.

```bash
mise run bootstrap-cilium
mise x -- cilium status --wait
mise x -- cilium connectivity test \
  --ip-families ipv4 \
  --namespace-labels 'pod-security.kubernetes.io/enforce=privileged,pod-security.kubernetes.io/warn=privileged,pod-security.kubernetes.io/audit=privileged'
```

The elevated labels apply only to disposable Cilium test namespaces; the
official connectivity test requires host networking, host ports and `NET_RAW`.

## Encrypted workload DNS

The network layer takes ownership of Talos' bootstrap CoreDNS ConfigMap and forwards
recursive queries to Cloudflare with DNS-over-TLS on TCP 853. Pod-to-CoreDNS
traffic stays cluster-local; cross-node traffic is protected by KubeSpan.
Talos host/bootstrap DNS remains ordinary DNS because `ResolverConfig` does
not implement DoT/DoH transports.

CoreDNS and the Cilium `HelmRelease` opt out of Flux pruning. The network
Kustomization and bootstrap root use `deletionPolicy: Orphan`, so deleting the
B2 source cannot cascade into removing cluster networking or DNS.

## Kubelet serving certificates

The certificates layer installs `kubelet-serving-cert-approver` v0.11.0 with a multi-arch
image pinned by digest. It validates node identity and SANs before approving
Talos kubelet serving CSRs, keeping logs, exec and metrics-server functional
across certificate rotations.

## 4. Create B2 keys

[`terraform/b2`](terraform/b2) uses Terraform to create the private bucket and three
least-privilege application keys. The root `b2-terraform` fnox profile loads the
account-level B2 key from `talos.nokiy.net/b2-terraform-admin` only for local
plan/apply subprocesses:

```bash
mise run b2:tf:init
mise run b2:tf:plan
mise run b2:tf:apply
```

The account-level key is not used by workloads or stored in fnox. Terraform
stores generated application-key secrets in the Terraform-managed 1Password
item. State is stored in the HCP Terraform `talos-b2` workspace and also
contains those values, so workspace access must be restricted; see
[`terraform/b2/README.md`](terraform/b2/README.md) before the first apply.

| Key | Prefix restriction | Capabilities | Stored in |
|---|---|---|---|
| Publisher | `clusters/production/` | `writeFiles` | 1Password, then GitHub Environment |
| Flux reader | Entire `talos-nokiy-net` bucket | `listFiles`, `readFiles`, plus “List All Bucket Names” | 1Password, then Kubernetes Secret |
| Recovery reader | `clusters/production/releases/` | `readFiles` | 1Password only |

Terraform keeps the trailing slash in every key restriction. Flux's generic S3
client performs a bucket-existence check, so only its reader receives
`listBuckets` in addition to object list/read access.

## 5. Create the 1Password layout

[`fnox.toml`](fnox.toml) expects these exact vault, item and field names.

### Vault `talos.nokiy.net`

Item `b2-talos-nokiy-net`:

| Section | Fields |
|---|---|
| `configuration` | `ENDPOINT`, `REGION`, `BUCKET`, `CURRENT_PREFIX`, `RELEASES_PREFIX` |
| `publisher` | `ACCESS_KEY`, `SECRET_KEY` |
| `flux_reader` | `READ_ACCESS_KEY`, `READ_SECRET_KEY` |
| `recovery_reader` | `RECOVERY_ACCESS_KEY`, `RECOVERY_SECRET_KEY` |

Terraform owns all four sections. fnox addresses each unique field directly as
`op://vault/item/FIELD`; section names are not part of the reference path.

Check references without exporting values into your shell:

```bash
mise exec -- fnox --profile publisher check --no-defaults
mise exec -- fnox --profile flux-bootstrap check --no-defaults
```

## 6. Publish and configure GitHub Actions

Test the publisher locally first:

```bash
mise run publish-b2
```

After the GitHub repository/remote exists, create the `production`
Environment. This local task reads the Publisher vault and stores its five
non-secret settings as GitHub Variables and its two B2 credentials as GitHub
Secrets. It also restricts the Environment to the `main` branch, so a manually
dispatched workflow from another ref cannot receive the publisher:

```bash
mise run configure-github
```

GitHub Actions installs only the explicitly listed locked CI tools, invokes
tasks with `mise run --skip-tools`, and reads only its own `production`
Environment. It neither installs fnox/`op` nor contacts 1Password. Rotate the
publisher by updating the Publisher item and rerunning `mise run
configure-github`.

Every merge to `main` writes the versioned audit copy first and the active object
last. Run `configure-github` before adding manual Environment protection rules.
If your GitHub plan supports required reviewers for a private repository, add
them afterward when deployment needs approval; later task runs preserve them.

## 7. Bootstrap Flux from B2

The active object must already exist before this step:

```bash
mise run bootstrap-flux
```

The task uses the `flux-bootstrap` fnox profile. It preflights B2 HEAD/LIST/GET,
applies the Flux release declared by Helmfile, and creates
`flux-system/b2-flux-reader` without putting secret values on disk or in argv.
Only that bucket-scoped, read-only B2 reader is persisted in Kubernetes.

Flux source-controller probes the bucket-root `.sourceignore` object even when
the Bucket source has a narrower `spec.prefix`. The reader is therefore scoped
to the complete bucket, but remains read-only; reconciliation still lists and
applies only the active immutable release selected by
`clusters/production/current/entrypoint/release.yaml`.

Flux bootstrap disables Helm's atomic rollback for the controller release. A
failed install remains available for inspection instead of removing Flux CRDs
and existing custom resources during automatic cleanup.

Bootstrap ownership is intentionally narrow:

| Layer | Declarative source | Long-term owner |
|---|---|---|
| Talos, Kubernetes versions and machine allocation | Omni Cluster Template | Omni |
| Initial Cilium and Flux releases | `bootstrap/helmfile.yaml.gotmpl` | Flux after hand-off |
| B2 reader Secret and root Bucket/Kustomization | `bootstrap/b2-source.yaml.tpl` plus 1Password injection | Operator bootstrap boundary |
| Release selection | `current/entrypoint/release.yaml` generated from the Git SHA | Root Flux Kustomization |
| Network layer | `clusters/production/network` | `cluster-network` Kustomization |
| Certificate layer | `clusters/production/certificates` | `cluster-certificates` Kustomization |
| System layer | `clusters/production/system` | `cluster-system` Kustomization |

Flux cannot store its own initial reader credential inside the B2 release it
needs that credential to fetch. This one out-of-band Secret is therefore an
intentional bootstrap boundary.

Verify the hand-off:

```bash
flux get sources bucket -n flux-system
flux get kustomizations -n flux-system
flux get helmreleases -A
helm status cilium -n kube-system
mise run status
```

To rotate the reader, update `B2 Runtime` in 1Password and run:

```bash
mise run sync-flux-secret
flux reconcile source bucket cluster-config -n flux-system
```

Neither fnox nor 1Password tooling is installed on Talos. Runtime credentials
are synchronized explicitly from the operator's local 1Password Desktop CLI
session.

## Rollback

Normal rollback is a Git revert merged to `main`. For an emergency restore of
a versioned release:

```bash
mise run rollback-b2 <git-sha>
flux reconcile source bucket cluster-config -n flux-system
flux reconcile kustomization cluster-config -n flux-system --with-source
flux get kustomizations -n flux-system
```

The rollback profile downloads the archived release entrypoint with the
releases-only reader, then atomically restores it with the write-only publisher.
The entrypoint selects the complete immutable snapshot; layer files are never
copied during rollback. GitHub never receives recovery access.

## Security boundary

B2 `Bucket` artifacts are checksummed by Flux but cannot be verified with
Cosign like OCI artifacts. Compensating controls here are separate
prefix-scoped keys, a private bucket that retains release versions (and can use
Object Lock when required),
1Password vault separation, GitHub Environment approval, branch protection,
digest-pinned Cilium, and deletion protection for the CNI/DNS resources.

If cryptographic verification of the complete configuration artifact becomes
mandatory, publish a signed artifact to a real OCI Distribution registry and
replace the Flux `Bucket` with an `OCIRepository`; an S3 bucket alone is not an
OCI registry.

References: [fnox 1Password provider](https://fnox.jdx.dev/providers/1password.html),
[fnox configuration](https://fnox.jdx.dev/reference/configuration),
[mise tasks](https://mise.jdx.dev/tasks/toml-tasks.html),
and [Flux Bucket sources](https://fluxcd.io/flux/components/source/buckets/).
