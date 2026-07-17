# Application secrets

External Secrets uses one centrally managed `ClusterSecretStore` backed by the
`talos.nokiy.net` 1Password vault. Its Service Account token exists only in the
`external-secrets` namespace. Application directories must not declare
`SecretStore`, `ClusterSecretStore`, `ClusterExternalSecret`, `PushSecret`, or
`ClusterPushSecret` resources.

Label each namespace that is allowed to use the central Store:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: example
  labels:
    secrets.nokiy.net/onepassword: enabled
```

Each item title must exactly equal its Kubernetes namespace. Put every
application or purpose in its own section, and reference fields as:

```text
<namespace-item>/<section>/<field>
```

For example, the key `example/database/password` reads the `password` field
from section `database` of the item named `example`. Admission rejects a first
path segment that differs from the ExternalSecret namespace. Declare explicit
item, section, and field references. Field labels within a section must be
unique. `dataFrom`, `find`, and `extract` are forbidden because they can bypass
the namespace-matched item boundary. Generated Secrets are owned by their
`ExternalSecret`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: example
  namespace: example
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
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

Provision the central bootstrap token once, after the `external-secrets`
namespace exists:

```console
mise run sync-external-secrets-secret
```

The Store condition admits only explicitly labeled namespaces, while a
`ValidatingAdmissionPolicy` requires the item path segment to equal the
ExternalSecret namespace at the Kubernetes API.
The Service Account remains vault-scoped, so these controls prevent
configuration-level cross-namespace access but cannot provide cryptographic
item isolation inside a single vault.

## Public DNS opt-in

ExternalDNS watches only Ingress resources explicitly labeled for publication.
Every public Ingress must select Traefik and opt in:

```yaml
metadata:
  labels:
    dns.nokiy.net/publish: enabled
  annotations:
    external-dns.alpha.kubernetes.io/ttl: "60"
spec:
  ingressClassName: traefik
```

ExternalDNS publishes the addresses that Traefik copies from its Cilium Node
IPAM LoadBalancer Service. Do not hard-code node addresses in application
annotations. The 60-second DNS TTL bounds normal resolver caching during node
failover. Cloudflare proxying is disabled by default and requires a separate
review because it changes source-IP and forwarded-header trust.
