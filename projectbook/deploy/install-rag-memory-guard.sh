#!/bin/sh
# Run as root on a Linux Docker host using systemd and cgroup v2.
set -eu
test "$(docker info --format '{{.CgroupDriver}}/{{.CgroupVersion}}')" = systemd/2
test -f /sys/fs/cgroup/cgroup.controllers
# One aggregate budget for every book, including manually deployed sidecars.
cat > /etc/systemd/system/projectbookrag.slice <<'EOF'
[Unit]
Description=ProjectBook optional search shared resource budget
[Slice]
MemoryAccounting=true
MemoryHigh=1152M
MemoryMax=1280M
MemorySwapMax=0
CPUQuota=100%
TasksMax=256
EOF
systemctl daemon-reload
systemctl start projectbookrag.slice
systemctl set-property projectbookrag.slice MemoryHigh=1152M MemoryMax=1280M MemorySwapMax=0 CPUQuota=100% TasksMax=256
test "$(cat /sys/fs/cgroup/projectbookrag.slice/memory.max)" = 1342177280
systemctl show projectbookrag.slice -p MemoryMax -p MemorySwapMax -p CPUQuotaPerSecUSec
