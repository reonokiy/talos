# Repository Agent Guide

This file applies to the entire repository. Treat it as mandatory operational
policy, especially the secret-handling rules below.

## Repository Purpose

This repository declares and operates one production Kubernetes cluster built
with Talos Linux and Sidero Omni. Talos and Omni create the machines and base
cluster. Cilium supplies networking without kube-proxy, Flux reconciles the
long-lived cluster configuration, and Backblaze B2 is the immutable release
source consumed by Flux.

The repository intentionally does not use Git as the in-cluster Flux source.
GitHub Actions publishes reviewed Git revisions to B2, and Flux reads those B2
artifacts with a dedicated read-only application key.

## Architecture and Ownership

### Talos and Omni

- `talos/cluster-patch.yaml` is the Omni cluster-level machine configuration
  patch. It disables Flannel and kube-proxy, enables the settings required by
  Cilium, configures KubeSpan, and defines host resolver behavior.
- Omni owns machine allocation, Talos configuration delivery, and Kubernetes
  lifecycle. Do not model these resources as Flux workloads.
- A new cluster has no functional CNI until the bootstrap Cilium release is
  installed. Preserve this ordering during bootstrap and recovery work.

### Bootstrap boundary

- `bootstrap/helmfile.yaml.gotmpl` declaratively installs the initial Cilium
  release and the Flux controllers.
- Cilium bootstrap and its Flux `HelmRelease` use the same release name,
  namespace, chart version, and values. Flux adopts and upgrades the existing
  release in place. Never uninstall Cilium as part of this hand-off.
- Flux controllers are owned by the local Helmfile bootstrap boundary, not by
  Flux itself. Upgrade them by changing the pinned chart and controller values,
  validating the change, and running the bootstrap task.
- Helm atomic cleanup is disabled for the Flux release. A failed Flux upgrade
  must remain inspectable and must not remove controllers or CRDs automatically.
- `bootstrap/b2-source.yaml.tpl` creates the out-of-band B2 reader Secret, the
  active `Bucket`, and the root `cluster-config` Kustomization.
- `bootstrap/release-entrypoint.yaml.tpl` is rendered for each Git revision. It
  pins the immutable release source and declares the layered Flux pipeline.

### Production cluster layout

This is intentionally a single-cluster repository. All continuously reconciled
resources live below `clusters/production/`:

```text
clusters/production/
├── infrastructure/
│   ├── network/
│   │   ├── cilium/
│   │   └── coredns/
│   ├── certificates/
│   │   └── kubelet-serving-cert-approver/
│   ├── secrets/
│   │   └── external-secrets/
│   └── system/
│       └── metrics-server/
├── apps/
│   └── kustomization.yaml
└── kustomization.yaml
```

- `infrastructure/network` owns cluster networking and DNS.
- `infrastructure/certificates` owns kubelet serving-certificate approval and
  similar certificate prerequisites.
- `infrastructure/secrets` owns External Secrets Operator, its CRDs, admission
  policies, and other cluster-wide secret-management safeguards.
- `infrastructure/system` owns cluster services that depend on networking and
  certificates and secret management, such as Metrics Server.
- `apps` is reserved for application workloads. Do not place cluster-wide
  controllers or shared application prerequisites there.
- If another cluster later requires reuse, extract explicit shared bases then.
  Do not add premature base/overlay indirection to this single-cluster layout.

### Flux reconciliation layers

The generated release entrypoint creates five Kustomizations over one immutable
`cluster-release` Bucket artifact:

```text
cluster-network
  -> cluster-certificates
  -> cluster-secrets
  -> cluster-system
  -> cluster-apps
```

- Ordering is expressed with Flux `spec.dependsOn`, never directory order.
- Each layer has independent health, inventory, pruning, and failure status.
- Network and certificate layers use `deletionPolicy: Orphan` to avoid a source
  or control-plane mistake cascading into loss of critical cluster services.
- Cilium and CoreDNS also carry resource-level pruning protection.
- The secrets layer uses `deletionPolicy: Orphan`; loss of a release source must
  not remove External Secrets CRDs, admission policy, or the controller while
  applications still depend on generated Secrets.
- External Secrets is currently in stage 2 of a CRD ownership repair. The
  `external-secrets-crds` HelmRelease is suspended after restoring every CRD
  and recording `helm.sh/resource-policy: keep` in release revision 2. The
  original `external-secrets` release is active with `installCRDs: true` and
  takes ownership of those established CRDs. Do not remove the suspended CRD
  release until every CRD reports the controller release as owner and the
  controller rollout is Ready; retirement requires a separate reviewed release
  and live-state verification.
- Put an application in its own Kustomize directory under `apps` when it needs
  an independent failure or pruning boundary. Avoid dependencies between normal
  applications; move shared controllers and prerequisites into infrastructure.

### Application secret management

External Secrets Operator reads application credentials from the single
1Password vault `talos.nokiy.net`. The operator and the single
`ClusterSecretStore/onepassword` are cluster infrastructure. Applications only
own namespaced `ExternalSecret` resources. Follow
`clusters/production/apps/README.md` when onboarding an application.

- Applications may create only `external-secrets.io/v1` `ExternalSecret`
  resources. Do not put `SecretStore`, `ClusterSecretStore`,
  `ClusterExternalSecret`, `PushSecret`, or `ClusterPushSecret` in an
  application directory.
- The infrastructure-owned Store uses `provider.onepasswordSDK`, vault
  `talos.nokiy.net`, and the single Secret
  `external-secrets/onepassword-service-account` key `token`. Never copy that
  Secret into application namespaces.
- An application namespace must carry label
  `secrets.nokiy.net/onepassword: enabled` before it can reference the central
  Store. Every `ExternalSecret` must set `secretStoreRef.kind` to
  `ClusterSecretStore` and `secretStoreRef.name` to `onepassword`.
- Name each 1Password item `<namespace>/<application-or-purpose>`. Every
  `spec.data[].remoteRef.key` must therefore have the form
  `<namespace>/<item>/<field>` and start with the `ExternalSecret` namespace
  followed by `/`.
- Use explicit `spec.data` mappings. `dataFrom`, `find`, and `extract` are
  forbidden because they can bypass the namespace item-prefix boundary.
- Generated Kubernetes Secrets must use `spec.target.creationPolicy: Owner`.
  Prefer `deletionPolicy: Retain` unless an application has a deliberate and
  reviewed reason to delete the Secret with its external source.
- Do not grant application ServiceAccounts permission to create or update
  `ClusterSecretStore` or `ExternalSecret`. The chart does not aggregate these
  permissions into the standard `view` or `edit` roles; Flux and cluster
  administrators own the declarations.
- The Kubernetes `ValidatingAdmissionPolicy` resources in
  `infrastructure/secrets/external-secrets/admission-policy.yaml` enforce the
  provider, vault, bootstrap Secret, ownership policy, explicit mappings, and
  namespace item prefix at admission time. Keep
  `scripts/check-external-secrets-policy.sh` aligned with those runtime rules.
- Provision the central bootstrap token once with
  `mise run sync-external-secrets-secret` after the `external-secrets` namespace
  exists. This is an out-of-band bootstrap operation like the Flux B2 reader.
  Never commit the token, render it into B2, or replicate it to applications.
- One vault cannot provide cryptographic item-level isolation: the Service
  Account token can read every item in `talos.nokiy.net`. Store namespace
  conditions, RBAC, item prefixes, and admission policy prevent configuration-level
  cross-namespace access, but they do not contain a compromised ESO controller
  or token. Do not describe this design as a hard 1Password authorization
  boundary.

### B2 release protocol

GitHub Actions publishes only the `clusters/` tree. The B2 layout is:

```text
clusters/production/releases/<git-sha>/
├── clusters/
├── manifest.sha256
└── release.yaml

clusters/production/current/entrypoint/release.yaml
```

- A Git-SHA release prefix is immutable and preserves the repository path
  structure used by local Kustomize validation.
- `scripts/render.sh` stages the repository snapshot, renders the release
  entrypoint, and creates the checksum manifest.
- `scripts/publish-b2.sh` uploads the complete immutable snapshot first. It
  updates the single active entrypoint object last, providing atomic promotion.
- Flux never consumes a partially uploaded revision because the active
  entrypoint references only a completed immutable release prefix.
- `scripts/rollback-b2.sh` restores an archived entrypoint. It does not copy all
  layer files because the entrypoint already references the immutable snapshot.
- Do not replace this protocol with an in-place multi-file sync under the active
  prefix. B2 has no multi-object transaction, and stale active files cannot be
  treated as an atomic release.

### Terraform, 1Password, and GitHub

- `terraform/b2` owns the private bucket, the publisher key, the Flux reader
  key, the recovery reader key, and the 1Password item receiving generated
  values.
- HCP Terraform provides remote state, locking, and state history. Terraform
  runs locally through the repository's fnox profile.
- The publisher can write only below the production prefix. GitHub Actions
  receives this key through the protected `production` Environment.
- The Flux reader is bucket-scoped and read-only. Bucket scope is required
  because source-controller probes the root `.sourceignore` object even when a
  narrower source prefix is configured.
- The recovery reader can read immutable releases but cannot publish them.
- GitHub Actions never connects to 1Password. Local operators provision GitHub
  Environment variables and secrets through the repository task.

### Normal workflows

- Use `mise` tasks and locked tools rather than ad hoc tool installation.
- Run `mise run check` for GitOps rendering checks and `mise run validate` when
  the required Terraform Cloud environment is available.
- A push to `main` runs `.github/workflows/publish-b2.yaml`, publishes the
  immutable snapshot, and atomically promotes its entrypoint.
- Use `mise run bootstrap-flux` only for the local Flux bootstrap/recovery
  boundary. Normal cluster changes flow through GitHub Actions and B2.
- Verify runtime state with Flux readiness, controller conditions, workload
  health, and non-secret Kubernetes status. Keep all layer revisions aligned.

## Mandatory Secret Safety

Never retrieve, inspect, reveal, decode, print, log, persist, or quote secret
values. This prohibition applies even when credentials are available locally,
the user is authenticated, or a command would technically be permitted.

### Allowed operations

- Read static configuration that contains only secret names, environment
  variable names, provider definitions, `op://` references, Kubernetes
  `secretRef` names, or field paths without resolved values.
- Run existing repository `mise` tasks that use `fnox exec` to inject secrets
  into their intended subprocess, provided the task does not expose values and
  no debugging or tracing mode is enabled.
- Inspect non-secret Kubernetes resources, readiness conditions, events,
  controller logs, APIService health, release status, and workload status.
- Confirm that a secret-consuming operation succeeded from its sanitized exit
  status or resource condition, without examining the secret itself.

### Forbidden operations

- Do not use `op read`, `op item get`, `op inject`, or equivalent commands to
  resolve or display values managed by 1Password.
- Do not use fnox lookup, export, reveal, or diagnostic commands to obtain
  managed values. Do not run fnox merely to inspect its resulting environment.
- Do not print or enumerate a secret-bearing environment with `env`, `printenv`,
  `set`, shell expansion, process environment files, debuggers, or similar
  mechanisms.
- Never enable `set -x`, shell tracing, verbose SDK logging, Terraform debug
  logging, or another mode that may expose arguments, headers, or environments.
- Do not place secret values in command-line arguments, temporary files,
  generated configuration, logs, patches, test fixtures, or chat responses.
- Do not inspect Terraform state, state backups, plans containing sensitive
  values, or sensitive `terraform output` values. In particular, do not read
  local files under `terraform/b2/.terraform` or any `*.tfstate*` file.
- Do not read Kubernetes Secret resources or their data with `kubectl get`,
  `kubectl describe`, JSON/JSONPath, YAML, templates, base64 decoding, API
  requests, or client libraries.
- Do not use Helm, Flux, Kustomize, or another renderer to display configuration
  containing resolved Secret values. Do not open generated artifacts known or
  suspected to contain rendered secrets.
- Do not copy Kubernetes Secret data into another resource for inspection.

### Secret-safe debugging

- Diagnose authentication and secret wiring through sanitized errors, object
  names, references, conditions, events, and controller behavior.
- If value-level verification would be needed, stop and ask the user to verify,
  replace, or rotate the credential manually. State exactly which reference or
  field name needs attention, never its expected value.
- Prefer existence checks performed by an existing secret-consuming task over
  direct Secret API reads. Do not create a new helper that reveals values.
- If a command unexpectedly emits a secret, stop immediately. Do not repeat,
  quote, summarize, or persist the output. Tell the user that accidental
  exposure may have occurred and recommend rotating the affected credential.

## Change Safety

- Preserve immutable release publication and active-entrypoint ordering.
- Preserve Flux Kustomization names when moving resources so inventories can be
  adopted without destructive recreation.
- Before changing ownership or paths, account for Flux pruning. Temporarily
  disable pruning during a controlled migration and restore it only after the
  new owner inventory is confirmed.
- Never uninstall Cilium, delete Flux CRDs, remove finalizers, or alter critical
  ownership metadata as a routine refactor. Such recovery actions require live
  state inspection and a deliberate migration sequence.
- Pin chart/image versions or digests and follow existing repository patterns.
- Keep generated `.build/` artifacts and local Terraform caches out of commits.
