# Stage 6 — Multi-hop Packet Capture

## Objective

Capture the same ICMP and HTTP flows at every namespace and compare Ethernet/IP/TCP headers across hops.

## Topology change

The Stage 5 topology is unchanged. Six tcpdump processes observe:

```text
client/eth0 -> router/eth0 -> router/eth1 -> fw/eth0 -> fw/eth1 -> server/eth0
```

Captures include ICMP and TCP/8080 only. Files are written under `captures/`.

## Important commands

```bash
sudo ./lab.sh up 6
sudo ./lab.sh capture start
sudo ip netns exec lab-client ping -c 2 10.10.3.2
sudo ip netns exec lab-client curl http://10.10.3.2:8080/docs/STATE.md
sudo ./lab.sh capture stop
sudo ./lab.sh capture summary
```

`capture start` replaces earlier project capture files. `capture stop` preserves the pcap files for analysis.

## Verification

```bash
sudo ./lab.sh test 6
```

The test generates ping and HTTP traffic, verifies all six pcap files are readable and non-empty, then prints up to eight packets per observation point.

## Expected result

All six capture files contain traffic, and the summary shows the same end-to-end IP flow at successive interfaces.

## What to observe

- With NAT off, source and destination IP addresses remain constant across hops.
- Ethernet source/destination MAC addresses change at each routed link.
- TCP ports and sequence/acknowledgment numbers identify the same connection.
- Enable one Stage 4 NAT mode before manual capture to observe address translation at router ingress versus egress.

## Common failure causes

- `tcpdump` is missing or lacks packet-capture permission.
- Traffic was generated before tcpdump finished starting.
- A capture was stopped with a non-flushing signal; use the helper.
- The selected filter sees no ICMP or TCP/8080 traffic.

