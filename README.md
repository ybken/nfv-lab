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

Stage 0 只建立仓库和文档骨架，不创建 namespace、veth、地址、路由或防火墙规则。

## 仓库结构

```text
.
├── README.md
├── lab.sh
└── docs
    ├── STATE.md
    └── labs
        └── stage-0.md
```

## Stage 0 使用

环境检查不会修改系统：

```bash
./lab.sh check
./lab.sh status
./lab.sh test 0
```

当前阶段不需要也不应使用 `sudo`。后续阶段的特权命令将在对应阶段实现后说明。

