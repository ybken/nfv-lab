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

Stage 1 创建 namespace、veth 和接口地址，只支持相邻节点通信；尚未启用转发、静态路由或防火墙规则。

## 仓库结构

```text
.
├── README.md
├── lab.sh
└── docs
    ├── STATE.md
    └── labs
        ├── stage-0.md
        └── stage-1.md
```

## Stage 1 使用

环境检查不会修改系统。拓扑操作需要 root 权限：

```bash
./lab.sh check
sudo ./lab.sh up 1
sudo ./lab.sh test 1
sudo ./lab.sh status
sudo ./lab.sh down
```
