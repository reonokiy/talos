apiVersion: source.toolkit.fluxcd.io/v1
kind: Bucket
metadata:
  name: cluster-config
  namespace: flux-system
spec:
  provider: generic
  interval: 1m
  timeout: 60s
  bucketName: ${B2_BUCKET}
  endpoint: ${B2_ENDPOINT}
  region: ${B2_REGION}
  prefix: ${B2_PREFIX}
  secretRef:
    name: b2-flux-reader
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-config
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 1m
  timeout: 10m
  wait: true
  prune: true
  # Removing this root object must not garbage-collect Cilium/CoreDNS and take
  # the cluster network down. Source changes still prune ordinary resources.
  deletionPolicy: Orphan
  sourceRef:
    kind: Bucket
    name: cluster-config
  # Bucket artifacts retain the complete object key; spec.prefix filters the
  # listing but does not strip the prefix from paths in the artifact.
  path: ${B2_KUSTOMIZE_PATH}
