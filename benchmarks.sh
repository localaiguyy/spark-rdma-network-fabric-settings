#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# DGX Spark RoCE fabric — throughput + latency benchmarks
#
# Requires 'perftest' on both nodes:  sudo apt install perftest
#
# Reference results (2× DGX Spark via Cisco Nexus 3232C):
#   Single rail        98.00 Gb/s
#   Dual rail  30 s   196.0  Gb/s   (98.01 + 98.01)
#   Dual rail 450 s   194.2  Gb/s   (97.19 + 97.05)
#   ib_send_lat       2.35 µs typical, 4.21 µs @99.9%
#   ib_write_lat      2.41 µs typical, 4.99 µs @99.9%
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

PEER_A="${PEER_A:-192.0.2.21}"    # peer rail A (PCIe domain 0000:)
PEER_B="${PEER_B:-192.0.2.24}"    # peer rail B (PCIe domain 0002:)
DEV_A="${DEV_A:-rocep1s0f0}"       # local rail A device
DEV_B="${DEV_B:-roceP2p1s0f1}"     # local rail B device
DUR="${DUR:-20}"                   # client seconds

# ⚠️ -x 3 selects GID index 3 = RoCEv2 over IPv4. Without it you may bind
#    RoCEv1 or an IPv6 GID and get wrong/failing results.
GID=3

cat <<'NOTES'
─────────────────────────────────────────────────────────────────────────────
BEFORE YOU TRUST ANY NUMBER

1. Start a FRESH server for every run, with flags MATCHING the client.
   A leftover server from a previous test with different parameters will
   still accept the connection and produce a PLAUSIBLE BUT WRONG number.

2. NEVER use `pkill -f ib_write_bw` over SSH. The pattern matches the SSH
   command string carrying it, so it kills its own session — presenting as
   intermittent `exit 255` that looks exactly like network flakiness.
   Use `systemd-run --unit=` + `systemctl stop <unit>`.

3. Background servers die with the SSH session. `nohup &`, `setsid &` and
   `& disown` all fail here. `systemd-run --unit=<name> --collect` works.

4. Test BOTH DIRECTIONS. The ConnectX-7 firmware power-throttle is
   per-SENDING-endpoint — a one-direction test after a fix reads as
   "nothing changed" while the reverse direction is fine.
─────────────────────────────────────────────────────────────────────────────
NOTES

# ══ SERVER SIDE (run on the peer) ══════════════════════════════════════════
cat <<EOF

═══ STEP 1 — on the PEER node, start the servers ═══

# Single-rail test:
sudo systemd-run --unit=rdma-a --collect /usr/bin/ib_write_bw \\
  -d ${DEV_A} -x ${GID} -F --report_gbits -Q 64 -D $((DUR + 10)) -p 18515

# Dual-rail test — one server per rail, DIFFERENT tcp ports.
# (default 18515 collides and the second server silently fails)
sudo systemd-run --unit=agg-a --collect /usr/bin/ib_write_bw \\
  -d ${DEV_A} -x ${GID} -F --report_gbits -Q 64 -D $((DUR + 10)) -p 18515
sudo systemd-run --unit=agg-b --collect /usr/bin/ib_write_bw \\
  -d ${DEV_B} -x ${GID} -F --report_gbits -Q 64 -D $((DUR + 10)) -p 18518

# Confirm they are actually LISTENING before starting the client:
systemctl is-active agg-a agg-b
ss -ltn | grep -E '18515|18518'

# Latency servers:
sudo systemd-run --unit=lat-s --collect /usr/bin/ib_send_lat \\
  -d ${DEV_A} -x ${GID} -F -p 18620
sudo systemd-run --unit=lat-w --collect /usr/bin/ib_write_lat \\
  -d ${DEV_A} -x ${GID} -F -p 18630

EOF

# ══ CLIENT SIDE ════════════════════════════════════════════════════════════
echo "═══ STEP 2 — client tests (this node) ═══"
echo
echo "--- Single rail A (expect ~98 Gb/s) ---"
echo "ib_write_bw -d ${DEV_A} -x ${GID} -F --report_gbits -Q 64 -D ${DUR} ${PEER_A}"
echo
echo "--- DUAL RAIL (expect ~196 Gb/s combined) ---"
cat <<EOF
( ib_write_bw -d ${DEV_A} -x ${GID} -F --report_gbits -Q 64 -D ${DUR} -p 18515 ${PEER_A} ) &
( ib_write_bw -d ${DEV_B} -x ${GID} -F --report_gbits -Q 64 -D ${DUR} -p 18518 ${PEER_B} ) &
wait
# ADD THE TWO RESULTS TOGETHER. ~97-98 each = ~196 total.
EOF
echo
echo "--- Latency (expect ~2.35 µs typical) ---"
echo "ib_send_lat  -d ${DEV_A} -x ${GID} -F -p 18620 ${PEER_A}"
echo "ib_write_lat -d ${DEV_A} -x ${GID} -F -p 18630 ${PEER_A}"
echo

# ══ THE DIAGNOSTIC MATRIX ══════════════════════════════════════════════════
cat <<'EOF'
═══ IF YOU DON'T GET ~196 — read the number, it tells you which limit ═══

  ~98 Gb/s   Both rails are on the SAME CABLE.
             Check: ethtool -m <if> | grep "Vendor SN"  (matching = same wire)

  ~109 Gb/s  Both rails are on the SAME PCIe DOMAIN.
             You are hitting the PCIe Gen5 x4 ceiling (~112 Gb/s).
             Use one interface from 0000: and one from 0002:

  ~13 Gb/s   ConnectX-7 firmware PCIe power-throttle.
             Fix: REBOOT with cables in their final position.
             The "insufficient power (27W)" dmesg message is COSMETIC and
             PERSISTS after the fix — measure throughput, not logs.
             Test BOTH directions; the throttle is per-sending-endpoint.

  ~50 Gb/s   Check active_mtu — if it reads 1024 instead of 4096, jumbo is
             not really configured (on NX-OS the network-qos policy alone
             leaves interfaces at 1500 while LOOKING configured).
EOF

# ══ MONITORING ═════════════════════════════════════════════════════════════
cat <<'EOF'

═══ ⚠️ KERNEL COUNTERS ARE BLIND TO RDMA ═══

During a sustained 194 Gb/s transfer, measured:
  kernel if_octets (what ifconfig/Observium/LibreNMS graph):  0.01 Gb/s
  ConnectX-7 hardware counters:                              ~9.7 TB moved

Your bandwidth graph draws a FLAT LINE AT ZERO through a saturated fabric.
It is not "low" — it is blind. RDMA bypasses the kernel network stack.

Read the hardware counters instead:
EOF
cat <<EOF
  cat /sys/class/infiniband/${DEV_A}/ports/1/counters/port_xmit_data
  cat /sys/class/infiniband/${DEV_A}/ports/1/counters/port_rcv_data

⚠️ Values are in 4-BYTE WORDS, not bytes (InfiniBand spec). MULTIPLY BY 4.
   Verified: a run reported at 98.01 Gb/s measured 99.45 Gb/s with x4
   applied (the ~1.5% excess is RoCE header overhead the hardware counts
   and the payload benchmark does not). Read as raw bytes you get a
   nonsensical 24.86 Gb/s. Do not "simplify" the x4 away.
EOF
