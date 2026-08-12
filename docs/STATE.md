# Project State

- Current completed stage: Stage 2
- Important files: `README.md`, `lab.sh`, `docs/labs/stage-0.md`, `docs/labs/stage-1.md`, `docs/labs/stage-2.md`
- Active design decisions:
  - Build the lab cumulatively, one requested stage at a time.
  - Use four fixed namespace names and three veth pairs with short temporary host names.
  - Enable IPv4 forwarding only in `lab-router` and `lab-fw`.
  - Use the specified default and remote-subnet routes; do not add NAT or filtering.
  - Rebuild the cumulative topology from clean project-owned resources.
  - Use Bash and standard Linux networking tools only.
- Known problems: none
- Next stage: Stage 3 — stateful ACL and HTTP on TCP/8080
