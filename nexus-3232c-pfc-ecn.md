# PFC + ECN for RoCEv2 — Cisco Nexus 3232C

> ✅ **STATUS: APPLIED AND VERIFIED IN PRODUCTION (2026-08-08).** PFC is live on a
> 3-node DGX Spark fabric. Verified after applying: `active_mtu` still 4096, dual-rail
> throughput **98.01 + 98.01 = 196.0 Gb/s**, and **zero pause-frame storms** under load.
>
> ⚠️ **ECN/WRED and the input classification policy are NOT applied** — both need QoS TCAM
> regions carved, which requires a **switch reload**. See [TCAM](#-tcam-the-part-that-needs-a-reload).
>
> **Why PFC mattered here:** before applying it the switch had logged **322,434 output
> discards** on one port, all in queue 0, averaging **4,049 bytes** — i.e. full-size RoCE
> data frames (`active_mtu` 4096) being dropped from a full egress buffer, with the PFC
> counter `TxPPP` at **0** because no pause frame had ever been sent. Without PFC a full
> buffer has exactly one option: drop. RoCE degrades badly on loss.

## What this does

Makes the RoCE fabric **lossless** so RDMA traffic is never dropped due to buffer
exhaustion, and adds ECN so senders slow down *before* buffers fill.

| Mechanism | Role | Analogy |
|---|---|---|
| **ECN** (Explicit Congestion Notification) | Marks packets when a queue builds; sender throttles smoothly via DCQCN | Shock absorber |
| **PFC** (Priority Flow Control, 802.1Qbb) | PAUSEs one traffic class when a buffer nears full; guarantees zero drops | Emergency brake |

**ECN should do nearly all the work.** PFC is the last-resort guarantee. A design where PFC
fires constantly is a badly-tuned design — excessive pausing causes head-of-line blocking
and, in bad topologies, congestion spreading.

## The design

- **RoCE data → priority 3 / CoS 3** (the de-facto industry standard for RoCEv2, matching
  what NVIDIA/Mellanox hosts default to)
- **CNP (Congestion Notification Packets) → priority 6**, strict priority, *no* PFC.
  CNPs are the feedback signal — they must never be paused or they can't do their job.
- **ECN thresholds (WRED): min 150 KB, max 1500 KB, drop-probability 7%.** Conservative
  starting values for a 100G fabric; tune against real counters.
- PFC no-drop applies **only** to priority 3. Management/SSH traffic is unaffected.

⚠️ **Host and switch must agree on the priority number.** If hosts mark RoCE as priority 3,
the switch must treat 3 as no-drop. A mismatch means PFC protects a class carrying nothing
while the actual RoCE traffic stays droppable — and it will look configured.

---

## Switch config

```
! ─────────────────────────────────────────────────────────────
! 1. CLASSIFICATION — match RoCE (CoS 3) and CNP (CoS 6)
! ─────────────────────────────────────────────────────────────
class-map type qos match-all c-roce
  match cos 3
class-map type qos match-all c-cnp
  match cos 6

policy-map type qos roce-classify
  class c-roce
    set qos-group 3
  class c-cnp
    set qos-group 6

! ─────────────────────────────────────────────────────────────
! 2. NETWORK-QOS — no-drop + jumbo on the RoCE class
!    NOTE: this REPLACES the existing jumbo-nq policy.
!    MTU 9216 is preserved on every class below.
! ─────────────────────────────────────────────────────────────
class-map type network-qos c-nq-roce
  match qos-group 3
class-map type network-qos c-nq-cnp
  match qos-group 6

policy-map type network-qos roce-nq
  class type network-qos c-nq-roce
    pause pfc-cos 3            ! <- PFC enabled for priority 3
    mtu 9216
  class type network-qos c-nq-cnp
    mtu 9216
  class type network-qos class-default
    mtu 9216                   ! <- preserves existing jumbo behaviour

! ─────────────────────────────────────────────────────────────
! 3. QUEUING — bandwidth split + ECN/WRED marking on RoCE
! ─────────────────────────────────────────────────────────────
policy-map type queuing roce-out
  class type queuing c-out-q3
    bandwidth remaining percent 80
    random-detect minimum-threshold 150 kbytes \
                  maximum-threshold 1500 kbytes \
                  drop-probability 7 weight 0 ecn
  class type queuing c-out-q6
    priority level 1           ! CNPs strict-priority, never paused
  class type queuing c-out-q-default
    bandwidth remaining percent 20

! ─────────────────────────────────────────────────────────────
! 4. APPLY system-wide
! ─────────────────────────────────────────────────────────────
system qos
  service-policy type network-qos roce-nq
  service-policy type queuing output roce-out

! ─────────────────────────────────────────────────────────────
! 5. PER-INTERFACE — PFC + trust + classification
! ─────────────────────────────────────────────────────────────
interface Ethernet1/1-4
  priority-flow-control mode on
  service-policy type qos input roce-classify
  mtu 9216
```

⚠️ **`system qos` accepts ONE network-qos policy.** Applying `roce-nq` *replaces*
`jumbo-nq`. That's why `class-default` above carries `mtu 9216` — omit it and every
non-RoCE class silently drops to 1500, breaking jumbo for everything else.

---

## Host side (DGX Spark)

The switch config alone does nothing if hosts don't mark their traffic.

```bash
# Map RoCE traffic to priority 3 (both production rails)
sudo mlnx_qos -i enp1s0f0np0 --trust dscp
sudo mlnx_qos -i enP2p1s0f1np1 --trust dscp

# DSCP 26 -> priority 3 (26>>3 = 3), the RoCE convention
sudo cma_roce_tos -d rocep1s0f0 -t 104      # DSCP 26 << 2 = 104
sudo cma_roce_tos -d roceP2p1s0f1 -t 104

# Enable PFC on priority 3 only
sudo mlnx_qos -i enp1s0f0np0 --pfc 0,0,0,1,0,0,0,0
sudo mlnx_qos -i enP2p1s0f1np1 --pfc 0,0,0,1,0,0,0,0

# Enable ECN for DCQCN (per RoCE device, all 8 priorities shown; enable p3)
echo 1 | sudo tee /sys/class/net/enp1s0f0np0/ecn/roce_np/enable/3
echo 1 | sudo tee /sys/class/net/enp1s0f0np0/ecn/roce_rp/enable/3
```

`roce_np` = notification point (receiver, sends CNPs). `roce_rp` = reaction point (sender,
slows down). **Both ends need it** or the loop is open.

⚠️ These are **not persistent**. Wrap in a systemd unit or they vanish on reboot.

---

## Verification

Config that looks applied and isn't is the normal failure mode here. Check the wire.

```bash
# --- SWITCH ---
show policy-map system type network-qos          ! is roce-nq active?
show interface ethernet1/1 priority-flow-control ! PFC on? counters moving?
show interface ethernet1/1 | include MTU         ! still 9216? (jumbo regression check)
show queuing interface ethernet1/1               ! WRED/ECN thresholds present?
show interface ethernet1/1 counters errors       ! discards should stay 0
```

```bash
# --- HOST ---
mlnx_qos -i enp1s0f0np0                          # trust mode + pfc mask
ibv_devinfo | grep active_mtu                    # must STILL be 4096
ethtool -S enp1s0f0np0 | grep -iE "pause|prio3"  # pause frames + priority counters
```

**Success criteria after applying:**

| Check | Expected |
|---|---|
| `active_mtu` | **still 4096** — if it dropped to 1024, the network-qos policy broke jumbo |
| `ib_write_bw` both rails | **still ~196 Gb/s** — PFC should not cost throughput on an uncongested fabric |
| Pause frames, idle | **0** — constant pausing means thresholds are too aggressive |
| `output discard` | **0** |

⚠️ **If throughput drops after enabling PFC, you have a misconfiguration, not a tuning
problem.** The most common cause is a host/switch priority mismatch.

---

## ⛔ TCAM: the part that needs a reload

On the N3K the **input classification** policy and the **ECN/WRED queuing** policy both fail
with:

```
Module 1 returned status "TCAM region is not configured. Please configure TCAM region and retry"
```

Check with `show hardware access-list tcam region` — if the QoS regions read `size = 0`, carve
them and **reload** (a reload is required for TCAM changes to take effect):

```
hardware access-list tcam region qos 256
copy running-config startup-config
reload
```

★ **PFC itself works without this.** If your hosts run `Priority trust state: pcp` (the
Mellanox/NVIDIA default when configured for RoCE) they mark CoS 3 themselves, so the switch's
PFC acts on that marking directly and the input classification policy is largely redundant.
Verify with `mlnx_qos -i <iface>`.

⇒ Without ECN you have the **emergency brake (PFC)** but not the **shock absorber (ECN)**.
Fine for a small non-oversubscribed fabric; add ECN before you scale to 8+ nodes where
many-to-one incast becomes real.

## Original rationale for staging it (kept for the reasoning trail)

The fabric it would protect currently carries a two-node tensor-parallel vLLM cluster. A
fabric interruption stalls all local inference, and NCCL blocks rather than failing cleanly.
Applying it means replacing the live `system qos` policy — the same stanza the working jumbo
config depends on.

The engineering justification for waiting is empirical: this fabric has **zero congestion**.
4 of 32 ports populated, no oversubscription, 1:1 traffic, and `0 input discard` /
`0 output discard` / zero pause frames / zero CRC errors across all four ports. PFC prevents
drops from buffer exhaustion; there are no drops and no buffer exhaustion. It is insurance,
not a fix.

**Apply it when any of these becomes true:**

- Node count reaches ~4+ (NCCL all-reduce incast becomes real)
- Any non-zero `output discard` or pause counter appears
- Storage traffic (NVMe-oF) shares the fabric
- Any oversubscription is introduced

**Apply during a maintenance window with inference stopped**, and verify `active_mtu` is
still 4096 immediately afterward.

## Rollback

```
system qos
  service-policy type network-qos jumbo-nq

interface Ethernet1/1-4
  no priority-flow-control mode on
  no service-policy type qos input roce-classify
```

Then re-verify `active_mtu` = 4096 and re-run the dual-rail throughput test.
