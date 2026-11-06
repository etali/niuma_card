# SPDX-License-Identifier: AGPL-3.0-only
"""Local workbench lifecycle, shared by both game modes."""
import fcntl
import hashlib
import http.client
import json
import os
import shutil
import signal
import subprocess
import threading
import time

from .storage import read_json


class PageSessions:
    """Track browser connections, not background-tab JavaScript timers."""
    def __init__(self, server, transient=False):
        self.server = server
        self.lock = threading.Lock()
        self.pages = 0
        self.transient = transient
        self.idle_after = time.monotonic() + 60  # also retire a failed browser launch
        self.ended = threading.Event()

    def touch(self):
        # A CLI-started worker has no owning terminal. Keep it available for
        # result polling, then let it expire when both engines are idle.
        if self.transient:
            with self.lock:
                if not self.pages: self.idle_after = time.monotonic() + 60

    def stream(self, handler):
        with self.lock:
            self.pages += 1
            self.idle_after = None
        try:
            handler.send_response(200)
            handler.send_header('Content-Type', 'text/event-stream')
            handler.send_header('Cache-Control', 'no-store')
            handler.end_headers()
            while not self.ended.is_set():
                handler.wfile.write(b': open\n\n')
                handler.wfile.flush()
                self.ended.wait(2)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        finally:
            with self.lock:
                self.pages -= 1
                if self.pages == 0:
                    self.idle_after = time.monotonic() + 5  # allow navigation/reload

    def stop_if_idle(self, last_page=False):
        server = self.server
        with self.lock:
            if last_page and (self.idle_after is None or time.monotonic() < self.idle_after):
                return False
            # Lock admission on both engines; a concurrent submit either already
            # owns a job (keep serving) or will see closing and cannot start.
            with server.app.lock, server.lock:
                if server.app.jobs or any(job['meta']['status'] == 'running' for job in server.jobs.values()):
                    return False
                if not self.ended.is_set():
                    server.app.closing = server.closing = True
                    self.ended.set()
                    threading.Thread(target=server.shutdown, daemon=True).start()
            return True


def request(port, path, method='GET', token=''):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
    try:
        headers = {'Content-Type': 'application/json', 'X-Balance-Token': token}
        connection.request(method, path, body='{}' if method == 'POST' else None, headers=headers)
        response = connection.getresponse()
        if response.status == 409:
            raise ValueError('工作台有实验正在运行；等实验完成后重试，或在工作台停止对应实验')
        if response.status != 200:
            raise ValueError('此端口的服务未提供所需的工作台接口')
        return json.load(response)
    finally:
        connection.close()


def store_key(path):
    return hashlib.sha256(os.fsencode(path)).hexdigest()


def _verified_legacy_pid(port, pid, lock_paths):
    # Legacy servers have no authenticated shutdown route. Never signal a PID
    # from JSON alone: match the OS listener and both of this store's files.
    tool = shutil.which('lsof')
    if not tool or type(pid) is not int or pid <= 1: return False
    def fields(args):
        result = subprocess.run([tool, '-nP', *args], capture_output=True, text=True, timeout=5)
        return set(result.stdout.splitlines()) if result.returncode == 0 else set()
    listening = fields(['-iTCP@127.0.0.1:%d' % port, '-sTCP:LISTEN', '-Fp'])
    opened = fields(['-p', str(pid), '-Fn'])
    return {item for item in listening if item.startswith('p')} == {'p' + str(pid)} and all('n' + str(path) in opened for path in lock_paths)


def _stores_free(lock_paths):
    for path in lock_paths:
        if not path.is_file(): continue
        with path.open('a+') as lock:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: return False
    return True


def resolve_listener(port, version, same_project, on_work_store, off_work_store, stop):
    """Return 'reuse', 'start' or 'stopped'. Caller holds the startup lock."""
    lock_paths = [on_work_store / 'server.lock', off_work_store / '.service.lock']
    address_file = off_work_store / 'service.json'
    try:
        health = request(port, '/api/health')
    except ConnectionRefusedError:
        if stop and address_file.is_file() and _stores_free(lock_paths):
            marker = read_json(address_file)
            if isinstance(marker, dict) and marker.get('url') == f'http://127.0.0.1:{port}/off-work/':
                address_file.unlink(missing_ok=True)
        return 'stopped' if stop else 'start'
    except (OSError, ValueError, http.client.HTTPException) as exc:
        raise ValueError('端口 %d 被其他服务占用或未响应，请选择其他端口' % port) from exc
    if not isinstance(health, dict) or health.get('app') != 'manual-balance-v1' or not same_project(health.get('project')):
        raise ValueError('端口 %d 已由其他项目或服务使用' % port)
    try:
        marker = read_json(off_work_store / 'service.json')
    except (OSError, ValueError):
        marker = {}
    pid = health.get('pid')
    if (not isinstance(marker, dict) or marker.get('pid') != pid or marker.get('url') != f'http://127.0.0.1:{port}/off-work/'
            or marker.get('on_work_store_key', store_key(on_work_store)) != store_key(on_work_store)
            or marker.get('off_work_store_key', store_key(off_work_store)) != store_key(off_work_store)):
        raise ValueError('端口 %d 的工作台使用另一份数据目录' % port)
    if not health.get('closing') and not stop and health.get('source_version') == version:
        return 'reuse'
    if health.get('closing'):
        pass  # retiring between health check and relaunch
    elif health.get('lifecycle') == 1 and marker.get('control_token'):
        request(port, '/api/shutdown', 'POST', marker['control_token'])
    else:
        # For an already-running release from before the shutdown endpoint.
        # Both history interfaces must positively establish that it is idle.
        if not _verified_legacy_pid(port, pid, lock_paths):
            raise ValueError('无法确认旧进程持有此工作台的端口和数据锁，已保留现场')
        active = request(port, '/api/runs').get('active_run_ids')
        jobs = request(port, '/off-work/api/history').get('items')
        if active != [] or not isinstance(jobs, list) or not all(
                job.get('status') in ('done', 'error', 'cancelled', 'interrupted') for job in jobs):
            raise ValueError('旧工作台有未完成的实验；请等待实验完成后再重启')
        if not _verified_legacy_pid(port, pid, lock_paths):
            raise ValueError('旧服务在检查期间已更换；请重新启动工作台')
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    until = time.monotonic() + 10
    while time.monotonic() < until:
        if _stores_free(lock_paths):
            try: request(port, '/api/health')
            except ConnectionRefusedError: return 'stopped' if stop else 'start'
        time.sleep(.05)
    raise ValueError('旧工作台正在退出，尚未释放端口或数据锁，请稍后重试')
