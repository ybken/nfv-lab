# Stage 3 — Stateful Firewall and HTTP

## Objective

Apply a stateful ACL in `lab-fw`, keep ICMP testable, and allow client access to an HTTP service on server TCP/8080.

## Topology change

Stage 2 routing remains. The firewall `FORWARD` chain now:

1. accepts `ESTABLISHED,RELATED` traffic;
2. accepts ICMP;
3. accepts client-to-server TCP/8080 in `NEW` state;
4. rejects other client-to-server TCP with a TCP reset;
5. drops new server-to-client traffic and any remaining unmatched traffic.

A Python HTTP server runs inside `lab-server`; the lab documents are available under `/docs/`.

## Important commands

```bash
sudo ./lab.sh up 3
sudo ip netns exec lab-fw iptables -L FORWARD -v -n --line-numbers
sudo ip netns exec lab-client curl http://10.10.3.2:8080/docs/STATE.md
```

## Verification

```bash
sudo ./lab.sh test 3
```

The test verifies ICMP, allowed HTTP, rejected TCP/8081, dropped server-originated traffic, and prints firewall counters.

## Expected result

Ping and HTTP succeed. TCP/8081 is rejected, an unsolicited server-to-client connection times out, and the matching rule counters increase.

## What to observe

- The HTTP request matches the `NEW` rule.
- Response packets match `ESTABLISHED,RELATED`; no reverse-port rule is needed.
- REJECT fails quickly with a TCP reset, while DROP waits for the client timeout.
- All iptables rules and policies exist only inside `lab-fw`.

## Common failure causes

- `iptables`, `curl`, or `python3` is missing.
- The HTTP process failed; inspect `run/http.log`.
- Rule order places DROP before an allow rule.
- Conntrack support is unavailable in the kernel.
- A stale topology is active; run `sudo ./lab.sh down`, then retry.
