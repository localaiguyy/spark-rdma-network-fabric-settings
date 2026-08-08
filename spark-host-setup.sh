#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# DGX Spark (GB10) — 100G RoCE fabric host setup
#
# Configures TWO rails per host: one per PCIe domain, each to a DIFFERENT
# physical cable. That pairing is what yields 196 Gb/s instead of ~109.
#
# Run on each Spark. Adjust IPs per host.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Per-host addressing ────────────────────────────────────────────────────
# node1: 192.0.2.11 / 192.0.2.14
# node2: 192.0.2.21 / 192.0.2.24
RAIL_A_IP="${RAIL_A_IP:-192.0.2.11}"
RAIL_B_IP="${RAIL_B_IP:-192.0.2.14}"

# ── The two interfaces that matter ─────────────────────────────────────────
# DIFFERENT PCIe domain (0000: vs 0002:) AND different physical port (p0/p1).
# The GB10 shows 4 interfaces for 2 ports; the other two are redundant
# doorways to cables already in use here.
RAIL_A_IF="enp1s0f0np0"      # PCIe domain 0000:, port p0
RAIL_B_IF="enP2p1s0f1np1"    # PCIe domain 0002:, port p1

echo "=== Verifying the pairing BEFORE configuring ==="
# Matching Vendor SN = same physical cable = will NOT scale.
SN_A=$(sudo ethtool -m "$RAIL_A_IF" 2>/dev/null | awk -F: '/Vendor SN/{print $2}' | xargs)
SN_B=$(sudo ethtool -m "$RAIL_B_IF" 2>/dev/null | awk -F: '/Vendor SN/{print $2}' | xargs)
echo "  $RAIL_A_IF -> cable $SN_A"
echo "  $RAIL_B_IF -> cable $SN_B"
if [[ "$SN_A" == "$SN_B" ]]; then
  echo "!! ERROR: both interfaces are on the SAME cable ($SN_A)."
  echo "!! This tops out at ~98 Gb/s. Pick interfaces on different wires."
  exit 1
fi
echo "  OK: different cables."

# ── Persistent addressing via NetworkManager ───────────────────────────────
# ⚠️ 'ip addr add' does NOT survive here — NetworkManager reclaims the
# interface and silently strips the address, minutes later. Use nmcli.
#
# ⚠️ These interfaces MUST be statically addressed. Left on DHCP against a
# fabric VLAN with no DHCP server, NM retries forever, never reaches
# 'activated', and can leave the host booting with NO network at all.

echo "=== Creating persistent NM profiles ==="
sudo nmcli con add type ethernet con-name "rdma-${RAIL_A_IF}" ifname "$RAIL_A_IF" \
  ip4 "${RAIL_A_IP}/24" ipv4.method manual ipv6.method disabled \
  802-3-ethernet.mtu 9000 connection.autoconnect yes

sudo nmcli con add type ethernet con-name "rdma-P2-f1" ifname "$RAIL_B_IF" \
  ip4 "${RAIL_B_IP}/24" ipv4.method manual ipv6.method disabled \
  802-3-ethernet.mtu 9000 connection.autoconnect yes

sudo nmcli con up "rdma-${RAIL_A_IF}"
sudo nmcli con up "rdma-P2-f1"

# ── ARP flux guard (REQUIRED: two NICs in one subnet) ──────────────────────
# Without this Linux answers ARP for either address out of either NIC.
# Affects the TCP/IP side only — RDMA steers by device and is unaffected.
echo "=== ARP guards ==="
sudo sysctl -w net.ipv4.conf.all.arp_ignore=1
sudo sysctl -w net.ipv4.conf.all.arp_announce=2
# Persist
echo -e "net.ipv4.conf.all.arp_ignore = 1\nnet.ipv4.conf.all.arp_announce = 2" \
  | sudo tee /etc/sysctl.d/99-rdma-arp.conf >/dev/null

# ── Verify ON THE WIRE ─────────────────────────────────────────────────────
echo
echo "=== Verification ==="
echo "--- Link speed (want 100000Mb/s) ---"
sudo ethtool "$RAIL_A_IF" | grep -E "Speed|Duplex"

echo "--- Jumbo end-to-end (8972 + 28 hdr = 9000) ---"
echo "    run against the PEER, e.g.:"
echo "    ping -c3 -M do -s 8972 -I $RAIL_A_IF 192.0.2.21"

echo "--- RoCE MTU (want 4096, NOT 1024) ---"
ibv_devinfo 2>/dev/null | grep -E "hca_id|active_mtu"

echo "--- PCIe link (expect 32GT/s x4 — this is the ~112 Gb/s ceiling) ---"
sudo lspci -s 0000:01:00.0 -vv 2>/dev/null | grep -E "LnkSta:" | sed 's/^\s*//'

echo
echo "Done. Now run benchmarks.sh to confirm ~196 Gb/s aggregate."

# ═══════════════════════════════════════════════════════════════════════════
# PFC (lossless RoCE) — HOST SIDE. Required if the switch runs PFC.
#
# ★★ PFC IS A TWO-SIDED PROTOCOL. Enabling it only on the switch is not
#    enough: the switch will emit pause frames that the host neither honours
#    nor generates. Verify BOTH ends.
#
#    Check first — if 'enabled' reads all zeros, host PFC is OFF:
#      sudo mlnx_qos -i <iface> | grep -A1 enabled
#      #  enabled   0 0 0 0 0 0 0 0     <- OFF (lossy)
#      #  enabled   0 0 0 1 0 0 0 0     <- priority 3 lossless (what you want)
#
# Priority 3 is the de-facto standard for RoCE and matches
# `pause pfc-cos 3` on the switch. The two MUST agree.
# ═══════════════════════════════════════════════════════════════════════════
for i in "$RAIL_A_IF" "$RAIL_B_IF"; do
  sudo mlnx_qos -i "$i" --pfc 0,0,0,1,0,0,0,0 >/dev/null 2>&1 \
    && echo "  ✓ $i PFC priority 3 enabled" \
    || echo "  ✗ $i PFC enable FAILED"
done

# Verify: 'enabled' must show a 1 in position 3, and that priority gets a buffer.
sudo mlnx_qos -i "$RAIL_A_IF" 2>/dev/null | grep -A2 "enabled"

# ⚠️ NOT persistent across reboot — wrap in a systemd unit for production.
# ⚠️ Re-check `ibv_devinfo | grep active_mtu` afterwards: it must still read
#    4096. If it dropped to 1024, the switch's network-qos policy replaced
#    your jumbo policy without carrying `mtu 9216` on class-default.
