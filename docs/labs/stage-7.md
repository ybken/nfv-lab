# Stage 7 — Final Integration

## Objective

Complete the cumulative lab with iperf3 testing, full regression checks, reliable process cleanup, and final learning documentation.

## Topology change

The topology and addressing remain unchanged. Stage 7 allows client-to-server TCP/5201 through `lab-fw` and starts an iperf3 server in `lab-server`. NAT, QoS, and capture start off.

## Important commands

```bash
sudo ./lab.sh up 7
sudo ./lab.sh status
sudo ./lab.sh test 7
sudo ./lab.sh down
```

`up 7` rebuilds project-owned resources, so it is safe to repeat. `down` stops HTTP, iperf3, and tcpdump processes before deleting namespaces.

## Verification

```bash
bash -n ./lab.sh
shellcheck ./lab.sh
sudo ./lab.sh up 7
sudo ./lab.sh test 7
sudo ./lab.sh down
```

The full test covers routes, forwarding, ICMP, HTTP, stateful ACL behavior, iperf3, SNAT, DNAT, QoS, and six-point capture.

## Expected result

Every test passes. NAT and QoS end off, capture ends stopped, and `down` removes all namespaces and project processes.

## What to observe

- Functional tests and packet/state counters explain the same data path from different layers.
- iperf3 provides application-level throughput while `tc` controls link behavior.
- Repeated setup produces the same topology instead of accumulating rules or interfaces.
- Cleanup removes transient kernel resources while retaining pcap files for later analysis.

## Common failure causes

- A required command or kernel module is unavailable.
- An earlier manual rule conflicts with project-owned namespace state.
- HTTP or iperf3 failed to start; inspect `run/http.log` or `run/iperf3.log`.
- A test was run for a stage that was not brought up.

