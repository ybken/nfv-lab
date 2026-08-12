# Project State

- Current completed stage: Stage 4
- Important files: `README.md`, `lab.sh`, `docs/labs/stage-0.md`, `docs/labs/stage-1.md`, `docs/labs/stage-2.md`, `docs/labs/stage-3.md`, `docs/labs/stage-4.md`
- Active design decisions:
  - Build the lab cumulatively, one requested stage at a time.
  - Use four fixed namespace names and three veth pairs with short temporary host names.
  - Enable IPv4 forwarding only in `lab-router` and `lab-fw`.
  - Filter only in `lab-fw`; keep namespace INPUT and OUTPUT policies open.
  - Allow ICMP and client TCP/8080; use conntrack for return traffic.
  - Keep SNAT, DNAT, and off as mutually exclusive router NAT modes.
  - Start Stage 4 with NAT off and flush router conntrack on mode changes.
  - Allow the SNAT address through the firewall only for TCP/8080.
  - Rebuild the cumulative topology from clean project-owned resources.
  - Use Bash and standard Linux networking tools only.
- Known problems: none
- Next stage: Stage 5 — removable TBF bandwidth limiting and netem latency/loss
