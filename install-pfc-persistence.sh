#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Persist RoCE PFC across reboots.
#
# WHY THIS EXISTS: `mlnx_qos --pfc` sets RUNTIME state only. After a reboot
# (or a NIC reinit) the host silently drops back to PFC-off while the switch
# keeps running `pause pfc-cos 3`. The switch then pauses into a host that
# ignores pause — a half-lossless fabric that looks configured and is not.
#
# PFC IS A TWO-SIDED PROTOCOL. Both ends must agree on the same priority.
# Priority 3 is the de-facto RoCE standard and matches `pause pfc-cos 3`.
#
# Run on EVERY host on the fabric:  sudo ./install-pfc-persistence.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

RAIL_A_IF="${RAIL_A_IF:-enp1s0f0np0}"
RAIL_B_IF="${RAIL_B_IF:-enP2p1s0f1np1}"
PFC_MASK="${PFC_MASK:-0,0,0,1,0,0,0,0}"     # priority 3
MLNX_QOS="$(command -v mlnx_qos || echo /usr/bin/mlnx_qos)"   # /usr/bin on DGX OS, NOT /usr/sbin

[ -x "$MLNX_QOS" ] || { echo "mlnx_qos not found — install the OFED/DOCA tools"; exit 1; }

cat <<UNIT | sudo tee /etc/systemd/system/roce-pfc.service >/dev/null
[Unit]
Description=RoCE PFC priority 3 on the RDMA rails (matches switch pause pfc-cos 3)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# NO "|| true" — a silent failure leaves the switch pausing into a host that
# ignores pause. One ExecStart per rail so systemd marks the unit FAILED.
ExecStart=${MLNX_QOS} -i ${RAIL_A_IF} --pfc ${PFC_MASK}
ExecStart=${MLNX_QOS} -i ${RAIL_B_IF} --pfc ${PFC_MASK}

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now roce-pfc.service

echo "=== verification (every rail must read: enabled 0 0 0 1 0 0 0 0) ==="
rc=0
for i in "$RAIL_A_IF" "$RAIL_B_IF"; do
  m=$(sudo "$MLNX_QOS" -i "$i" 2>/dev/null | grep "^	enabled" | tr -s ' ')
  case "$m" in
    *"0 0 0 1 0 0 0 0"*) printf "  OK   %-16s %s\n" "$i" "$m" ;;
    *)                   printf "  FAIL %-16s %s\n" "$i" "$m"; rc=1 ;;
  esac
done

# ⚠️ Re-check the RoCE MTU: if the switch's network-qos policy was replaced
#    without carrying `mtu 9216` on class-default, this silently drops to 1024.
echo "=== active_mtu (must be 4096, not 1024) ==="
ibv_devinfo 2>/dev/null | grep -E 'hca_id|active_mtu' || true

exit $rc
