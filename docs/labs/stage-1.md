# Stage 1 — Namespaces and L2 Adjacency

## Objective

Create four network namespaces and connect each adjacent pair with veth interfaces. Assign interface addresses and demonstrate ARP plus same-subnet connectivity without forwarding.

## Topology change

```text
lab-client eth0  <->  eth0 lab-router eth1  <->  eth0 lab-fw eth1  <->  eth0 lab-server
  10.10.1.2/24       10.10.1.1/24  10.10.2.1/24   10.10.2.2/24  10.10.3.1/24   10.10.3.2/24
```

IPv4 forwarding remains disabled in every namespace. No static routes, ACLs, or NAT rules are added.

## Important commands

```bash
sudo ./lab.sh up 1
sudo ./lab.sh status
sudo ip -n lab-client link show
sudo ip -n lab-client address show
sudo ip -n lab-client neighbor show
```

## Verification

```bash
sudo ./lab.sh test 1
```

The test pings across each directly connected subnet:

- `lab-client` to `lab-router` at `10.10.1.1`
- `lab-router` to `lab-fw` at `10.10.2.2`
- `lab-fw` to `lab-server` at `10.10.3.2`

## Expected result

All three adjacent pings succeed, forwarding is reported as disabled, and neighbor entries appear after the pings.

## What to observe

- Each veth endpoint has its own MAC address.
- The first ping triggers ARP resolution on that link.
- Neighbor entries map the adjacent IPv4 address to its MAC address.
- Client-to-server traffic is not routable at this stage.

## Common failure causes

- The command was not run as root.
- A required `iproute2` or `ping` command is missing.
- A partial topology from an interrupted manual experiment uses the same names.
- An interface is down or has an unexpected address.

Clean up with `sudo ./lab.sh down` before retrying.

