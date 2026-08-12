# Stage 4 — SNAT and DNAT

## Objective

Demonstrate mutually exclusive SNAT and DNAT/port-forwarding modes in `lab-router`, including their conntrack representation.

## Topology change

Stage 3 remains active. `sudo ./lab.sh up 4` starts with NAT off. Select one mode:

- `snat`: client HTTP traffic to `10.10.3.2:8080` is source-translated to `10.10.2.1`.
- `dnat`: router `10.10.1.1:8080` is forwarded to server `10.10.3.2:8080`.
- `off`: the router NAT table contains no project rules.

Each mode change flushes router NAT rules and router conntrack entries before adding one mode.

## Important commands

```bash
sudo ./lab.sh up 4
sudo ./lab.sh nat snat
sudo ./lab.sh nat dnat
sudo ./lab.sh nat off
sudo ./lab.sh status
```

## Verification

```bash
sudo ./lab.sh test 4
```

The test runs SNAT and DNAT separately, checks HTTP, prints NAT counters and conntrack tuples, then restores `off`.

For manual packet observation, run these in separate terminals before a curl:

```bash
sudo ip netns exec lab-router tcpdump -ni eth0 tcp port 8080
sudo ip netns exec lab-router tcpdump -ni eth1 tcp port 8080
```

## Expected result

SNAT HTTP and DNAT HTTP both succeed in their own mode. `test 4` ends with NAT mode `off`.

## What to observe

- SNAT: router `eth0` sees source `10.10.1.2`; `eth1` sees source `10.10.2.1`.
- DNAT: router `eth0` receives destination `10.10.1.1`; `eth1` sends destination `10.10.3.2`.
- Conntrack records original and reply tuples so reverse translation is automatic.
- NAT rules exist only inside `lab-router`; firewall filtering remains inside `lab-fw`.

## Common failure causes

- `conntrack`, `iptables`, or kernel NAT support is unavailable.
- The selected curl target does not match the active mode.
- An old connection is reused; switch modes again to flush conntrack.
- The HTTP service is not running; inspect `run/http.log`.

