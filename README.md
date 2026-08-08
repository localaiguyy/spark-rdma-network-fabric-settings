# spark-rdma-network-fabric-settings

Reference configurations for a **100 GbE RoCEv2 RDMA fabric** joining
**NVIDIA DGX Spark (GB10)** nodes to a **Cisco Nexus 3232C** — covering
**RDMA, PFC, ECN, jumbo MTU and multi-rail addressing on both sides**.

Everything here is running in production on a 3-node fabric sustaining
**196.0 Gb/s per node** (98.01 Gb/s × 2 rails) at **~2.1–2.4 µs** RDMA latency.

## Contents

| File | Side | What it covers |
|---|---|---|
| [`nexus-3232c-running.cfg`](nexus-3232c-running.cfg) | Switch | VLAN, jumbo MTU, LLDP, host ports — the working baseline |
| [`nexus-3232c-pfc-ecn.md`](nexus-3232c-pfc-ecn.md) | Switch | PFC (applied), ECN/WRED (needs a TCAM carve + reload) |
| [`spark-host-setup.sh`](spark-host-setup.sh) | Host | `nmcli` rails, MTU, ARP guards, host-side PFC |
| [`install-pfc-persistence.sh`](install-pfc-persistence.sh) | Host | ⛔ **Run this** — makes host PFC survive a reboot |
| [`benchmarks.sh`](benchmarks.sh) | Both | Throughput/latency tests + a diagnostic matrix |

## ★★★ The three things that actually matter

### 1. Jumbo needs TWO configs on NX-OS, not one

A system-wide `network-qos` policy **and** a per-interface `mtu`. With only the policy,
`show policy-map system type network-qos` reports 9216 while `show interface` still reads
**MTU 1500**. It looks configured and is not. **Verify on the wire**, not in the config.

Numbers are deliberately mismatched: **switch 9216** (full frame incl. headers) vs
**hosts 9000** (payload) — the host must be *lower* or the switch drops frames as oversize.
RoCE then negotiates `active_mtu` **4096**, which is the number that affects throughput.

### 2. PFC is a TWO-SIDED protocol — and it does NOT survive a reboot

Enabling it only on the switch does nothing useful — the host must agree on the same
priority (3 is the de-facto RoCE standard):

```bash
sudo mlnx_qos -i <iface> | grep -A1 enabled
#  enabled  0 0 0 0 0 0 0 0   <- OFF, fabric is LOSSY
#  enabled  0 0 0 1 0 0 0 0   <- priority 3 lossless
```

**Why it matters:** without PFC a full egress buffer has exactly one option — drop. On one
port we measured **322,434 output discards**, all queue 0, averaging **4,049 bytes** — full
size RoCE data frames (`active_mtu` 4096) being discarded, with `TxPPP 0` proving no pause
frame had ever been sent. RoCE degrades badly on loss.

⛔⛔ **`mlnx_qos` sets RUNTIME state only — it is lost on reboot, silently.** We hit this in
production: two of three hosts reverted to PFC-off while the switch kept running
`pause pfc-cos 3`. The switch then pauses into hosts that ignore pause — a half-lossless
fabric that looks configured and is not. **Run
[`install-pfc-persistence.sh`](install-pfc-persistence.sh) on every host.**

★★ **Verify every rail on every host, not one representative box.** This is per-device state;
a spot check on one machine proves nothing about the others — that is exactly how we shipped a
half-configured fabric and believed it was done:

```bash
for h in node1 node2 node3; do ssh $h 'for i in enp1s0f0np0 enP2p1s0f1np1; do
  sudo mlnx_qos -i $i | grep "^\tenabled"; done'; done
# every rail must read:  enabled  0 0 0 1 0 0 0 0
```

### 3. On a DGX Spark: different CABLE *and* different PCIe DOMAIN

The GB10 presents **one** ConnectX-7 through **two** PCIe domains, so 2 physical ports show
up as **4 network interfaces**. Both rails must differ in *both* dimensions:

| Configuration | Result |
|---|---|
| Same cable, two PCIe domains | ~98 Gb/s (cable-limited) |
| Two cables, same PCIe domain | ~109 Gb/s (**PCIe Gen5 x4 limited**) |
| **Different cable + different domain** | **~196 Gb/s** ✅ |

Identify which interfaces share a wire — **matching serial = same cable**:

```bash
sudo ethtool -m <iface> | grep "Vendor SN"
```

⚠️ A DGX Spark cannot exceed ~200 Gb/s total: its NIC advertises `200000baseCR4` but every
PCIe function reports `LnkSta: Speed 32GT/s, Width x4` (~112 Gb/s practical per domain).
**200G/400G switch ports are capacity you cannot use — buy 100G port count, not port speed.**

## Quick start

```bash
# 1. Switch: paste nexus-3232c-running.cfg (edit VLAN + interface range).
#    Apply the SAME config to EVERY 100G switch in the fabric — a mixed
#    fabric where one switch runs PFC and another does not is worse than
#    neither. Reload once if you carved TCAM.
# 2. Hosts: edit the IPs at the top, then run on each node
sudo ./spark-host-setup.sh
# 3. Make PFC survive reboots — on EVERY host
sudo ./install-pfc-persistence.sh
# 4. Verify
./benchmarks.sh
```

## Verify on the wire — never trust the config

```bash
ping -c3 -M do -s 8972 -I <iface> <peer>   # jumbo must PASS
ping -c3 -M do -s 9100 -I <iface> <peer>   # must FAIL (proves the limit is real)
ibv_devinfo | grep active_mtu              # want 4096, NOT 1024
```

⚠️ **Your bandwidth graphs are blind to RDMA.** It bypasses the kernel network stack, so
`ifconfig`-style counters read ~0 through a saturated fabric. Read the hardware counters at
`/sys/class/infiniband/<dev>/ports/1/counters/port_xmit_data` and **multiply by 4** (the
values are in 4-byte words per the InfiniBand spec).

⚠️ **Judge discard counters by rate of change, not absolute value** — they are cumulative
until cleared. And *"idle"* is an assumption until a counter proves it: benchmarking a busy
fabric produces low numbers that are easy to misattribute to hardware.

## License

MIT — see [LICENSE](LICENSE).
