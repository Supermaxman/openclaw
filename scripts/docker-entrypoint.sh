#!/bin/sh
set -e

# Start Docker daemon if installed
if command -v dockerd >/dev/null 2>&1; then
  # Prefer overlay2 (try loading module, but it may be built into the kernel)
  modprobe overlay 2>/dev/null || true
  if grep -q overlay /proc/filesystems; then
    STORAGE_DRIVER=overlay2
  else
    STORAGE_DRIVER=fuse-overlayfs
  fi

  # Rewrite /etc/resolv.conf so dockerd can resolve registry hostnames.
  # Keep Docker's embedded DNS (127.0.0.11) first for container name resolution
  # on shared Docker networks, then fall back to public DNS for external lookups
  # (needed by inner dockerd for registry pulls).
  cat > /etc/resolv.conf <<REOF
nameserver 127.0.0.11
nameserver 8.8.8.8
nameserver 1.1.1.1
REOF

  # Remount cgroup2 as writable so dockerd can manage container cgroups
  mount -o remount,rw /sys/fs/cgroup

  # Remount /proc/sys as writable so dockerd can configure IPv6 on veth
  # interfaces. This is safe — /proc/sys/net is network-namespaced and
  # can't affect the host.
  mount -o remount,rw /proc/sys

  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<DEOF
{"storage-driver":"$STORAGE_DRIVER"}
DEOF

  dockerd --log-level=warn &>/var/log/dockerd.log &
  # Wait for Docker socket
  timeout=30
  while [ ! -S /var/run/docker.sock ] && [ "$timeout" -gt 0 ]; do
    sleep 1
    timeout=$((timeout - 1))
  done
  if [ -S /var/run/docker.sock ]; then
    echo "dockerd started (storage: $STORAGE_DRIVER)"
  else
    echo "WARNING: dockerd failed to start, check /var/log/dockerd.log" >&2
  fi
fi

# Drop to node user and exec the main process
exec su -s /bin/sh node -c "exec $*"
