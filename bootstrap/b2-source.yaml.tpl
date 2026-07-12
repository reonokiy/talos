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
  prefix: ${B2_ENTRYPOINT_PREFIX}
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
  wait: false
  # bootstrap-flux temporarily leaves pruning disabled while child
  # Kustomizations adopt resources from the legacy monolithic inventory.
  prune: false
  # Removing this root object must not garbage-collect Cilium/CoreDNS and take
  # the cluster network down. Source changes still prune ordinary resources.
  deletionPolicy: Orphan
  sourceRef:
    kind: Bucket
    name: cluster-config
  path: ${B2_ENTRYPOINT_PATH}
