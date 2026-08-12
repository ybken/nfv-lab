# Stage 0 — Repository Skeleton

## Objective

Create the minimal repository layout and verify that tools needed by later stages are discoverable.

## Topology change

None. This stage creates no namespace, interface, address, route, firewall rule, or process.

## Important commands

```bash
./lab.sh check
./lab.sh status
```

## Verification

```bash
bash -n ./lab.sh
./lab.sh test 0
```

## Expected result

The script passes Bash syntax validation and reports which required and optional commands are available. A missing required command makes the check fail without installing or changing anything.

## What to observe

Only command availability and the recorded project stage; the host network remains unchanged.

## Common failure causes

- `iproute2`, `iptables`, or another required package is not installed.
- The script is not executable; restore it with `chmod +x lab.sh`.
- The script is run with a shell other than Bash.

