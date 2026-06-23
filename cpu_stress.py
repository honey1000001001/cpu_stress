#!/usr/bin/env python3
"""
CPU Stress Daemon for K8s Worker Nodes
Production-grade CPU stress script for UOS 201050 Hygon 64-bit.
No root required. Protects K8s components. Monthly quota controlled.
"""

import argparse
import atexit
import ctypes
import fcntl
import hashlib
import json
import math
import multiprocessing
import os
import resource
import signal
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from datetime import datetime

VERSION = "1.0.0"

# Exceptions
class K8sCheckError(Exception):
    pass

# ======================== CpuMonitor ========================
class CpuMonitor:
    def __init__(self):
        self.last_stat = None
        self.last_time = None
        self.consecutive_failures = 0

    def get_usage(self):
        try:
            with open('/proc/stat', 'r') as f:
                line = f.readline()
            parts = line.split()
            user = int(parts[1])
            nice = int(parts[2])
            system = int(parts[3])
            idle = int(parts[4])
            iowait = int(parts[5])
            now = time.monotonic()

            total = user + nice + system + idle + iowait
            idle_total = idle + iowait

            if self.last_stat is None:
                self.last_stat = (total, idle_total)
                self.last_time = now
                self.consecutive_failures = 0
                return 0.0

            total_delta = total - self.last_stat[0]
            idle_delta = idle_total - self.last_stat[1]

            self.last_stat = (total, idle_total)
            self.last_time = now
            self.consecutive_failures = 0

            if total_delta == 0:
                return 0.0
            return (total_delta - idle_delta) / total_delta * 100.0
        except Exception:
            self.consecutive_failures += 1
            if self.consecutive_failures >= 3:
                return None
            return 0.0

# ======================== K8sHealthChecker ========================
class K8sHealthChecker:
    def __init__(self, kubectl_timeout=30, eviction_margin=5, k8s_reserve=10):
        self.kubectl_timeout = kubectl_timeout
        self.eviction_margin = eviction_margin
        self.k8s_reserve = k8s_reserve
        self.node_name = None
        self._detect_node_name()
        
        # K8s状态缓存：避免高频调用API Server
        self._cache = None
        self._cache_time = 0
        self._cache_ttl = 30  # 缓存30秒

    def _run_kubectl(self, args):
        cmd = ['sudo', '-n', 'kubectl'] + args
        try:
            result = subprocess.run(
                cmd, timeout=self.kubectl_timeout,
                capture_output=True, text=True
            )
            if result.returncode != 0:
                raise K8sCheckError(
                    f"kubectl {' '.join(args)} failed: {result.stderr.strip()}"
                )
            return result.stdout
        except subprocess.TimeoutExpired:
            raise K8sCheckError(
                f"kubectl {' '.join(args)} timed out after {self.kubectl_timeout}s"
            )
        except FileNotFoundError:
            raise K8sCheckError("kubectl or sudo not found")
        except PermissionError:
            raise K8sCheckError("sudo permission denied (run 'sudo -n true' to test)")

    def _detect_node_name(self):
        hostname = os.uname().nodename
        try:
            output = self._run_kubectl(['get', 'nodes', '-o', 'wide'])
            lines = output.strip().split('\n')
            if len(lines) < 2:
                raise K8sCheckError("No nodes found in cluster")
            headers = lines[0].split()
            name_idx = 0
            hostname_idx = -1
            internal_ip_idx = -1
            for i, h in enumerate(headers):
                h_lower = h.lower()
                if h_lower == 'hostname':
                    hostname_idx = i
                if 'internal-ip' in h_lower or h_lower == 'internal-ip':
                    internal_ip_idx = i
            for line in lines[1:]:
                parts = line.split()
                if hostname_idx >= 0 and hostname_idx < len(parts):
                    if parts[hostname_idx] == hostname:
                        self.node_name = parts[name_idx]
                        return
                if internal_ip_idx >= 0 and internal_ip_idx < len(parts):
                    if parts[internal_ip_idx] == hostname:
                        self.node_name = parts[name_idx]
                        return
            raise K8sCheckError(
                f"Cannot match hostname '{hostname}' to any K8s node"
            )
        except K8sCheckError:
            raise
        except Exception as e:
            raise K8sCheckError(f"Failed to detect node name: {e}")

    def _refresh_cache(self):
        """刷新K8s节点状态缓存"""
        try:
            output = self._run_kubectl([
                'get', 'node', self.node_name, '-o', 'json'
            ])
            data = json.loads(output)
            self._cache = {}
            for cond in data.get('status', {}).get('conditions', []):
                self._cache[cond['type']] = cond['status']
            self._cache_time = time.monotonic()
        except K8sCheckError:
            raise
        except Exception as e:
            raise K8sCheckError(f"Failed to refresh K8s cache: {e}")

    def get_node_conditions(self, force_refresh=False):
        """获取节点状态（带缓存）"""
        now = time.monotonic()
        # 缓存过期 或 强制刷新
        if force_refresh or self._cache is None or (now - self._cache_time) > self._cache_ttl:
            self._refresh_cache()
        return self._cache

    def check_eviction_pressure(self, force_refresh=False):
        try:
            conditions = self.get_node_conditions(force_refresh)
            pressure_types = [
                'MemoryPressure', 'DiskPressure', 'PIDPressure'
            ]
            for ptype in pressure_types:
                if conditions.get(ptype) == 'True':
                    return True
            return False
        except K8sCheckError:
            raise
        except Exception as e:
            raise K8sCheckError(f"Eviction check failed: {e}")

    def is_safe_to_stress(self, force_refresh=False):
        try:
            conditions = self.get_node_conditions(force_refresh)
            if conditions.get('Ready') != 'True':
                return False
            pressure_types = [
                'MemoryPressure', 'DiskPressure', 'PIDPressure'
            ]
            for ptype in pressure_types:
                if conditions.get(ptype) == 'True':
                    return False
            return True
        except K8sCheckError:
            raise
        except Exception:
            return False

# ======================== CRC32 Helper ========================
def zlib_crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF

# ======================== QuotaManager ========================
class QuotaManager:
    def __init__(self, quota_percent, window_hours, state_dir):
        self.quota_percent = quota_percent
        self.window_hours = window_hours
        self.state_file = os.path.join(state_dir, 'quota.json')
        self.used_seconds = 0
        self.current_month = None
        self._load_state()

    def _load_state(self):
        try:
            if os.path.exists(self.state_file):
                with open(self.state_file, 'r') as f:
                    data = json.load(f)
                stored_checksum = data.pop('checksum', None)
                content = json.dumps(data, sort_keys=True)
                computed = format(
                    ctypes.c_uint32(
                        zlib_crc32(content.encode())
                    ).value, '08x'
                )
                if stored_checksum and stored_checksum != computed:
                    print(f"[WARN] Quota file checksum mismatch, resetting", file=sys.stderr)
                    self._reset_state()
                    return
                now_month = datetime.now().strftime('%Y-%m')
                if data.get('month') != now_month:
                    self._reset_state()
                else:
                    self.used_seconds = data.get('used_seconds', 0)
                    self.current_month = data.get('month')
            else:
                self._reset_state()
        except (json.JSONDecodeError, KeyError, TypeError):
            print(f"[WARN] Quota file corrupted, resetting", file=sys.stderr)
            self._reset_state()

    def _reset_state(self):
        self.used_seconds = 0
        self.current_month = datetime.now().strftime('%Y-%m')
        self._save_state()

    def _save_state(self):
        now_month = datetime.now().strftime('%Y-%m')
        if self.current_month != now_month:
            self.used_seconds = 0
            self.current_month = now_month

        data = {
            'month': self.current_month,
            'used_seconds': self.used_seconds,
            'last_update': datetime.now().isoformat(),
        }
        content = json.dumps(data, sort_keys=True)
        checksum = format(
            ctypes.c_uint32(zlib_crc32(content.encode())).value, '08x'
        )
        data['checksum'] = checksum

        dir_path = os.path.dirname(self.state_file)
        if dir_path:
            os.makedirs(dir_path, exist_ok=True)

        tmp_fd, tmp_path = tempfile.mkstemp(
            dir=dir_path, suffix='.tmp', prefix='quota_'
        )
        try:
            with os.fdopen(tmp_fd, 'w') as f:
                json.dump(data, f, indent=2)
            backup = self.state_file + '.bak'
            if os.path.exists(self.state_file):
                shutil.copy2(self.state_file, backup)
            os.rename(tmp_path, self.state_file)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    def can_stress(self):
        total_seconds = self.window_hours * 3600
        quota_seconds = total_seconds * self.quota_percent / 100.0
        return self.used_seconds < quota_seconds

    def record_stress(self, seconds):
        now_month = datetime.now().strftime('%Y-%m')
        if self.current_month != now_month:
            self._reset_state()
        self.used_seconds += seconds
        self._save_state()

    def get_remaining_minutes(self):
        total_seconds = self.window_hours * 3600
        quota_seconds = total_seconds * self.quota_percent / 100.0
        remaining = max(0, quota_seconds - self.used_seconds)
        return remaining / 60.0

    def get_usage_percent(self):
        total_seconds = self.window_hours * 3600
        quota_seconds = total_seconds * self.quota_percent / 100.0
        if quota_seconds == 0:
            return 0.0
        return min(100.0, self.used_seconds / quota_seconds * 100.0)


# ======================== StressWorker ========================
# Worker函数从独立文件导入
from cpu_stress_worker import stress_work

# ======================== Watchdog ========================
def watchdog_process(heartbeat_value, check_interval, timeout, main_pid, state_dir):
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)

    worker_dir = os.path.join(state_dir, 'workers')
    while True:
        time.sleep(check_interval)
        try:
            if not os.path.exists(f'/proc/{main_pid}'):
                _cleanup_orphan_workers(worker_dir)
                break
            last_beat = heartbeat_value.value
            now = time.monotonic()
            if now - last_beat > timeout:
                print(
                    f"[WATCHDOG] Main loop heartbeat expired "
                    f"({now - last_beat:.1f}s > {timeout}s), killing main process",
                    file=sys.stderr
                )
                try:
                    # 先发SIGTERM，给进程清理机会
                    os.kill(main_pid, signal.SIGTERM)
                    time.sleep(5)
                    # 如果还活着，再发SIGKILL
                    if os.path.exists(f'/proc/{main_pid}'):
                        os.kill(main_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                time.sleep(1)
                _cleanup_orphan_workers(worker_dir)
                break
        except Exception:
            pass


def _cleanup_orphan_workers(worker_dir):
    if not os.path.isdir(worker_dir):
        return
    for fname in os.listdir(worker_dir):
        if fname.endswith('.pid'):
            fpath = os.path.join(worker_dir, fname)
            try:
                with open(fpath, 'r') as f:
                    wpid = int(f.read().strip())
                try:
                    os.kill(wpid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                os.unlink(fpath)
            except Exception:
                try:
                    os.unlink(fpath)
                except OSError:
                    pass

# ======================== CpuStressDaemon ========================
class CpuStressDaemon:
    def __init__(self, args):
        self.args = args
        self.target = args.target
        self.interval = args.interval
        self.max_workers = args.max_workers
        self.state_dir = os.path.expanduser(args.state_dir)
        self.k8s_reserve = args.k8s_reserve
        self.deadband = 5
        self.dry_run = args.dry_run
        self.verbose = args.verbose
        self.log_file = args.log_file
        self.protect_k8s = args.protect_k8s
        self.check_eviction = args.check_eviction
        
        # K8s保护关闭时，不预留CPU
        if not self.protect_k8s:
            self.k8s_reserve = 0
        self.kubectl_timeout = args.kubectl_timeout
        self.eviction_margin = args.eviction_margin
        self.max_worker_lifetime = args.max_worker_lifetime
        self.watchdog_enabled = args.watchdog
        self.watchdog_timeout = args.watchdog_timeout
        self.mem_limit = args.mem_limit
        self.cpu_affinity = args.cpu_affinity
        self.quota_percent = args.quota
        self.quota_mode = args.quota_mode
        self.quota_window = args.quota_window

        self.monitor = CpuMonitor()
        self.k8s_checker = None
        self.quota_manager = None
        self.workers = []
        self.stop_event = multiprocessing.Event()
        self.heartbeat = multiprocessing.Value(ctypes.c_double, time.monotonic())
        self.lock_fd = None
        self.pid_file = os.path.join(self.state_dir, 'cpu_stress.pid')
        self.lock_file = os.path.join(self.state_dir, 'cpu_stress.lock')
        self.workers_dir = os.path.join(self.state_dir, 'workers')
        self.restart_timestamps = []
        self._pending_target_change = 0
        self.log_fh = None
        self._setup_logging()

    def _setup_logging(self):
        # 统一日志目录
        self.log_dir = os.path.join(self.state_dir, 'log')
        os.makedirs(self.log_dir, exist_ok=True)

        if self.log_file and self.log_file != '-':
            # 如果指定了日志文件，使用指定路径
            log_path = self.log_file
        else:
            # 默认放到统一日志目录
            log_path = os.path.join(self.log_dir, 'cpu_stress.log')
            self.log_file = log_path

        os.makedirs(os.path.dirname(log_path) or '.', exist_ok=True)
        self.log_fh = open(log_path, 'a', buffering=1)
        self.log_max_size = 1 * 1024 * 1024  # 1MB大小阈值
        self.log_rotate_hours = 6  # 6小时轮转周期
        self.log_retain_days = 2   # 保留2天
        self._last_rotate_hour = datetime.now().hour

    def _rotate_log(self):
        """日志轮转：时间+大小双触发"""
        if not self.log_fh or not self.log_file:
            return
        try:
            now = datetime.now()
            current_hour = now.hour
            need_rotate = False

            # 检查1：时间触发（每6小时）
            if current_hour != self._last_rotate_hour:
                # 检查是否到了轮转时间点（0, 6, 12, 18点）
                if current_hour % self.log_rotate_hours == 0:
                    need_rotate = True

            # 检查2：大小触发（超过1MB）
            if os.path.exists(self.log_file):
                size = os.path.getsize(self.log_file)
                if size >= self.log_max_size:
                    need_rotate = True

            if need_rotate:
                # 检查磁盘空间
                stat = os.statvfs(os.path.dirname(self.log_file) or '.')
                free_mb = (stat.f_bavail * stat.f_frsize) / (1024 * 1024)
                if free_mb < 100:
                    self.log('WARN', f"磁盘空间不足 ({free_mb:.0f}MB)，停止写入日志")
                    return

                # 执行轮转
                self.log_fh.close()
                timestamp = now.strftime('%Y%m%d_%H')
                backup = f"{self.log_file}.{timestamp}.log"
                if os.path.exists(backup):
                    os.remove(backup)
                os.rename(self.log_file, backup)
                self.log_fh = open(self.log_file, 'a', buffering=1)
                self._last_rotate_hour = current_hour
                size_mb = os.path.getsize(backup) / 1024 / 1024
                self.log('INFO', f"日志已轮转: {os.path.basename(backup)} ({size_mb:.1f}MB)")

                # 清理旧日志
                self._cleanup_old_logs()

        except Exception:
            pass

    def _cleanup_old_logs(self):
        """清理超过保留天数的旧日志"""
        try:
            import glob
            pattern = f"{self.log_file}.*.log"
            cutoff = datetime.now().timestamp() - (self.log_retain_days * 86400)

            for f in glob.glob(pattern):
                if os.path.getmtime(f) < cutoff:
                    os.remove(f)
        except Exception:
            pass

    def log(self, level, msg):
        ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        line = f"{ts} [{level}] {msg}"
        # 只在非守护进程模式下打印到stdout
        if not self.args.daemon:
            print(line)
        if self.log_fh:
            try:
                self.log_fh.write(line + '\n')
                # 定期检查轮转
                if hasattr(self, '_log_counter'):
                    self._log_counter += 1
                else:
                    self._log_counter = 1
                if self._log_counter % 100 == 0:
                    self._rotate_log()
            except Exception:
                pass

    def _acquire_lock(self):
        os.makedirs(self.state_dir, exist_ok=True, mode=0o700)
        os.makedirs(self.workers_dir, exist_ok=True, mode=0o700)

        pid_path = self.pid_file
        if os.path.exists(pid_path):
            try:
                with open(pid_path, 'r') as f:
                    old_pid = int(f.read().strip())
                os.kill(old_pid, 0)
                print(
                    f"[FATAL] Another instance is running (PID={old_pid})",
                    file=sys.stderr
                )
                sys.exit(1)
            except (ProcessLookupError, ValueError, PermissionError):
                try:
                    os.unlink(pid_path)
                except OSError:
                    pass

        self.lock_fd = open(self.lock_file, 'w')
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("[FATAL] Cannot acquire lock, another instance may be running",
                  file=sys.stderr)
            sys.exit(1)

        # 使用原子操作创建PID文件，防止TOCTOU竞态
        fd = os.open(pid_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        with os.fdopen(fd, 'w') as f:
            f.write(str(os.getpid()))

    def _release_lock(self):
        try:
            if self.lock_fd:
                fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
                self.lock_fd.close()
        except Exception:
            pass
        try:
            os.unlink(self.lock_file)
        except OSError:
            pass

    def _signal_handler(self, signum, frame):
        if signum in (signal.SIGTERM, signal.SIGINT):
            self.stop_event.set()
        elif signum == signal.SIGHUP:
            pass
        elif signum == signal.SIGUSR1:
            self._pending_target_change = 10
        elif signum == signal.SIGUSR2:
            self._pending_target_change = -10

    def _setup_signals(self):
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGHUP, self._signal_handler)
        signal.signal(signal.SIGUSR1, self._signal_handler)
        signal.signal(signal.SIGUSR2, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

    def _interruptible_sleep(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.stop_event.is_set():
                return
            remaining = deadline - time.monotonic()
            sleep_time = min(0.5, max(0, remaining))
            if sleep_time <= 0:
                break
            time.sleep(sleep_time)
            self.heartbeat.value = time.monotonic()

    def _init_workers(self):
        """初始化固定数量的Worker进程（启动时创建，永不退出）"""
        if self.dry_run:
            self.log('INFO', f"Dry run: would start {self.max_workers} workers")
            return

        os.makedirs(self.workers_dir, exist_ok=True)

        for i in range(self.max_workers):
            task_queue = multiprocessing.Queue()
            ctx = multiprocessing.get_context('fork')
            p = ctx.Process(
                target=stress_work,
                args=(
                    task_queue,
                    self.stop_event,
                    os.getpid(),
                    self.mem_limit,
                    i,
                ),
                daemon=False,
            )
            p.start()
            self.workers.append({'process': p, 'queue': task_queue, 'id': i})

            if self.cpu_affinity and hasattr(os, 'sched_setaffinity'):
                try:
                    cpu_id = i % os.cpu_count()
                    os.sched_setaffinity(p.pid, {cpu_id})
                except Exception:
                    pass

            self.log('INFO', f"Worker {i} started (PID={p.pid})")

        self.log('INFO', f"All {self.max_workers} workers initialized")

    def _send_compute_task(self, worker, iterations=1000):
        """向Worker发送计算任务"""
        try:
            worker['queue'].put_nowait({'type': 'compute', 'iterations': iterations})
        except Exception:
            pass

    def _send_sleep_task(self, worker, duration=0.1):
        """向Worker发送休眠任务"""
        try:
            worker['queue'].put_nowait({'type': 'sleep', 'duration': duration})
        except Exception as e:
            self.log('ERROR', f"Failed to send sleep task to Worker {worker['id']}: {e}")

    def _schedule_tasks(self, cpu_usage):
        """根据CPU使用率连续调节Worker休眠时长（PI控制）"""
        if self.dry_run:
            return

        target = self.target - self.k8s_reserve
        cpu_gap = target - cpu_usage  # 正值=CPU不足，负值=CPU过高

        # 积分项：累积误差消除静态误差
        if not hasattr(self, 'integral_error'):
            self.integral_error = 0
        self.integral_error += cpu_gap * self.interval
        # 积分限幅：防止积分饱和（±50%）
        self.integral_error = max(-50, min(50, self.integral_error))

        # PI控制公式
        p_term = cpu_gap * 0.02
        i_term = self.integral_error * 0.001
        sleep_time = max(0.1, min(10.0, 0.5 - p_term - i_term))

        # 判断动作意图
        if sleep_time < 0.3:
            action = "加压中"
        elif sleep_time <= 0.7:
            action = "维持中"
        else:
            action = "减压中"

        # 打印汇总信息
        alive_workers = sum(1 for w in self.workers if w['process'].is_alive())
        if self.k8s_reserve > 0:
            self.log('INFO', f"CPU:{cpu_usage:.1f}% 目标:{self.target:.0f}% (K8s预留{self.k8s_reserve}%) "
                     f"误差:{cpu_gap:+.1f}% Workers:{alive_workers}/{len(self.workers)}")
        else:
            self.log('INFO', f"CPU:{cpu_usage:.1f}% 目标:{self.target:.0f}% "
                     f"误差:{cpu_gap:+.1f}% Workers:{alive_workers}/{len(self.workers)}")

        # 打印每个Worker详情
        duty_cycle = 0.5 / (0.5 + sleep_time) * 100
        for worker in self.workers:
            if not worker['process'].is_alive():
                continue
            self._send_sleep_task(worker, sleep_time)
            self.log('INFO', f"  → Worker {worker['id']}: sleep {sleep_time:.2f}s "
                     f"({action}, 占空比{duty_cycle:.0f}%, "
                     f"P:{p_term:+.2f} I:{i_term:+.2f})")

    def _stop_all_workers(self):
        """优雅停止所有Worker"""
        for worker in self.workers:
            try:
                # 发送哨兵值通知worker退出
                worker['queue'].put_nowait(None)
            except Exception:
                pass

        for worker in self.workers:
            p = worker['process']
            if p.is_alive():
                p.join(timeout=5)
                if p.is_alive():
                    p.terminate()
                    p.join(timeout=3)

        self.workers.clear()
        self.log('INFO', "All workers stopped")

    def _check_workers(self):
        """检查Worker健康状态"""
        for worker in self.workers:
            p = worker['process']
            if not p.is_alive():
                if p.exitcode and p.exitcode != 0:
                    self.log('ERROR', f"Worker {worker['id']} (PID={p.pid}) exited abnormally with code {p.exitcode}")
                    self._restart_worker(worker)
                elif p.exitcode == 0:
                    self.log('WARN', f"Worker {worker['id']} (PID={p.pid}) exited normally, restarting")
                    self._restart_worker(worker)

    def _restart_worker(self, old_worker):
        """重启单个Worker"""
        try:
            task_queue = multiprocessing.Queue()
            ctx = multiprocessing.get_context('fork')
            p = ctx.Process(
                target=stress_work,
                args=(
                    task_queue,
                    self.stop_event,
                    os.getpid(),
                    self.mem_limit,
                    old_worker['id'],
                ),
                daemon=False,
            )
            p.start()
            # 更新worker信息
            old_worker['process'] = p
            old_worker['queue'] = task_queue
            self.log('INFO', f"Worker {old_worker['id']} restarted (PID={p.pid})")
        except Exception as e:
            self.log('ERROR', f"Failed to restart worker {old_worker['id']}: {e}")

    def _safe_remove(self, path):
        allowed_dir = os.path.realpath(self.state_dir) + os.sep
        real_path = os.path.realpath(path)
        if not real_path.startswith(allowed_dir):
            self.log('ERROR', f"Refused to delete outside allowed dir: {path}")
            return
        try:
            os.unlink(path)
            self.log('DEBUG', f"Removed {path}")
        except OSError:
            pass

    def _check_main_memory(self):
        try:
            usage = resource.getrusage(resource.RUSAGE_SELF)
            rss_kb = usage.ru_maxrss
            if rss_kb > 512 * 1024:
                self.log('WARN', f"Main process memory > 512MB ({rss_kb/1024:.0f}MB), consider restart")
        except Exception:
            pass

    def run(self):
        os.makedirs(self.state_dir, exist_ok=True)
        os.makedirs(self.workers_dir, exist_ok=True)

        self._acquire_lock()
        self._setup_signals()
        atexit.register(self.stop)

        self.log('INFO', f"CPU Stress Daemon started (PID={os.getpid()})")
        self.log('INFO', f"State dir: {self.state_dir}")

        cpu_count = os.cpu_count() or 1
        if self.max_workers is None:
            self.max_workers = max(1, cpu_count // 2)
        self.log('INFO', f"Cores: {cpu_count}, Max workers: {self.max_workers}")

        if self.max_workers == 0:
            self.log('ERROR', "No cores available for workers (need at least 2), exiting")
            sys.exit(1)

        if self.protect_k8s:
            try:
                self.k8s_checker = K8sHealthChecker(
                    kubectl_timeout=self.kubectl_timeout,
                    eviction_margin=self.eviction_margin,
                    k8s_reserve=self.k8s_reserve,
                )
                self.log('INFO', f"K8s Protection: enabled, Node: {self.k8s_checker.node_name}")
            except K8sCheckError as e:
                self.log('FATAL', f"K8s initialization failed: {e}")
                self.log('FATAL', "Cannot verify K8s safety, refusing to start")
                sys.exit(1)

        self.quota_manager = QuotaManager(
            self.quota_percent, self.quota_window, self.state_dir
        )
        self.log('INFO', f"Quota: {self.quota_percent}%/month, "
                 f"Used: {self.quota_manager.get_usage_percent():.1f}%, "
                 f"Remaining: {self.quota_manager.get_remaining_minutes():.1f}min")
        self.log('INFO', f"Target: {self.target}%, K8s Reserve: {self.k8s_reserve}%, "
                 f"Available: {self.target - self.k8s_reserve}%")
        self.log('INFO', f"K8s Protection: {'enabled' if self.protect_k8s else 'disabled'}, "
                 f"Eviction Check: {'enabled' if self.check_eviction else 'disabled'}")

        if self.watchdog_enabled:
            ctx = multiprocessing.get_context('fork')
            self._watchdog_proc = ctx.Process(
                target=watchdog_process,
                args=(
                    self.heartbeat,
                    self.interval * 3,
                    self.watchdog_timeout,
                    os.getpid(),
                    self.state_dir,
                ),
                daemon=True,
            )
            self._watchdog_proc.start()
            self.log('INFO', f"Watchdog process started (PID={self._watchdog_proc.pid})")

        # 初始化固定数量的Worker
        self._init_workers()

        self.heartbeat.value = time.monotonic()
        last_memory_check = time.monotonic()

        while not self.stop_event.is_set():
            self.heartbeat.value = time.monotonic()

            if not self.quota_manager.can_stress():
                self.log('INFO', "Monthly quota exhausted, sending sleep tasks")
                for w in self.workers:
                    self._send_sleep_task(w, 1.0)
                self._interruptible_sleep(self.interval)
                continue

            if self.protect_k8s and self.k8s_checker:
                try:
                    if not self.k8s_checker.is_safe_to_stress():
                        self.log('WARN', "K8s node unhealthy, sending sleep tasks")
                        for w in self.workers:
                            self._send_sleep_task(w, 1.0)
                        self._interruptible_sleep(self.interval)
                        continue
                except K8sCheckError as e:
                    self.log('FATAL', f"K8s check failed: {e}")
                    self.log('FATAL', "Stopping all workers and exiting")
                    self._stop_all_workers()
                    sys.exit(1)

            if self.check_eviction and self.k8s_checker:
                try:
                    if self.k8s_checker.check_eviction_pressure():
                        self.log('WARN', "Eviction pressure detected, sending sleep tasks")
                        for w in self.workers:
                            self._send_sleep_task(w, 1.0)
                        self._interruptible_sleep(self.interval)
                        continue
                except K8sCheckError as e:
                    self.log('FATAL', f"Eviction check failed: {e}")
                    self.log('FATAL', "Stopping all workers and exiting")
                    self._stop_all_workers()
                    sys.exit(1)

            current = self.monitor.get_usage()
            if current is None:
                self.log('FATAL', "CPU monitor failed 3 times, exiting")
                self._stop_all_workers()
                sys.exit(1)

            # CPU异常时强制刷新K8s状态
            if current > 90 and self.k8s_checker:
                try:
                    self.k8s_checker.is_safe_to_stress(force_refresh=True)
                    self.k8s_checker.check_eviction_pressure(force_refresh=True)
                except K8sCheckError as e:
                    self.log('WARN', f"K8s emergency check failed: {e}")

            if self._pending_target_change != 0:
                old_target = self.target
                self.target = max(0, min(100, self.target + self._pending_target_change))
                self.log('INFO', f"Target adjusted: {old_target}% -> {self.target}%")
                # 重置积分项，防止目标变更后过冲
                self.integral_error = 0
                self._pending_target_change = 0

            # 紧急制动
            if current > 95:
                self.log('CRITICAL', f"CPU > 95% ({current:.1f}%), emergency sleep")
                for w in self.workers:
                    self._send_sleep_task(w, 1.0)
                self._interruptible_sleep(self.interval)
                continue

            # 根据CPU使用率调度任务密度
            self._schedule_tasks(current)

            if self.verbose:
                self.log('DEBUG', f"CPU: {current:.1f}%, Target: {self.target - self.k8s_reserve}%")

            self.quota_manager.record_stress(self.interval)

            now = time.monotonic()
            if now - last_memory_check >= 60:
                self._check_main_memory()
                last_memory_check = now

            # 每30秒输出一次状态摘要
            if not hasattr(self, '_last_status_log'):
                self._last_status_log = now
            if now - self._last_status_log >= 30:
                alive = sum(1 for w in self.workers if w['process'].is_alive())
                self.log('INFO', f"Status: CPU {current:.1f}%, Workers {alive}/{len(self.workers)}, "
                         f"Quota {self.quota_manager.get_usage_percent():.1f}%")
                self._last_status_log = now

            self._check_workers()
            self._interruptible_sleep(self.interval)

        self.log('INFO', "Daemon shutting down")
        self.stop()

    def stop(self):
        self._stop_all_workers()

        if hasattr(self, '_watchdog_proc') and self._watchdog_proc.is_alive():
            self._watchdog_proc.terminate()
            self._watchdog_proc.join(timeout=5)

        if self.quota_manager:
            try:
                self.quota_manager._save_state()
            except Exception:
                pass

        try:
            os.unlink(self.pid_file)
        except OSError:
            pass

        self._release_lock()

        if self.log_fh:
            try:
                self.log_fh.close()
            except Exception:
                pass

# ======================== Daemonize ========================
def daemonize():
    if os.fork() > 0:
        sys.exit(0)
    os.setsid()
    if os.fork() > 0:
        sys.exit(0)
    os.umask(0o022)
    sys.stdin = open(os.devnull, 'r')
    # 注意：stdout/stderr在守护进程模式下不重定向到/dev/null
    # 错误信息需要记录到日志文件，由log()方法处理

# ======================== CLI ========================
def parse_args():
    cpu_count = os.cpu_count() or 1
    default_max_workers = max(1, cpu_count // 2)

    parser = argparse.ArgumentParser(
        description='CPU Stress Daemon for K8s Worker Nodes',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--version', action='version', version=f'%(prog)s {VERSION}')

    basic = parser.add_argument_group('Basic')
    basic.add_argument('--target', type=int, default=40,
                       choices=range(0, 101), metavar='[0-100]',
                       help='Target CPU %% (default: 40, range: 0-100)')
    basic.add_argument('--interval', type=int, default=2,
                       help='Monitoring interval in seconds (default: 2)')
    basic.add_argument('--max-workers', type=int, default=None,
                       help=f'Max workers (default: cores/2={default_max_workers})')
    basic.add_argument('--state-dir', default='~/.cpu_stress/',
                       help='State files directory (default: ~/.cpu_stress/)')
    basic.add_argument('--log-file', default=None,
                       help='Log file path (default: stdout)')
    basic.add_argument('--verbose', action='store_true',
                       help='Verbose logging')
    basic.add_argument('--daemon', action='store_true',
                       help='Run as daemon in background')
    basic.add_argument('--dry-run', action='store_true',
                       help='Monitor only, do not start workers')

    quota = parser.add_argument_group('Monthly Quota')
    quota.add_argument('--quota', type=int, default=6,
                       choices=range(0, 101), metavar='[0-100]',
                       help='Monthly quota %% (default: 6, range: 0-100)')
    quota.add_argument('--quota-mode', choices=['daily', 'random', 'manual'],
                       default='daily',
                       help='Quota distribution mode (default: daily)')
    quota.add_argument('--quota-window', type=int, default=720,
                       help='Quota window in hours (default: 720=30 days)')

    k8s = parser.add_argument_group('K8s Protection')
    k8s.add_argument('--protect-k8s', action='store_true', default=True,
                     help='Enable K8s component protection (default: on)')
    k8s.add_argument('--no-protect-k8s', dest='protect_k8s',
                     action='store_false',
                     help='Disable K8s component protection')
    k8s.add_argument('--k8s-reserve', type=int, default=10,
                     help='CPU %% reserved for K8s components (default: 10)')
    k8s.add_argument('--check-eviction', action='store_true', default=True,
                     help='Check kubelet eviction thresholds (default: on)')
    k8s.add_argument('--no-check-eviction', dest='check_eviction',
                     action='store_false',
                     help='Disable eviction threshold checks')
    k8s.add_argument('--kubectl-timeout', type=int, default=30,
                     help='kubectl call timeout in seconds (default: 30)')
    k8s.add_argument('--eviction-margin', type=int, default=5,
                     help='Eviction safety margin %% (default: 5)')

    safety = parser.add_argument_group('Safety')
    safety.add_argument('--max-worker-lifetime', type=int, default=None,
                        help='Max worker lifetime in seconds (default: quota_window*3600/10)')
    safety.add_argument('--watchdog', action='store_true', default=True,
                        help='Enable watchdog process (default: on)')
    safety.add_argument('--no-watchdog', dest='watchdog', action='store_false',
                        help='Disable watchdog process')
    safety.add_argument('--watchdog-timeout', type=int, default=None,
                        help='Watchdog timeout in seconds (default: interval*10)')
    safety.add_argument('--mem-limit', type=int, default=256,
                        help='Per-worker memory limit in MB (default: 256)')
    safety.add_argument('--cpu-affinity', action='store_true', default=False,
                        help='Pin workers to specific CPU cores')

    args = parser.parse_args()

    if args.max_workers is None:
        args.max_workers = default_max_workers

    if args.max_worker_lifetime is None:
        args.max_worker_lifetime = max(3600, args.quota_window * 3600 // 10)

    if args.watchdog_timeout is None:
        args.watchdog_timeout = args.interval * 10

    if args.log_file is None and args.daemon:
        args.log_file = os.path.expanduser('~/.cpu_stress/log/cpu_stress.log')

    return args

# ======================== Main ========================
def main():
    try:
        args = parse_args()

        if args.daemon:
            if args.log_file:
                log_dir = os.path.dirname(args.log_file)
                if log_dir:
                    os.makedirs(log_dir, exist_ok=True)
            daemonize()

        daemon = CpuStressDaemon(args)
        daemon.run()
    except Exception as e:
        # 生产环境：遇到错误立即退出，记录到日志
        import traceback
        error_msg = f"FATAL ERROR: {e}\n{traceback.format_exc()}"
        print(error_msg, file=sys.stderr)
        # 尝试写入日志文件
        try:
            log_path = os.path.expanduser('~/.cpu_stress/log/cpu_stress.log')
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
            with open(log_path, 'a') as f:
                f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} [FATAL] {error_msg}\n")
        except Exception:
            pass
        sys.exit(1)

if __name__ == '__main__':
    main()
