# Talos and Omni desired state

[`cluster-template.yaml`](cluster-template.yaml) is the authoritative Sidero
Omni declaration for the production cluster. Omni remains the only owner of
machine allocation and Talos machine configuration; do not apply these patches
directly with `talosctl patch machineconfig`.

## Declared cluster

| Setting | Desired state |
|---|---|
| Omni cluster | `talos-default` |
| Talos | `v1.13.6` |
| Kubernetes | `v1.36.2` |
| Control planes | 3 static machines declared in the template |
| Workers | empty machine set preserved for future nodes |
| Talos install disk | `/dev/vda` on every machine |
| Extensions | `iscsi-tools`, `qemu-guest-agent`, `util-linux-tools` |
| Automatic etcd backup | every 1 hour |

The template preserves the existing user-managed Omni ConfigPatch resource IDs
and their merge order:

- `200-talos-default` uses the existing `cluster-patch.yaml`;
- `300-talos-default-kubelet` preserves kubelet serving-certificate rotation;
- `400-talos-default-longhorn-storage` declares the storage layout and mount;
- `500-ced320a4-4f06-4b3a-8efd-a962ae219a28` preserves the current resolver
  patch.

`cluster-patch.yaml` still contains the repository's earlier resolver document.
The current live `500` resolver patch intentionally wins later in Omni's
ConfigPatch order. Omni-generated discovery and disk-encryption system patches
remain generated from the cluster `features` block.

## System-disk storage layout

Every current machine has one 256 GiB virtio system disk. The desired layout is:

| Area | Size | Purpose |
|---|---:|---|
| Talos `EPHEMERAL` | 96 GiB | `/var`, images, kubelet and control-plane runtime data |
| `longhorn` user volume | 150 GiB | XFS mounted by Talos at `/var/mnt/longhorn` |
| Remaining space | about 10 GiB | Talos system partitions and allocation/alignment margin |

The Longhorn volume selector is `system_disk`, not `/dev/vda` or a size-only
selector. Talos therefore allocates the volume only on the disk it booted from.
The kubelet receives the required `rshared` bind mount for
`/var/mnt/longhorn`. Longhorn must use that same path as its default data path.

### Existing machines require reprovisioning

Applying the template does not shrink an already provisioned `EPHEMERAL`
partition. The three existing control-plane nodes therefore will not gain the
150 GiB volume until they are reprovisioned. Do not wipe or reprovision all
control planes together.

Before changing the first node, require all of the following:

1. Omni reports a recent successful etcd backup.
2. Kubernetes nodes, etcd, Cilium and Flux are healthy.
3. The Omni template has been applied and the new machine schematic (including
   `util-linux-tools`) is available.

Then drain and reprovision exactly one control-plane machine through Omni, wait
for it to rejoin and become healthy, and only then continue with the next
machine. Reprovisioning destroys the selected node's local `EPHEMERAL` data.
Keep Longhorn disk scheduling disabled until all three nodes report the
`longhorn` volume mounted at `/var/mnt/longhorn`.

## CLI workflow

The repository exposes file-backed `mise` tasks under `.mise/tasks/omni/`:

```bash
mise run omni:validate
mise run omni:diff
mise run omni:plan
mise run omni:apply
mise run omni:status
```

- `omni:validate` is offline.
- `omni:diff` reads current Omni state without changing it.
- `omni:plan` runs `sync --dry-run --verbose`.
- `omni:apply` repeats validation and dry-run, requires typing the cluster name,
  then runs the real sync and waits for readiness.
- `omni:status` reports current template status without waiting.

Always review the diff for unexpected deletions before confirming `omni:apply`.
The first apply can roll nodes because adding `util-linux-tools` changes their
Talos image schematic. It still cannot resize the existing disk layout without
the separate, deliberate per-node reprovisioning described above.
