"""
CPU Stress Worker进程
固定数量Worker，通过占空比控制CPU占用率
支持连续休眠时长调节，实现平滑控制
"""
import math
import hashlib
import os
import resource
import signal
import time


def stress_work(task_queue, stop_event, main_pid, mem_limit_mb, worker_id):
    """Worker进程：固定数量，根据队列指令控制CPU占用"""
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)

    # 设置内存限制
    mem_limit_bytes = mem_limit_mb * 1024 * 1024
    try:
        resource.setrlimit(resource.RLIMIT_AS, (mem_limit_bytes, mem_limit_bytes))
    except (ValueError, resource.error):
        pass

    # 计算时长固定，休眠时长动态调节
    COMPUTE_DURATION = 0.5  # 每次计算0.5秒
    current_sleep = 0.5     # 当前休眠时长（默认50%占空比）

    while not stop_event.is_set():
        try:
            # 执行密集计算
            deadline = time.monotonic() + COMPUTE_DURATION
            while time.monotonic() < deadline and not stop_event.is_set():
                x = 0.0
                for i in range(10000):
                    x += math.sin(i) * math.cos(i) * math.sqrt(abs(i) + 1)
                data = str(x).encode()
                hashlib.sha256(data).digest()
                hashlib.md5(data).digest()

            # 检查队列指令（非阻塞），更新休眠时长
            try:
                task = task_queue.get_nowait()
                if task is None:  # 哨兵值，退出
                    break
                if task.get('type') == 'sleep':
                    current_sleep = task.get('duration', current_sleep)
                    time.sleep(current_sleep)
                    continue
            except Exception:
                pass

            # 使用当前休眠时长
            time.sleep(current_sleep)

        except Exception:
            pass
