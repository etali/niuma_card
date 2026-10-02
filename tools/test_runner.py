#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""完整回归入口：自动发现、独立用户数据、进程超时、取消清理和持久日志。"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

from test_runtime import cleanup_user_data
from project_paths import display_path, redact_paths, relative_path, sanitize_file

ROOT = Path(__file__).resolve().parents[1]
STATIC_CHECKS = ("check_card_table.py", "check_balance_numbers.py", "check_shell_utf8.py",
                 "check_launch_script.py", "check_doc_refs.py", "check_no_line_refs.py")


@dataclass
class Result:
    path: str
    kind: str
    status: str
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    reason: str = ""
    log: str = ""


def discover(root, pattern):
    files = sorted(p for p in (root / "tests").glob("test_*") if p.suffix in (".gd", ".py"))
    files += [root / "tools" / name for name in STATIC_CHECKS if (root / "tools" / name).is_file()]
    return [p for p in files if not pattern or pattern in p.relative_to(root).as_posix()]


def stop_process(process):
    # Godot/服务器/Node 都可能有子进程；只停当前测试的新进程组。
    # 工作台会创建自己的 session，进程组信号到不了它；在父进程退出前收集后代。
    descendants = []
    if process.poll() is None:
        listing = subprocess.check_output(["ps", "-ax", "-o", "pid=,ppid="], text=True)
        pairs = [tuple(map(int, line.split())) for line in listing.splitlines() if line.strip()]
        parents = {process.pid}
        while True:
            found = {pid for pid, parent in pairs if parent in parents and pid not in parents}
            if not found:
                break
            descendants.extend(found)
            parents.update(found)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in reversed(descendants):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            if not descendants:
                return
        except PermissionError:
            # macOS 对只剩 zombie 的进程组返回 EPERM，而不是 ESRCH。
            # 活着的组长仍须报错；后代已在上面逐个收到相同信号。
            if process.poll() is None:
                raise
        if sig == signal.SIGTERM:
            time.sleep(0.15)
    process.wait()


def parse_result(path, root, code, output, log):
    kind = "gd" if path.suffix == ".gd" else "python" if path.parent.name == "tests" else "check"
    result = Result(path.relative_to(root).as_posix(), kind, "failed", log=relative_path(log, root))
    if kind == "gd":
        match = re.findall(r"(\d+) 通过 / (\d+) 失败", output)
        if not match:
            result.reason = "没有测试汇总（编译失败或未跑完）"
            return result
        result.passed, result.failed = map(int, match[-1])
        if "SCRIPT ERROR" in output:
            result.reason = "运行时报错，断言数不可信"
            return result
    elif kind == "python":
        match = re.search(r"Ran (\d+) tests? in", output)
        if not match or int(match[1]) == 0:
            result.reason = "没有执行 Python 用例"
            return result
        total = int(match[1])
        failed = sum(int(n) for n in re.findall(r"(?:failures|errors|unexpected successes)=(\d+)", output))
        skipped = re.search(r"skipped=(\d+)", output)
        result.failed, result.skipped = failed, int(skipped[1]) if skipped else 0
        result.passed = max(0, total - result.failed - result.skipped)
    else:
        result.passed, result.failed = (1, 0) if code == 0 else (0, 1)
    if code != 0 or result.failed:
        result.reason = "退出码 %d" % code
    else:
        result.status = "passed"
    return result


def run_file(path, root, output_dir, env, timeout, cancelled, takeover_lock):
    log = output_dir / (path.relative_to(root).as_posix().replace("/", "__") + ".log")
    kind = "gd" if path.suffix == ".gd" else "python" if path.parent.name == "tests" else "check"
    relative = path.relative_to(root).as_posix()
    command = ([env["GODOT"], "--headless", "-s", relative] if kind == "gd" else
               [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", path.name, "-v"]
               if kind == "python" else [sys.executable, relative])
    locked = kind == "gd" and re.search(r"start_takeover|start_local_host_takeover", path.read_text())
    acquired = False
    process = None
    try:
        if locked:
            while not cancelled.is_set():
                if takeover_lock.acquire(timeout=0.1):
                    acquired = True
                    break
        if cancelled.is_set():
            return Result(relative, kind, "cancelled", reason="已取消", log=relative_path(log, root))
        with log.open("w", encoding="utf-8") as stream:
            process = subprocess.Popen(command, cwd=root, env=env, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if cancelled.wait(0.05) or time.monotonic() >= deadline:
                    stop_process(process)
                    reason = "已取消" if cancelled.is_set() else "超时（%g 秒）" % timeout
                    return Result(relative, kind, "cancelled" if cancelled.is_set() else "failed",
                                  reason=reason, log=relative_path(log, root))
            return parse_result(path, root, process.returncode, log.read_text(errors="replace"), log)
    except OSError as error:
        return Result(relative, kind, "failed", reason=redact_paths(str(error), root), log=relative_path(log, root))
    finally:
        if process is not None:
            # 正常退出后清理同一进程组残留；自行脱离 session 的后台服务必须
            # 由测试的 finally 管理。超时/取消时在组长存活期间收集后代并终止。
            stop_process(process)
        try:
            if log.is_file():
                # 清理必须读取原始路径；对外日志脱敏后不能再用它定位用户数据。
                raw = log.read_text(errors="replace")
                try:
                    for user_dir in re.findall(r"^CARD_TEST_USER_DIR=(.+)$", raw, re.M):
                        cleanup_user_data(user_dir)
                finally:
                    sanitize_file(log, root)
        finally:
            if acquired:
                takeover_lock.release()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("filter", nargs="?", default="")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("TEST_TIMEOUT", "180")))
    parser.add_argument("--jobs", type=int, default=int(os.environ.get("JOBS", min(8, os.cpu_count() or 1))))
    parser.add_argument("--log-dir", type=Path, help="日志与 JSON 报告目录（默认 build/test-results/时间戳）")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    files = discover(root, args.filter)
    if not files:
        parser.error("没有匹配的测试：" + (args.filter or "tests/test_*"))
    if args.jobs < 1 or args.timeout <= 0:
        parser.error("jobs 和 timeout 必须大于 0")
    real_godot = os.environ.get("GODOT") or shutil.which("godot") or "/Applications/Godot.app/Contents/MacOS/Godot"
    if Path(real_godot).parent == Path(os.environ.get("CARD_TEST_RUNTIME_ROOT", "/nonexistent")):
        real_godot = os.environ["CARD_TEST_REAL_GODOT"]
    if any(path.suffix == ".gd" for path in files) and not os.access(real_godot, os.X_OK):
        parser.error("找不到 Godot：" + display_path(real_godot, root))
    output_dir = (args.log_dir or root / "build/test-results" / (time.strftime("%Y%m%d-%H%M%S") + "-%d" % os.getpid())).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    print("测试日志：" + display_path(output_dir, root), flush=True)
    cancelled = threading.Event()
    received = []
    def on_signal(number, _frame):
        received.append(number)
        cancelled.set()
    previous = {sig: signal.signal(sig, on_signal) for sig in (signal.SIGINT, signal.SIGTERM)}
    results = []
    try:
        with tempfile.TemporaryDirectory(prefix="card-tests-") as temporary:
            runtime = Path(temporary)
            wrapper = runtime / "godot"
            wrapper.write_text("#!" + sys.executable + "\nimport runpy\nrunpy.run_path(" +
                               repr(str(Path(__file__).with_name("test_runtime.py"))) + ", run_name='__main__')\n")
            wrapper.chmod(0o755)
            env = dict(os.environ, GODOT=str(wrapper), CARD_TEST_REAL_GODOT=str(real_godot),
                       CARD_TEST_PROJECT_ROOT=str(root), CARD_TEST_RUNTIME_ROOT=str(runtime),
                       TEST_SPEED=os.environ.get("TEST_SPEED", "5"), PYTHONDONTWRITEBYTECODE="1")
            lock = threading.Lock()
            try:
                with ThreadPoolExecutor(max_workers=args.jobs) as pool:
                    futures = [pool.submit(run_file, path, root, output_dir, env, args.timeout, cancelled, lock) for path in files]
                    for future in as_completed(futures):
                        result = future.result()
                        results.append(result)
                        symbol = "✓" if result.status == "passed" else "✗"
                        print(f"  {symbol} {result.path}: {result.passed} 通过 / {result.failed} 失败 / {result.skipped} 跳过"
                              + (" — " + result.reason if result.reason else ""), flush=True)
                        if result.status != "passed":
                            print("    日志：" + result.log, flush=True)
                            if (root / result.log).is_file():
                                lines = (root / result.log).read_text(errors="replace").splitlines()
                                print("\n".join("    " + line for line in lines[-15:]), flush=True)
            finally:
                for record in runtime.glob("*.user.json"):
                    cleanup_user_data(json.loads(record.read_text()))
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    passed = sum(r.status == "passed" for r in results)
    report = {"files": len(files), "passed_files": passed, "failed_files": len(results) - passed,
              "results": [asdict(r) for r in sorted(results, key=lambda r: r.path)]}
    for kind, label in (("gd", "GDScript 断言"), ("python", "Python 用例"), ("check", "静态检查")):
        selected = [r for r in results if r.kind == kind]
        counts = {name: sum(getattr(r, name) for r in selected) for name in ("passed", "failed", "skipped")}
        report[kind] = counts
        print(f"{label}：{counts['passed']} 通过 / {counts['failed']} 失败 / {counts['skipped']} 跳过")
    (output_dir / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"文件：{passed} 通过 / {len(results)-passed} 失败；报告：{display_path(output_dir / 'results.json', root)}")
    return 128 + received[0] if received else 0 if passed == len(files) else 1


if __name__ == "__main__":
    sys.exit(main())
