#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""完整回归入口：自动发现、独立用户数据、进程超时、取消清理和持久日志。"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
import fcntl
import fnmatch
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
SUITES = {
    "gd": ("tests/test_*.gd",),
    "python": ("tests/test_*.py",),
    "static": ("tools/check_*.py",),
    "drawer": ("tests/test_drawer_*.gd",),
    "bot": ("tests/test_bot_*", "tests/test_think_clock.gd"),
    "network": ("tests/test_net_*.gd", "tests/test_protocol.gd", "tests/test_seat_map.gd",
                "tests/test_host_takeover.gd", "tests/test_embedded_host.gd",
                "tests/test_reconnect_door.gd", "tests/test_foe_offline.gd",
                "tests/test_lan_*.gd", "tests/test_rematch.gd"),
}


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


def discover(root, pattern, suites=()):
    files = sorted(p for p in (root / "tests").glob("test_*") if p.suffix in (".gd", ".py"))
    files += [root / "tools" / name for name in STATIC_CHECKS if (root / "tools" / name).is_file()]
    selected = [glob for suite in suites for glob in SUITES[suite]]
    return [p for p in files
            if (not pattern or pattern in p.relative_to(root).as_posix())
            and (not selected or any(fnmatch.fnmatchcase(p.relative_to(root).as_posix(), glob)
                                     for glob in selected))]


def file_kind(path):
    return "gd" if path.suffix == ".gd" else "python" if path.parent.name == "tests" else "check"


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
    kind = file_kind(path)
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
        matches = list(re.finditer(r"Ran (\d+) tests? in", output))
        match = matches[-1] if matches else None
        summary = output[match.end():] if match else ""
        skipped = re.search(r"skipped=(\d+)", summary)
        result.skipped = int(skipped[1]) if skipped else 0
        # setUpClass 抛 SkipTest 时 unittest 报 Ran 0 tests / OK(skipped=1)。
        # 它是有理由的整类跳过；真正没有发现用例仍应失败。
        if not match or (int(match[1]) == 0 and result.skipped == 0):
            result.reason = "没有执行 Python 用例"
            return result
        total = int(match[1])
        failed = sum(int(n) for n in re.findall(r"(?:failures|errors|unexpected successes)=(\d+)", summary))
        result.failed = failed
        # unittest 的类/模块准备跳过计入 skipped，却不计入 testsRun；普通方法跳过才应
        # 从 total 中扣除。verbose 输出保留了这两类跳过的公共名称。
        setup_skips = len(re.findall(r"^setUp(?:Class|Module) \(.+\) \.\.\. skipped ", output, re.M))
        method_skips = max(0, result.skipped - setup_skips)
        result.passed = max(0, total - result.failed - method_skips)
    else:
        result.passed, result.failed = (1, 0) if code == 0 else (0, 1)
    if code != 0 or result.failed:
        result.reason = "退出码 %d" % code
    else:
        result.status = "passed"
    return result


def run_process(command, root, env, log, timeout, cancelled):
    """导入与测试共用超时/取消/后代清理，避免前置阶段另走无界 subprocess.run。"""
    process = None
    try:
        with log.open("w", encoding="utf-8") as stream:
            process = subprocess.Popen(command, cwd=root, env=env, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if cancelled.wait(0.05) or time.monotonic() >= deadline:
                    return None, "已取消" if cancelled.is_set() else "超时（%g 秒）" % timeout
            return process.returncode, ""
    finally:
        if process is not None:
            stop_process(process)


def prepare_resources(root, output_dir, godot, timeout, cancelled):
    """并行读缓存前串行导入；与构建字体事务共用锁，补齐净克隆或已丢失的缓存。"""
    log = output_dir / "prepare_resources.log"
    result = Result("资源准备", "prepare", "failed", log=relative_path(log, root))
    deadline = time.monotonic() + timeout
    try:
        (root / "build").mkdir(exist_ok=True)
        (root / "build/.gdignore").touch()
        with (root / "build/.font-transaction.lock").open("a+b") as lock:
            while not cancelled.is_set():
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        result.reason = "等待资源导入锁超时（%g 秒）" % timeout
                        return result
                    cancelled.wait(0.05)
            if cancelled.is_set():
                result.status, result.reason = "cancelled", "已取消"
                return result
            command = [godot, "--headless", "--path", str(root), "--import",
                       "--log-file", str(output_dir / "prepare_engine.log")]
            code, reason = run_process(command, root, os.environ, log,
                                       max(0.01, deadline - time.monotonic()), cancelled)
            if reason:
                result.status = "cancelled" if cancelled.is_set() else "failed"
                result.reason = reason
            elif code != 0:
                result.reason = "退出码 %d" % code
            elif re.search(r"(?:^|\s)(?:SCRIPT ERROR|ERROR):", log.read_text(errors="replace")):
                result.reason = "Godot 导入报错"
            else:
                result.status = "passed"
    except OSError as error:
        result.reason = redact_paths(str(error), root)
    finally:
        if not log.exists():
            log.write_text(result.reason + "\n", encoding="utf-8")
        sanitize_file(log, root)
        engine_log = output_dir / "prepare_engine.log"
        if engine_log.is_file():
            sanitize_file(engine_log, root)
    return result


def run_file(path, root, output_dir, env, timeout, cancelled, takeover_lock):
    log = output_dir / (path.relative_to(root).as_posix().replace("/", "__") + ".log")
    kind = file_kind(path)
    relative = path.relative_to(root).as_posix()
    command = ([env["GODOT"], "--headless", "-s", relative] if kind == "gd" else
               [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", path.name, "-v"]
               if kind == "python" else [sys.executable, relative])
    locked = kind == "gd" and re.search(r"start_takeover|start_local_host_takeover", path.read_text())
    acquired = False
    try:
        if locked:
            while not cancelled.is_set():
                if takeover_lock.acquire(timeout=0.1):
                    acquired = True
                    break
        if cancelled.is_set():
            return Result(relative, kind, "cancelled", reason="已取消", log=relative_path(log, root))
        code, reason = run_process(command, root, env, log, timeout, cancelled)
        if reason:
            return Result(relative, kind, "cancelled" if cancelled.is_set() else "failed",
                          reason=reason, log=relative_path(log, root))
        return parse_result(path, root, code, log.read_text(errors="replace"), log)
    except OSError as error:
        return Result(relative, kind, "failed", reason=redact_paths(str(error), root), log=relative_path(log, root))
    finally:
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
    parser.add_argument("--suite", choices=SUITES, action="append", default=[],
                        help="按执行层或功能选择，可重复指定取并集，再与名称过滤取交集")
    parser.add_argument("--list", action="store_true", help="只列出选中的测试，不启动 Godot")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("TEST_TIMEOUT", "180")))
    parser.add_argument("--jobs", type=int, default=int(os.environ.get("JOBS", min(8, os.cpu_count() or 1))))
    parser.add_argument("--log-dir", type=Path, help="日志与 JSON 报告目录（默认 build/test-results/时间戳）")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    files = discover(root, args.filter, args.suite)
    if not files:
        parser.error("没有匹配的测试：" + (args.filter or "tests/test_*"))
    if args.jobs < 1 or args.timeout <= 0:
        parser.error("jobs 和 timeout 必须大于 0")
    if args.list:
        for path in files:
            print(path.relative_to(root).as_posix())
        return 0
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
    preparation = None
    try:
        if os.access(real_godot, os.X_OK) and any(file_kind(path) != "check" for path in files):
            print("准备 Godot 资源（串行导入）…", flush=True)
            preparation = prepare_resources(root, output_dir, real_godot, args.timeout, cancelled)
            if preparation.status != "passed":
                print("  ✗ 资源准备：" + preparation.reason + "；日志：" + preparation.log, flush=True)
        if preparation is None or preparation.status == "passed":
            results = run_selected(files, root, output_dir, real_godot, args, cancelled)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    passed = sum(r.status == "passed" for r in results)
    report = {"files": len(files), "passed_files": passed, "failed_files": len(results) - passed,
              "not_run_files": len(files) - len(results),
              "preparation": asdict(preparation) if preparation is not None else None,
              "results": [asdict(r) for r in sorted(results, key=lambda r: r.path)]}
    for kind, label in (("gd", "GDScript 断言"), ("python", "Python 用例"), ("check", "静态检查")):
        selected = [r for r in results if r.kind == kind]
        counts = {name: sum(getattr(r, name) for r in selected) for name in ("passed", "failed", "skipped")}
        report[kind] = counts
        print(f"{label}：{counts['passed']} 通过 / {counts['failed']} 失败 / {counts['skipped']} 跳过")
    (output_dir / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"文件：{passed} 通过 / {len(results)-passed} 失败 / {report['not_run_files']} 未运行；报告：{display_path(output_dir / 'results.json', root)}")
    return 128 + received[0] if received else 0 if passed == len(files) else 1


def run_selected(files, root, output_dir, real_godot, args, cancelled):
    results = []
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
    return results


if __name__ == "__main__":
    sys.exit(main())
