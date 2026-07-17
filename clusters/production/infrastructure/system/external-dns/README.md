# ExternalDNS

ExternalDNS watches only explicitly opted-in Traefik Ingress resources and
publishes their status addresses into the `nokiy.net` Cloudflare zone.

Before publishing this release, apply the repository's
`terraform/cloudflare` stack. In vault `talos.nokiy.net`, it creates item
`external-dns` with section `cloudflare` and these fields:

| Section field | Purpose |
|---|---|
| `api-token` | Cloudflare API Token restricted to Zone Read and DNS Edit for `nokiy.net` |
| `zone-id` | Cloudflare zone identifier for `nokiy.net` |

Do not use a Global API Key. The token and zone identifier reconcile into the
`external-dns/external-dns-cloudflare` Secret through the central
`ClusterSecretStore/onepassword`; neither value belongs in Git or B2.

An Ingress is ignored unless it has both the Traefik class and opt-in label:

```yaml
metadata:
  labels:
    dns.nokiy.net/publish: enabled
  annotations:
    external-dns.alpha.kubernetes.io/ttl: "60"
spec:
  ingressClassName: traefik
```

The controller uses `policy: sync` with the TXT registry, a cluster-specific
owner ID, the `nokiy.net` domain filter and the opt-in label filter. When Cilium
Node IPAM removes an unavailable node from Ingress status, ExternalDNS removes
that address from the owned multi-A record. It does not manage records without
the matching ownership TXT record.

Do not add static target IP filters here. Cilium's Service node selector is the
source of truth, so a replaced control-plane node can publish its new address
without a repository change. The 60-second record TTL bounds resolver caching;
actual client failover still depends on each resolver and client honoring DNS
TTL and retrying another returned address.

Records are DNS-only by default. Enabling the Cloudflare proxy changes the
source-address and failover model and requires separately reviewed forwarded
header trust in Traefik.

Verify the rollout through resource conditions and public DNS; never inspect
the generated Secret or enable provider debug logging:

```bash
kubectl -n external-dns wait externalsecret/cloudflare \
  --for=condition=Ready --timeout=2m
kubectl -n external-dns rollout status deployment/external-dns
kubectl -n traefik get service traefik
kubectl get ingress -A -l dns.nokiy.net/publish=enabled
dig +short A <published-hostname>
```
