# Linux Virtual Network / NFV Lab

## Goal

Build an incremental Linux virtual networking lab for learning, not just a final working script.

Final topology:

client -- router -- firewall -- server

Namespaces:
- lab-client
- lab-router
- lab-fw
- lab-server

Addressing:
- client eth0: 10.10.1.2/24
- router eth0: 10.10.1.1/24
- router eth1: 10.10.2.1/24
- firewall eth0: 10.10.2.2/24
- firewall eth1: 10.10.3.1/24
- server eth0: 10.10.3.2/24

Routes:
- client default via 10.10.1.1
- router: 10.10.3.0/24 via 10.10.2.2
- firewall: 10.10.1.0/24 via 10.10.2.1
- server default via 10.10.3.1

Enable IPv4 forwarding only inside router and firewall namespaces.

## Final capabilities

The completed lab must demonstrate:
1. network namespaces and veth
2. Ethernet/ARP behavior
3. L3 routing and IP forwarding
4. Netfilter/iptables ACL
5. conntrack/stateful firewall
6. SNAT
7. DNAT/port forwarding
8. bandwidth limiting
9. delay/loss simulation
10. tcpdump packet capture
11. connectivity/HTTP/iperf tests
12. idempotent setup and cleanup automation

Treat this as a simplified NFV service-function-chain lab.

## Stages

Implement only the stage explicitly requested. Never implement later stages early.

Stage 0:
repository skeleton, environment checks, docs only.

Stage 1:
four namespaces, three veth pairs, loopback/interfaces/IP addresses.
Only adjacent-node connectivity is required.
Demonstrate ARP and L2 adjacency.
No forwarding.

Stage 2:
static routes and IPv4 forwarding.
Client must reach server through router and firewall.
No firewall filtering or NAT.

Stage 3:
stateful ACL on lab-fw using iptables/Netfilter.
Keep ICMP testable.
Allow an HTTP service on server TCP/8080.
Demonstrate NEW and ESTABLISHED/RELATED behavior and DROP/REJECT.

Stage 4:
NAT on lab-router.
Support separately testable SNAT and DNAT/port-forwarding modes.
Do not enable mutually confusing NAT modes by default.
Make NAT observable with tcpdump and conntrack behavior.

Stage 5:
Traffic Control.
Demonstrate bandwidth limiting plus configurable latency/loss.
Prefer a simple, educational implementation using TBF and netem.
Make impairment removable without rebuilding the topology.

Stage 6:
packet-capture workflow.
Provide concise tcpdump commands/helpers to capture at client, router, firewall and server and compare packet headers across hops.

Stage 7:
final automation, tests, cleanup, documentation and robustness.

## Engineering constraints

Use Bash and standard Linux networking tools. Do not introduce Docker, Kubernetes, OVS, Mininet, Ansible or unnecessary dependencies.

Prefer:
- iproute2
- ip netns
- ip link
- ip addr
- ip route
- sysctl
- iptables
- tc
- tcpdump
- ping
- curl
- iperf3
- python3 only for a tiny HTTP test server if useful

All scripts:
- use `set -Eeuo pipefail`
- must be readable and educational
- must be safe to run repeatedly where practical
- must not modify host firewall/routing/sysctl state
- firewall/NAT rules must execute inside their namespaces
- cleanup must remove every namespace/process/resource created by this project
- namespace/interface names must respect Linux interface-name limits

Never run sudo yourself. Write privileged commands/scripts, then tell the user exactly what to run.

Run non-privileged static validation yourself where possible:
- bash -n
- shellcheck when available
- git diff

Do not install packages automatically.

## CLI target

Gradually converge on:

sudo ./lab.sh up <stage>
sudo ./lab.sh test <stage>
sudo ./lab.sh status
sudo ./lab.sh down

Later add concise subcommands for NAT, QoS and capture if needed.

`up N` should construct the cumulative topology required through stage N.

## Learning documentation

Maintain:

docs/STATE.md
docs/labs/

STATE.md must remain under about 40 lines and contain only:
- current completed stage
- important files
- active design decisions
- known problems
- next stage

For each implemented stage create one concise lab document containing:
- objective
- topology change
- important commands
- verification
- expected result
- what to observe
- common failure causes

Do not write long textbook explanations.

## Token/output policy

Minimize conversational output.

Do not paste entire files after editing them.
Do not repeat project background already present here.
Do not explain basic Linux/networking theory unless explicitly asked.
Inspect existing files before creating duplicates.
Reuse existing helpers instead of rewriting them.

At the end of each task respond with at most:

Changed:
- ...

Run:
- ...

Verify:
- ...

Observe:
- ...

If something failed, additionally give only the concrete failure and next diagnostic step.

Stop after the requested stage.