# Longhorn

Longhorn `1.12.0` is installed as an intentionally zero-capacity storage
control plane. The current Netcup nodes expose only `/dev/vda`, which contains
Talos system and EPHEMERAL volumes. Longhorn replica data must not share that
disk with etcd, kubelet state, container images, or logs. The controller Pods,
images, and their small runtime state still consume normal node resources.

The fail-closed controls are deliberate:

- the chart creates no `StorageClass`;
- new nodes do not receive a default Longhorn disk;
- `/var/mnt/longhorn` is the only accepted future data path;
- there are currently no disks on which any selector can schedule a replica;
- degraded volumes cannot be created; and
- the V2/SPDK data engine is disabled.

Do not add the `node.longhorn.io/create-default-disk` label or the
`node.longhorn.io/default-disks-config` annotation to any node while
`/var/mnt/longhorn` is backed by the system disk. The UI is unauthenticated,
has no Ingress or HTTPRoute, and a NetworkPolicy rejects normal cluster
ingress. Administrative access uses Kubernetes RBAC and port-forwarding:

```bash
kubectl -n longhorn-system port-forward service/longhorn-frontend 8080:80
```

## Merge and rollout gates

Before this release is merged and reconciled, use Omni to install these Talos
system extensions on every Kubernetes node, roll one node at a time, and verify
them after each reboot:

- `siderolabs/iscsi-tools`
- `siderolabs/util-linux-tools`

Also verify at least 4 vCPU and 4 GiB RAM per node, leave extra headroom because
these nodes also run the control plane, and run the Longhorn `1.12.0` preflight
check. Confirm that no live node already carries Longhorn disk opt-in metadata:

```bash
kubectl get nodes -L node.longhorn.io/create-default-disk
kubectl get nodes \
  -o custom-columns=NODE:.metadata.name,DISK_CONFIG:.metadata.annotations.node\\.longhorn\\.io/default-disks-config
```

The repository does not claim these live checks have already passed.

After Flux reports the release Ready, verify that the installation has zero
usable capacity and no StorageClass:

```bash
flux get kustomization cluster-storage -n flux-system
flux get helmrelease longhorn -n longhorn-system
kubectl get pods -n longhorn-system
kubectl get storageclass
kubectl -n longhorn-system get nodes.longhorn.io \
  -o custom-columns=NODE:.metadata.name,ALLOW_SCHEDULING:.spec.allowScheduling,DISKS:.spec.disks
```

## Enabling capacity later

Capacity requires a separate reviewed change after all three nodes receive a
dedicated non-system block device. That change must land as one atomic rollout:

1. Select each device by a stable, node-specific serial or WWN in a Talos
   `UserVolumeConfig`. Never use a selector that can match `system_disk`.
2. Mount the resulting volume at `/var/mnt/longhorn` and add the kubelet bind
   mount with `bind`, `rshared`, and `rw` options.
3. Confirm the mount source and free capacity before opting the node into
   Longhorn disk creation.
4. Measure RTT and throughput between every storage-node pair. Do not enable a
   three-replica synchronous StorageClass across high-latency links.
5. Give every schedulable Longhorn node and disk an explicit dedicated-storage
   tag. With `allowEmpty*SelectorVolume=false`, empty volume selectors can still
   use *untagged* resources, so no untagged disk may be schedulable.
6. Add an explicit, non-default StorageClass that requires those node and disk
   tags, uses V1 engine, three replicas and `Retain`, and has a tested
   backup/restore procedure.

Longhorn replicas are not backups. A future backup target must use a separate
private B2 bucket and a dedicated runtime key with the delete permissions
Longhorn requires; it must not reuse the immutable Flux release bucket or any
publisher, reader, or recovery credential.

## Maintenance, upgrade, and removal

Drain or upgrade one Talos node at a time and wait for every volume to become
Healthy before touching the next node. Before a Longhorn upgrade, take a system
backup and volume backups, check that no volume is Faulted, run the version's
preflight check, and upgrade only one supported minor version at a time. Engine
upgrades remain manual because automatic engine upgrades are disabled.

Longhorn does not support downgrades. B2 emergency rollback therefore requires
the archived marker, archived manifest, current checkout, live desired version,
and latest successfully installed Helm release to carry the same chart version.
The HelmRelease must be Ready, not Reconciling, and observed at its current
generation; missing history or an unreachable cluster fails closed. A Git
revert that lowers the chart version is also forbidden. Removing this directory
is not an uninstall procedure: pruning is disabled, CRDs are kept, and the Flux
storage layer uses `deletionPolicy: Orphan`. Follow the upstream uninstall
procedure in a dedicated, reviewed maintenance window.

Upstream references:

- <https://longhorn.io/docs/1.12.0/advanced-resources/os-distro-specific/talos-linux-support/>
- <https://longhorn.io/docs/1.12.0/best-practices/>
- <https://longhorn.io/docs/1.12.0/deploy/install/install-with-flux/>
- <https://longhorn.io/docs/1.12.0/deploy/upgrade/>
- <https://longhorn.io/docs/1.12.0/maintenance/maintenance/>
