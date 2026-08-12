# Project State

- Current completed stage: Stage 1
- Important files: `README.md`, `lab.sh`, `docs/labs/stage-0.md`, `docs/labs/stage-1.md`
- Active design decisions:
  - Build the lab cumulatively, one requested stage at a time.
  - Use four fixed namespace names and three veth pairs with short temporary host names.
  - Keep IPv4 forwarding disabled in every namespace through Stage 1.
  - Rebuild Stage 1 from a clean project-owned topology for repeatable setup.
  - Use Bash and standard Linux networking tools only.
- Known problems: none
- Next stage: Stage 2 — static routes and IPv4 forwarding in router and firewall namespaces
