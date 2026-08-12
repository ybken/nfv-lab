# Stage 2 — Routing and IPv4 Forwarding

## Objective

Route traffic end to end from client to server through router and firewall, without packet filtering or NAT.

## Topology change

The Stage 1 links and addresses remain unchanged. Stage 2 adds:

```text
lab-client --default--> lab-router --10.10.3.0/24--> lab-fw --connected--> lab-server
lab-server --default--> lab-fw     --10.10.1.0/24--> lab-router --connected--> lab-client
```

IPv4 forwarding is enabled only in `lab-router` and `lab-fw`.

## Important commands

```bash
sudo ./lab.sh up 2
sudo ./lab.sh status
sudo ip -n lab-router route show
sudo ip netns exec lab-router sysctl net.ipv4.ip_forward
```

## Verification

```bash
sudo ./lab.sh test 2
```

The test checks all four static routes, forwarding scope, and pings in both directions between `10.10.1.2` and `10.10.3.2`.

## Expected result

Both end-to-end pings succeed. Router and firewall report forwarding `1`; client and server report `0`.

## What to observe

- Each routing namespace forwards between its two interfaces.
- The packet keeps its original source and destination IP addresses across every hop.
- Return traffic needs the firewall and server routes as well as the forward path.
- There are no iptables rules or address translations at this stage.

## Common failure causes

- A next-hop address is wrong or its adjacent link is down.
- Forwarding is disabled in `lab-router` or `lab-fw`.
- A forward or return route is missing.
- An older partial topology is active; run `sudo ./lab.sh down`, then retry.

