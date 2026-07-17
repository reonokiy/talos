# Traefik public entry

Traefik runs as one DaemonSet Pod on each control-plane node. Cilium Node IPAM
publishes the selected node addresses in the Traefik LoadBalancer Service
status. Traefik copies that status into every managed Ingress, giving
ExternalDNS one deterministic source for the three public A-record targets.

These Talos nodes currently expose their public addresses as Kubernetes
`InternalIP` values and have no `ExternalIP`. Cilium Node IPAM prefers
`ExternalIP` when one exists and otherwise uses `InternalIP`, so this design
does not mutate Node status or require manually configured Service
`externalIPs`.

The Service uses `externalTrafficPolicy: Local` so each advertised node sends
traffic only to its local Traefik Pod and preserves the client source address.
The API, dashboard, health entrypoint and Prometheus endpoint are not exposed
through the public Service.

The provider firewall must allow inbound TCP 80 and 443 to all three node
addresses. No other Traefik port needs public exposure.

Every public application Ingress must explicitly set:

```yaml
metadata:
  labels:
    dns.nokiy.net/publish: enabled
  annotations:
    external-dns.alpha.kubernetes.io/ttl: "60"
spec:
  ingressClassName: traefik
```

Traefik does not run an ACME resolver and does not persist certificate
material. Each TLS Ingress must reference a namespaced TLS Secret provisioned
by a separately reviewed certificate workflow; this repository does not yet
install cert-manager. The default TLS policy requires TLS 1.2 or newer and
rejects unknown SNI names.

Talos adds `node.kubernetes.io/exclude-from-external-load-balancers` to
control-plane nodes by default. The Omni cluster patch removes it because these
three public control-plane nodes are intentionally the ingress endpoints.
