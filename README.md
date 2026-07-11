# Talos + Cilium + Flux + Backblaze B2

This repository bootstraps Cilium on a Talos/Omni cluster, installs Flux
without a Git source, and lets Flux reconcile one rendered manifest bundle
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
GitHub main ── GitHub Actions ── render one bundle.yaml ── Backblaze B2
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
only the B2 key that can list/read `clusters/production/current/`; it never
receives a publisher key or any 1Password authentication material.

`bundle.yaml` is a single S3 `PutObject`, so Flux cannot observe half of a
multi-file deployment. A versioned audit copy is written to the releases prefix
first. Both objects carry the Git commit and bundle SHA-256 in object metadata.
Flux Bucket artifacts retain the complete object key, so the generated Flux
`Kustomization` uses `./clusters/production/current` as its path.

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

The bundle takes ownership of Talos' bootstrap CoreDNS ConfigMap and forwards
recursive queries to Cloudflare with DNS-over-TLS on TCP 853. Pod-to-CoreDNS
traffic stays cluster-local; cross-node traffic is protected by KubeSpan.
Talos host/bootstrap DNS remains ordinary DNS because `ResolverConfig` does
not implement DoT/DoH transports.

CoreDNS and the Cilium `HelmRelease` opt out of Flux pruning. The root Flux
`Kustomization` also uses `deletionPolicy: Orphan`, so deleting the B2 source
cannot cascade into removing cluster networking or DNS.

## Kubelet serving certificates

The bundle installs `kubelet-serving-cert-approver` v0.11.0 with a multi-arch
image pinned by digest. It validates node identity and SANs before approving
Talos kubelet serving CSRs, keeping logs, exec and metrics-server functional
across certificate rotations.

## 4. Create B2 keys

Create one private B2 bucket and three application keys. Do not use the B2
master key. Keep all file versions for the releases prefix; optionally enable
B2 Object Lock/default retention when those audit versions must be immutable.

| Key | Prefix restriction | Capabilities | Stored in |
|---|---|---|---|
| Publisher | `clusters/production/` | `writeFiles` | Publisher vault, then GitHub Environment |
| Flux reader | `clusters/production/current/` | `listFiles`, `readFiles`, plus “List All Bucket Names” | Runtime vault |
| Recovery reader | `clusters/production/releases/` | `readFiles` | Runtime vault |

Keep the trailing slash in both B2 restrictions and 1Password fields. Flux's
generic S3 client performs a bucket-existence check, so the Flux reader must
have “List All Bucket Names”.

## 5. Create the 1Password layout

[`fnox.toml`](fnox.toml) expects these exact vault, item and field names.

### Vault `Talos GitOps Publisher`

Item `B2 Publisher`:

| Field | Example |
|---|---|
| `endpoint` | `s3.eu-central-003.backblazeb2.com` |
| `region` | `eu-central-003` |
| `bucket` | `my-flux-artifacts` |
| `current-prefix` | `clusters/production/current/` |
| `releases-prefix` | `clusters/production/releases/` |
| `access-key-id` | Publisher B2 application key ID |
| `secret-access-key` | Publisher B2 application key |

### Vault `Talos GitOps Runtime`

Item `B2 Runtime`:

| Field | Value |
|---|---|
| `reader-key-id` | Flux B2 application key ID |
| `reader-application-key` | Flux B2 application key |
| `recovery-key-id` | Recovery B2 application key ID |
| `recovery-application-key` | Recovery B2 application key |

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

After the private GitHub repository/remote exists, create the `production`
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
Only that prefix-scoped B2 reader is persisted in Kubernetes.

Bootstrap ownership is intentionally narrow:

| Layer | Declarative source | Long-term owner |
|---|---|---|
| Talos, Kubernetes versions and machine allocation | Omni Cluster Template | Omni |
| Initial Cilium and Flux releases | `bootstrap/helmfile.yaml.gotmpl` | Flux after hand-off |
| B2 reader Secret and root Bucket/Kustomization | `bootstrap/b2-source.yaml.tpl` plus 1Password injection | Operator bootstrap boundary |
| Workload and infrastructure manifests | `clusters/production` | Flux |

Flux cannot store its own initial reader credential inside the B2 bundle it
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
```

The rollback profile downloads with the releases-only reader, then uploads
with the write-only publisher. GitHub never receives recovery access.

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
