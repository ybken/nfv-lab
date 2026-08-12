# Linux Virtual Network / NFV Lab

这是一个按 Stage 0–7 逐步构建的 Linux 虚拟网络与 NFV 学习实验。它只使用 network namespace、veth、路由、Netfilter/iptables、conntrack、Traffic Control、tcpdump、HTTP 和 iperf3，在一台 Linux 主机内模拟：

```text
client -- router -- firewall -- server
```

项目重点不是只得到“能 ping 通”的结果，而是把二层邻接、三层转发、有状态安全策略、地址转换、链路损伤和逐跳观测联系起来。

## 安全边界与依赖

- `lab.sh` 不修改宿主机防火墙、路由或 sysctl；相关操作限定在项目 namespace 内。
- 除 `check`、`up 0` 和 `test 0` 外，拓扑命令需要 root，请由用户显式使用 `sudo`。
- 需要 Bash、iproute2、ping、iptables、curl、python3、conntrack、tc、tcpdump、iperf3、truncate 和 awk。
- 项目会使用固定 namespace 名称：`lab-client`、`lab-router`、`lab-fw`、`lab-server`。
- `up N` 会先删除同名项目资源再累计构建到 Stage N；不要在这些 namespace 中保存其他工作。

先检查环境：

```bash
./lab.sh check
```

## 最终拓扑、地址与路由

```text
lab-client          lab-router           lab-fw              lab-server
eth0                eth0 / eth1          eth0 / eth1         eth0
10.10.1.2/24  <->  10.10.1.1/24
                    10.10.2.1/24  <->   10.10.2.2/24
                                         10.10.3.1/24  <->  10.10.3.2/24
```

路由关系：

- client 默认路由经 `10.10.1.1`。
- router 到 `10.10.3.0/24` 经 `10.10.2.2`。
- firewall 到 `10.10.1.0/24` 经 `10.10.2.1`。
- server 默认路由经 `10.10.3.1`。
- 只有 router 和 firewall namespace 开启 IPv4 forwarding。

## 快速开始与完整回归

```bash
sudo ./lab.sh up 7
sudo ./lab.sh status
sudo ./lab.sh test 7
sudo ./lab.sh down
```

`up 7` 默认保持 NAT off、QoS off、capture stopped，便于从无附加变量的基线开始。`test 7` 会依次验证路由、ICMP、HTTP、ACL、iperf3、SNAT、DNAT、QoS 和六点抓包，结束后重新关闭可选模式。

## 所有 CLI 操作

### 构建、测试、状态与清理

```bash
sudo ./lab.sh up <0|1|2|3|4|5|6|7>
sudo ./lab.sh test <0|1|2|3|4|5|6|7>
sudo ./lab.sh status
sudo ./lab.sh down
```

| 操作 | 会做什么 | 可观察现象 | 对应知识 |
|---|---|---|---|
| `up 0` / `test 0` | 仅检查环境，不创建网络资源 | 输出工具存在或缺失 | 实验依赖、可重复环境 |
| `up 1` / `test 1` | 创建四个 namespace、三对 veth、地址和 loopback | 相邻节点 ping 成功；neighbor 表出现 IP→MAC | namespace 隔离、veth、ARP、L2 邻接 |
| `up 2` / `test 2` | 添加静态路由，仅 router/fw 开启转发 | client 与 server 双向 ping；各 namespace 路由表不同 | 路由选择、默认路由、返回路径、IP forwarding |
| `up 3` / `test 3` | 在 firewall 配置有状态 ACL，启动 TCP/8080 HTTP | ICMP/HTTP 成功；TCP/8081 快速 REJECT；反向新连接超时 DROP | Netfilter hook、规则顺序、conntrack NEW/ESTABLISHED、DROP/REJECT |
| `up 4` / `test 4` | 加入互斥 SNAT/DNAT 模式，默认关闭 | NAT 计数和 conntrack 原始/回复 tuple 改变 | SNAT、DNAT、端口转发、反向转换 |
| `up 5` / `test 5` | 加入可移除 TBF + netem，默认关闭 | 下载速率受限、RTT 增加、可能丢包、tc 计数变化 | 排队规则、整形、时延、随机丢包 |
| `up 6` / `test 6` | 加入六点 tcpdump 工作流，默认停止 | 同一流在各跳的 MAC、TTL、NAT 前后地址可比较 | 分层封装、逐跳转发、数据平面可观测性 |
| `up 7` / `test 7` | 启动 iperf3 并执行完整回归 | TCP/5201 吞吐结果；所有阶段联合通过 | 性能测试、自动化回归、幂等与生命周期管理 |
| `status` | 显示接口、路由、转发、ACL、NAT、QoS、服务和抓包状态 | 可把控制面配置与测试结果对应起来 | 运维诊断、状态核对 |
| `down` | 停止 HTTP/iperf3/tcpdump 并删除 namespace/veth | `ip netns list` 不再显示项目 namespace | 资源生命周期、安全清理 |

`up N` 是累计构建，例如 `up 5` 包含 Stage 1–5，但不包含 Stage 6–7。运行某个 `test N` 前应先执行对应的 `up N` 或更高阶段。

### NAT 操作

先执行 `sudo ./lab.sh up 4` 或更高阶段：

```bash
sudo ./lab.sh nat off
sudo ./lab.sh nat snat
sudo ./lab.sh nat dnat
```

| 模式 | 测试命令 | 重点观察 |
|---|---|---|
| `off` | `curl http://10.10.3.2:8080/docs/STATE.md` | client/server 端到端地址保持不变 |
| `snat` | `curl http://10.10.3.2:8080/docs/STATE.md` | router eth0 看到源 `10.10.1.2`，eth1 看到源 `10.10.2.1` |
| `dnat` | `curl http://10.10.1.1:8080/docs/STATE.md` | eth0 目的为 router，eth1 目的变为 server `10.10.3.2` |

每次模式切换都会清空 router namespace 的 NAT 规则和 conntrack 条目，因此 SNAT 与 DNAT 不会同时启用。可用以下命令把规则计数与连接状态对应起来：

```bash
sudo ip netns exec lab-router iptables -t nat -L -v -n
sudo ip netns exec lab-router conntrack -L
```

这里体现的是 NAT 只处理连接首包、conntrack 保存双向 tuple、后续包自动执行正向和反向转换。

### QoS 操作

先执行 `sudo ./lab.sh up 5` 或更高阶段：

```bash
sudo ./lab.sh qos set 4mbit 50ms 1%
sudo ip netns exec lab-fw tc -s qdisc show dev eth0
sudo ./lab.sh qos off
```

参数依次是速率、延迟和丢包率。速率支持 `kbit/mbit/gbit`，延迟支持 `us/ms/s`，丢包率范围是 `0%`–`100%`。QoS 位于 `lab-fw eth0` 出口，即 server 返回 client 的方向。

可执行：

```bash
sudo ip netns exec lab-client ping -c 10 10.10.3.2
sudo ip netns exec lab-client curl -o /dev/null -w 'speed=%{speed_download} bytes/s\n' \
  http://10.10.3.2:8080/run/qos.bin
```

应观察到 ping 回包增加约配置的单向出口延迟，HTTP 下载接近 TBF 上限，`tc -s` 中出现 sent、dropped 和 overlimits。它体现了带宽不是“包速率字段”，而是由队列调度控制；netem 则模拟真实链路质量。

### 抓包操作

先执行 `sudo ./lab.sh up 6` 或更高阶段：

```bash
sudo ./lab.sh capture start
sudo ./lab.sh capture status
sudo ip netns exec lab-client ping -c 2 10.10.3.2
sudo ip netns exec lab-client curl http://10.10.3.2:8080/docs/STATE.md
sudo ./lab.sh capture stop
sudo ./lab.sh capture summary
```

抓包文件位于 `captures/`：

| 文件 | 观察点 |
|---|---|
| `client.pcap` | client eth0 |
| `router-in.pcap` / `router-out.pcap` | router eth0 / eth1 |
| `fw-in.pcap` / `fw-out.pcap` | firewall eth0 / eth1 |
| `server.pcap` | server eth0 |

摘要使用 `tcpdump -e -n` 展示二层和三层报头。无 NAT 时，端到端 IP 和 TCP 端口保持一致，但每条路由链路的源/目的 MAC 会变化，IP TTL 会逐跳减小；启用 SNAT 或 DNAT 后，可在 router 入、出口之间看到对应 IP 改写。这把 Ethernet、IP、TCP、路由和 NAT 放到同一条实际报文路径中理解。

### HTTP、iperf3 与手工诊断

Stage 3 及以上提供 HTTP：

```bash
sudo ip netns exec lab-client curl http://10.10.3.2:8080/docs/STATE.md
```

Stage 7 提供 iperf3：

```bash
sudo ip netns exec lab-client iperf3 -c 10.10.3.2 -t 5
```

HTTP 验证应用可达性和有状态返回流量；iperf3 用持续 TCP 流量测量吞吐。配合 QoS 时，可以比较 iperf3 报告值与 TBF 配置，理解应用吞吐、TCP 拥塞控制和链路整形之间的关系。

常用只读诊断：

```bash
sudo ip netns list
sudo ip -br -n lab-router address
sudo ip -n lab-router route
sudo ip -n lab-client neighbor
sudo ip netns exec lab-fw sysctl net.ipv4.ip_forward
sudo ip netns exec lab-fw iptables -L FORWARD -v -n --line-numbers
sudo ip netns exec lab-router iptables -t nat -L -v -n
sudo ip netns exec lab-router conntrack -L
sudo ip netns exec lab-fw tc -s qdisc show dev eth0
```

## 建议学习与复习路径

1. 先做 Stage 1，只看 interface、MAC、ARP 和相邻 ping，回答“同一子网如何找到下一跳 MAC”。
2. 做 Stage 2，对照四张路由表和双向 ping，回答“去程和回程分别依赖哪些路由”。
3. 做 Stage 3，观察规则计数，比较 REJECT 与 DROP 的客户端体验，回答“为什么响应不需要单独开放临时端口”。
4. 做 Stage 4，分别抓 SNAT、DNAT，结合 conntrack tuple，回答“地址在哪个 hook 改写、回复如何恢复”。
5. 做 Stage 5，用多组 rate/delay/loss 重复 ping、curl、iperf3，回答“吞吐、RTT、丢包如何互相影响”。
6. 做 Stage 6，把六份 pcap 中同一连接按时间、IP、端口和 TCP sequence 对齐，回答“哪些字段端到端不变，哪些字段逐跳变化”。
7. 最后运行 Stage 7 全量回归，再执行 `down` 并检查 namespace 消失，复习自动化、幂等和资源清理。

每个阶段的简明目标、命令、预期结果和故障原因位于 `docs/labs/stage-N.md`；当前实现状态位于 `docs/STATE.md`。

## 运行产物与故障排查

- `run/http.log`：HTTP 服务启动或请求错误。
- `run/iperf3.log`：iperf3 服务错误。
- `captures/*.pcap`：停止抓包或 `down` 后仍保留，方便离线复习。
- `captures/*.log`：各 tcpdump 进程的诊断输出。

若实验状态混乱，先执行：

```bash
sudo ./lab.sh down
sudo ./lab.sh up 7
sudo ./lab.sh test 7
```

脚本不会自动安装软件，也不会调用 `sudo`；缺少工具时请根据 `./lab.sh check` 的结果自行安装。
