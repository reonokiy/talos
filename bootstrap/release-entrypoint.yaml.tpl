apiVersion: source.toolkit.fluxcd.io/v1
kind: Bucket
metadata:
  name: cluster-release
  namespace: flux-system
spec:
  provider: generic
  interval: 1m
  timeout: 60s
  bucketName: ${B2_BUCKET}
  endpoint: ${B2_ENDPOINT}
  region: ${B2_REGION}
  prefix: ${B2_RELEASE_PREFIX}
  secretRef:
    name: b2-flux-reader
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-network
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 1m
  timeout: 10m
  wait: true
  prune: true
  deletionPolicy: Orphan
  sourceRef:
    kind: Bucket
    name: cluster-release
  path: ${B2_RELEASE_PATH}/clusters/production/network
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-certificates
  namespace: flux-system
spec:
  dependsOn:
    - name: cluster-network
  interval: 5m
  retryInterval: 1m
  timeout: 10m
  wait: true
  prune: true
  deletionPolicy: Orphan
  sourceRef:
    kind: Bucket
    name: cluster-release
  path: ${B2_RELEASE_PATH}/clusters/production/certificates
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-system
  namespace: flux-system
spec:
  dependsOn:
    - name: cluster-certificates
  interval: 5m
  retryInterval: 1m
  timeout: 10m
  wait: true
  prune: true
  sourceRef:
    kind: Bucket
    name: cluster-release
  path: ${B2_RELEASE_PATH}/clusters/production/system
