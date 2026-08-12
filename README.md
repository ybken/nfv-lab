# Linux Virtual Network / NFV Lab

一个按阶段搭建的 Linux 虚拟网络实验，用于观察二层邻接、三层转发、防火墙、NAT 和流量控制。

## 目标拓扑

```text
lab-client          lab-router           lab-fw              lab-server
10.10.1.2/24  <->  10.10.1.1/24
                    10.10.2.1/24  <->   10.10.2.2/24
                                         10.10.3.1/24  <->  10.10.3.2/24
```

最终数据路径：

```text
client -- router -- firewall -- server
```

Stage 4 在 router namespace 内提供互斥的 SNAT、DNAT 和关闭模式；默认不启用 NAT。

## 仓库结构

```text
.
├── README.md
├── lab.sh
└── docs
    ├── STATE.md
    └── labs
        ├── stage-0.md
        ├── stage-1.md
        ├── stage-2.md
        ├── stage-3.md
        └── stage-4.md
```

## Stage 4 使用

环境检查不会修改系统。拓扑操作需要 root 权限：

```bash
./lab.sh check
sudo ./lab.sh up 4
sudo ./lab.sh nat snat
sudo ./lab.sh nat dnat
sudo ./lab.sh nat off
sudo ./lab.sh test 4
sudo ./lab.sh status
sudo ./lab.sh down
```
