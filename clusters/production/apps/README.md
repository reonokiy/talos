# Application secrets

External Secrets is intentionally namespaced. Each application directory that
needs secrets must declare its own `SecretStore`; do not add a
`ClusterSecretStore`, `ClusterExternalSecret`, `PushSecret`, or
`ClusterPushSecret`.

The only supported provider is the `talos.nokiy.net` 1Password vault:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: onepassword
  namespace: example
spec:
  provider:
    onepasswordSDK:
      vault: talos.nokiy.net
      auth:
        serviceAccountSecretRef:
          name: onepassword-service-account
          key: token
```

Every item title must start with its Kubernetes namespace and `/`:

```text
<namespace>/<application-or-purpose>
```

For example, an `example` namespace may read fields from the
`example/database` item, but admission rejects references to
`another-namespace/database`. Declare explicit item and field references. Field
labels within an item must be unique. `dataFrom`, `find`, and `extract` are
forbidden because they can bypass the item-prefix boundary. Generated Secrets
are owned by their `ExternalSecret`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: example
  namespace: example
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: onepassword
  target:
    name: example
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: password
      remoteRef:
        key: example/database/password
```

After Flux creates a new application namespace, provision its bootstrap token
without exposing it:

```console
mise run sync-external-secrets-secret -- example
```

The Service Account is vault-scoped, so every application Store can read any
item in `talos.nokiy.net`. Namespaced Stores prevent cross-namespace Store
references, while a `ValidatingAdmissionPolicy` enforces item-title prefixes at
the Kubernetes API. These controls prevent configuration-level cross-namespace
access but cannot provide cryptographic item isolation inside a single vault.
