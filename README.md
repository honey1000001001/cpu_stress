<p align="center">
  <h1 align="center">🚀 CPU Stress Daemon</h1>
  <p align="center">
    <strong>生产级CPU加压守护进程 | K8s集群Worker节点专用</strong>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/Python-3.6+-blue.svg" alt="Python">
    <img src="https://img.shields.io/badge/Linux-UOS%20201050-green.svg" alt="Linux">
    <img src="https://img.shields.io/badge/K8s-Ready-orange.svg" alt="K8s">
    <img src="https://img.shields.io/badge/Version-1.0.0-brightgreen.svg" alt="Version">
  </p>
</p>

---

## 📋 项目简介

一个专为 **K8s集群Worker节点** 设计的生产级CPU加压守护进程。通过PI控制算法精确调节CPU使用率，满足合规水位要求，同时保护K8s组件，感知节点压力驱逐。

### 🎯 核心价值

| 价值 | 说明 |
|------|------|
| **合规达标** | 满足月度CPU利用率水位要求（如40%） |
| **零影响** | 5层安全防护，确保不影响生产业务 |
| **智能控制** | PI控制算法，精确稳定在目标水位 |
| **K8s友好** | 感知节点状态，自动避让K8s组件 |

---

## ✨ 核心特性

<details>
<summary><strong>🔧 PI控制算法</strong></summary>

- **比例控制(P)**：快速响应CPU变化
- **积分控制(I)**：消除静态误差，精确稳定
- **占空比调节**：5%~100%连续可调

</details>

<details>
<summary><strong>🛡️ K8s感知保护</strong></summary>

- 监控节点Condition（Ready/MemoryPressure/DiskPressure/PIDPressure）
- 30秒API缓存，降低97% API Server压力
- 驱逐压力检测，自动停止加压

</details>

<details>
<summary><strong>📊 月度配额控制</strong></summary>

- 精确控制每月CPU达标时间占比
- 支持daily/random/manual三种配额模式
- 配额状态持久化，跨月自动重置

</details>

<details>
<summary><strong>🔒 5层安全防护</strong></summary>

- 外部看门狗 → 内部看门狗 → Worker自保护 → 主进程防护 → K8s感知
- 原子PID文件、文件锁、内存限制、CPU紧急制动

</details>

---

## 🚀 快速开始

### 安装

```bash
# 下载脚本
git clone https://github.com/honey1000001001/cpu_stress
cd cpu-stress-daemon

# 设置权限
chmod +x cpu_stress.py cpu_stress_worker.py cpu_stress_ctl.sh cpu_stress_watchdog.sh
```

### 启动

```bash
# 方式1：使用控制脚本（推荐）
bash cpu_stress_ctl.sh start 40

# 方式2：直接启动（测试环境）
python3 cpu_stress.py --target 40 --no-protect-k8s --no-check-eviction

# 方式3：生产环境
python3 cpu_stress.py --target 40 --quota 6 --daemon
```

### 停止

```bash
# 方式1：控制脚本
bash cpu_stress_ctl.sh stop

# 方式2：信号停止
kill -TERM $(cat ~/.cpu_stress/cpu_stress.pid)
```

---

## 📁 项目结构

```
cpu-stress-daemon/
├── cpu_stress.py              # 主守护进程 (1083行)
├── cpu_stress_worker.py       # Worker进程模块 (58行)
├── cpu_stress_ctl.sh          # 控制脚本 (1253行)
├── cpu_stress_watchdog.sh     # 外部看门狗 (38行)
└── README.md                  # 项目文档

运行时目录：~/.cpu_stress/
├── cpu_stress.pid             # 主进程PID
├── cpu_stress.lock            # 排他锁文件
├── quota.json                 # 配额状态
├── quota.json.bak             # 配额备份
└── log/                       # 日志目录
    ├── cpu_stress.log         # 当前日志
    ├── cpu_stress.log.*.log   # 轮转日志
    └── cpu_stress_watchdog.log
```

---

## 🏗️ 架构设计

### 进程模型

```
┌─────────────────────────────────────────────────────┐
│                  主守护进程                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │ CPU监控器   │  │ PI调节器    │  │ K8s检查器   │ │
│  │ /proc/stat  │  │ 误差→休眠   │  │ 节点状态    │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘ │
│         │                │                │         │
│         └────────────────┼────────────────┘         │
│                          ▼                          │
│              ┌─────────────────────┐                │
│              │   任务调度器        │                │
│              │  Queue → Workers    │                │
│              └──────────┬──────────┘                │
│                         │                           │
│         ┌───────────────┼───────────────┐          │
│         ▼               ▼               ▼          │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │
│  │  Worker 0   │ │  Worker 1   │ │  Worker N   │  │
│  │ 计算+休眠   │ │ 计算+休眠   │ │ 计算+休眠   │  │
│  └─────────────┘ └─────────────┘ └─────────────┘  │
│                                                    │
│              ┌─────────────────────┐                │
│              │    看门狗进程       │                │
│              │   心跳监控+清理     │                │
│              └─────────────────────┘                │
└─────────────────────────────────────────────────────┘
```

### PI控制流程

```
┌──────────────┐
│  读取CPU使用率 │
└──────┬───────┘
       ▼
┌──────────────┐
│  计算误差     │  error = target - current
└──────┬───────┘
       ▼
┌──────────────┐
│  PI控制计算   │  sleep = 0.5 - P项 - I项
└──────┬───────┘
       ▼
┌──────────────┐
│  发送休眠指令 │  Queue → Worker
└──────┬───────┘
       ▼
┌──────────────┐
│  Worker执行   │  计算X秒 + 休眠Y秒
└──────────────┘
```

---

## ⚙️ 配置参数

### 基础参数

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| `--target` | 40 | 0-100 | 目标CPU水位(%) |
| `--interval` | 2 | - | 监控间隔(秒) |
| `--max-workers` | 核心数/2 | - | Worker数量 |
| `--daemon` | off | - | 后台运行模式 |
| `--dry-run` | off | - | 仅监控不加压 |

### K8s保护参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--protect-k8s` | on | 启用K8s组件保护 |
| `--k8s-reserve` | 10 | K8s组件预留CPU(%) |
| `--check-eviction` | on | 检查驱逐阈值 |
| `--kubectl-timeout` | 30 | kubectl超时(秒) |

### 月度配额参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--quota` | 6 | 月度配额(%) |
| `--quota-mode` | daily | 配额模式(daily/random/manual) |
| `--quota-window` | 720 | 统计窗口(小时) |

---

## 📊 日志输出

### 启动日志

```
[INFO] CPU Stress Daemon started (PID=12345)
[INFO] Cores: 4, Max workers: 2
[INFO] Target: 40%, K8s Reserve: 10%, Available: 30%
[INFO] Quota: 6%/month, Remaining: 2592.0min
[INFO] Worker 0 started (PID=12346)
[INFO] Worker 1 started (PID=12347)
```

### 运行日志

```
[INFO] CPU:32.3% 目标:40% (K8s预留10%) 误差:+7.7% Workers:2/2
[INFO]   → Worker 0: sleep 0.32s (加压中, 占空比61%, P:+0.13 I:+0.05)
[INFO]   → Worker 1: sleep 0.32s (加压中, 占空比61%, P:+0.13 I:+0.05)
```

### 状态说明

| 状态 | 含义 | sleep范围 |
|------|------|-----------|
| 🔺 加压中 | CPU不足，增加计算时间 | < 0.3s |
| ⚖️ 维持中 | 平衡状态 | 0.3-0.7s |
| 🔻 减压中 | CPU过高，增加休眠时间 | > 0.7s |

---

## 🔐 安全设计

### 5层防护架构

```
Layer 5: 配额控制      ─ 月度限制/持久化
Layer 4: K8s感知       ─ 节点状态/API缓存
Layer 3: 主进程防护    ─ 文件锁/原子写入/超时
Layer 2: Worker自保护  ─ 内存限制/占空比控制
Layer 1: 内部看门狗    ─ 心跳监控
Layer 0: 外部看门狗    ─ crontab最后防线
```

### 安全特性一览

| 特性 | 实现方式 |
|------|----------|
| 多实例防护 | `fcntl.flock`排他锁 + O_EXCL原子创建 |
| PID文件安全 | 防止TOCTOU竞态和symlink攻击 |
| 目录权限 | `0o700`，其他用户不可访问 |
| kubectl超时 | 所有调用30秒超时 |
| API缓存 | 30秒TTL，降低97%调用 |
| CPU紧急制动 | >95%立即停止 |
| 内存保护 | Worker限制256MB |
| 配额安全 | 原子写入 + CRC32校验 |
| 时钟安全 | `time.monotonic()`防NTP跳变 |
| 参数校验 | --target/--quota强制0-100 |

### 失败策略

> **原则：任何错误 → 记录日志 → 退出程序**

| 场景 | 处理 |
|------|------|
| kubectl不可用 | 报错退出 |
| kubectl失败 | 停止worker，退出 |
| 节点NotReady | 停止worker，等待恢复 |
| 驱逐压力 | 停止worker，等待恢复 |

---

## 🛠️ 信号控制

| 信号 | 功能 |
|------|------|
| `SIGTERM` | 优雅停止 |
| `SIGINT` | 同SIGTERM (Ctrl+C) |
| `SIGUSR1` | 目标+10% |
| `SIGUSR2` | 目标-10% |

```bash
PID=$(cat ~/.cpu_stress/cpu_stress.pid)
kill -USR1 $PID    # 目标+10%
kill -USR2 $PID    # 目标-10%
kill -TERM $PID    # 停止
```

---

## 📦 部署

### 控制脚本

```bash
bash cpu_stress_ctl.sh           # 交互式菜单
bash cpu_stress_ctl.sh start 40  # 启动
bash cpu_stress_ctl.sh stop      # 停止
bash cpu_stress_ctl.sh status    # 状态
bash cpu_stress_ctl.sh log       # 日志
```

### 外部看门狗

```bash
# 部署到crontab
crontab -e
* * * * * /path/to/cpu_stress_watchdog.sh
```

### 日志轮转

| 策略 | 阈值 | 保留 |
|------|------|------|
| 时间轮转 | 每6小时 | 2天 |
| 大小轮转 | 1MB | - |
| 磁盘保护 | <100MB | 停止写入 |

---

## ❓ 常见问题

<details>
<summary><strong>Q: 脚本无法启动？</strong></summary>

```bash
# 检查残留进程
ps aux | grep cpu_stress

# 清理状态
rm -rf ~/.cpu_stress/
```

</details>

<details>
<summary><strong>Q: kubectl不可用？</strong></summary>

```bash
# 测试权限
sudo -n kubectl get nodes

# 配置sudoers
sudo visudo
# 添加: username ALL=(ALL) NOPASSWD: /usr/bin/kubectl
```

</details>

<details>
<summary><strong>Q: 如何查看日志？</strong></summary>

```bash
tail -f ~/.cpu_stress/log/cpu_stress.log
grep -E "ERROR|FATAL|WARN" ~/.cpu_stress/log/cpu_stress.log
```

</details>

---

## 📝 版本历史

| 版本 | 日期 | 更新 |
|------|------|------|
| 1.0.0 | 2026-06-23 | 初始发布 |

---

## 📄 许可证

MIT

---

<p align="center">
  <strong>⭐ 如果这个项目对你有帮助，请给个Star支持一下！</strong>
</p>
