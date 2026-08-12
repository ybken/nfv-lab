# Project State

- Current completed stage: Stage 3
- Important files: `README.md`, `lab.sh`, `docs/labs/stage-0.md`, `docs/labs/stage-1.md`, `docs/labs/stage-2.md`, `docs/labs/stage-3.md`
- Active design decisions:
  - Build the lab cumulatively, one requested stage at a time.
  - Use four fixed namespace names and three veth pairs with short temporary host names.
  - Enable IPv4 forwarding only in `lab-router` and `lab-fw`.
  - Filter only in `lab-fw`; keep namespace INPUT and OUTPUT policies open.
  - Allow ICMP and client TCP/8080; use conntrack for return traffic.
  - Demonstrate both explicit TCP REJECT and silent DROP without NAT.
  - Rebuild the cumulative topology from clean project-owned resources.
  - Use Bash and standard Linux networking tools only.
- Known problems: none
- Next stage: Stage 4 — separately testable SNAT and DNAT modes on `lab-router`
