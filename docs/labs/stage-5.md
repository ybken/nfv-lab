# Stage 5 — Bandwidth, Delay, and Loss

## Objective

Apply removable bandwidth limiting, latency, and packet loss without rebuilding the topology.

## Topology change

Stage 4 remains active with NAT off. Stage 5 applies two qdiscs to `lab-fw eth0`, the egress path toward the client:

```text
TBF rate limiter (root) -> netem delay/loss (child)
```

`up 5` starts with QoS off. A runtime 2 MiB HTTP payload supports repeatable rate checks.

## Important commands

```bash
sudo ./lab.sh up 5
sudo ./lab.sh qos set 4mbit 50ms 1%
sudo ip netns exec lab-fw tc -s qdisc show dev eth0
sudo ./lab.sh qos off
```

Rate accepts positive `kbit`, `mbit`, or `gbit` values. Delay accepts `us`, `ms`, or `s`. Loss accepts `0%` through `100%`.

## Verification

```bash
sudo ./lab.sh test 5
```

The test applies `4mbit 50ms 1%`, validates both qdiscs, measures a 2 MiB HTTP transfer, runs ping, prints counters, and removes QoS.

## Expected result

The download stays near the configured ceiling, ping shows added return-path delay, and `test 5` ends without TBF or netem on `lab-fw eth0`.

## What to observe

- TBF controls the average egress rate and burst allowance.
- netem adds delay and probabilistic loss after TBF.
- Only traffic leaving firewall `eth0` is impaired; the reverse direction is unchanged.
- `tc -s` counters show sent, dropped, and overlimit packets.

## Common failure causes

- The rate, delay, or loss unit is invalid.
- Kernel `sch_tbf` or `sch_netem` support is unavailable.
- A very high loss value causes HTTP or ping timeouts.
- QoS was applied to a different interface or namespace.

