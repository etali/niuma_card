#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""提交卡牌平衡实验或 BOT PK 到本机工作台，输出一行 JSON。"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.balance.off_work_workbench import DEFAULT_OPTIONS, REPORTS, ROOT, canonical_kind
from tools.balance.storage import read_json


class JobError(Exception):
    def __init__(self, payload):
        super().__init__(payload.get("error", "工作台请求失败"))
        self.payload = payload


def service_url(address):
    url = urlsplit(address)
    if (url.scheme != "http" or url.hostname not in ("localhost", "127.0.0.1") or
            not url.port or url.username is not None or url.password is not None or
            url.path.rstrip("/") not in ("", "/off-work") or url.query or url.fragment):
        raise ValueError("--url 须为本机工作台地址，例如 http://127.0.0.1:29861/off-work/")
    return f"http://127.0.0.1:{url.port}/off-work"


def api(url, path, body=None):
    data = json.dumps(body, ensure_ascii=False, allow_nan=False).encode() if body is not None else None
    req = Request(url + path, data=data, headers={"Content-Type": "application/json"})
    try:
        with urlopen(req, timeout=30) as response:
            return json.load(response)
    except HTTPError as exc:
        message = exc.read().decode(errors="replace")
        try:
            details = json.loads(message)
        except ValueError:
            details = {"error": message}
        raise JobError({**details, "http_status": exc.code}) from exc


def service_record():
    try:
        return read_json(REPORTS / "service.json")
    except FileNotFoundError:
        return {}


def running_service(record, version, project):
    if not record: return None
    address = service_url(record["url"])
    try:
        health = api(address.removesuffix("/off-work"), "/api/health")
        if (health.get("app") == "manual-balance-v1" and health.get("project") == project
                and health.get("source_version") == version and health.get("pid") == record.get("pid")):
            return address
    except (ConnectionError, URLError, JobError):
        pass
    return None


def connect(address):
    if address is not None:
        return service_url(address)
    from tools.manual_balance import project_id, source_version
    version, project = source_version(), project_id()
    record = service_record()
    service = running_service(record, version, project)
    if service is not None:
        return service
    port = urlsplit(service_url(record["url"])).port if record else 29861
    REPORTS.mkdir(parents=True, exist_ok=True)
    log_path = REPORTS / "server-startup.log"
    with log_path.open("ab") as log:
        process = subprocess.Popen([sys.executable, str(ROOT / "tools/manual_balance.py"), "--reuse",
                                    "--off-work", "--port", str(port)], cwd=ROOT,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        service = running_service(service_record(), version, project)
        if service is not None:
            return service
        if process.poll() not in (None, 0):
            raise ValueError(f"工作台启动失败（退出码 {process.returncode}），请查看 {log_path}")
        time.sleep(0.2)
    raise ValueError(f"等待工作台启动超时，请查看 {log_path}")


def load_document(path, kind):
    data = read_json(path)
    # Also accept the immutable config snapshot referenced by a previous CLI run.
    if isinstance(data, dict) and canonical_kind(data.get("kind")) == kind and "data" in data:
        data = data["data"]
    if not isinstance(data, dict):
        raise ValueError(f"{path} 应包含 JSON 对象")
    return data


def existing_path(path):
    return str(path) if path.is_file() else None


def submit(args):
    cards = load_document(args.cards, "cards")
    supplied = {side: load_document(path, "bot") for side, path in (("a", args.a), ("b", args.b)) if path}
    url = connect(args.url)
    label = "BOT PK" if args.kind == "bot" else "卡牌评估"
    body = {"kind": args.kind, "label": label, "card_name": args.name, "cards": cards,
            "a_name": f"A · {args.a.stem}" if args.a else "策略 A", "b_name": f"B · {args.b.stem}" if args.b else "策略 B",
            "seed": args.seed, "pairs": args.pairs, "max_seconds": args.max_seconds, **supplied}
    submitted = api(url, "/api/run", body)
    key = submitted["id"]
    job_path = "/api/jobs/" + key
    folder = REPORTS / key
    cards_id = submitted["configs"]["cards"]
    # An explicit --url may point at an isolated store with an identical card
    # snapshot. Only advertise local files if this job actually lives here.
    local_request = existing_path(folder / "request.json")
    output = {**submitted, "kind": args.kind, "url": url, "job_url": url + job_path,
              "experiment_url": url + "/?" + urlencode({"run": key, "cards": cards_id}),
              "cards_url": url + "/api/library/" + cards_id,
              "request_path": local_request,
              "cards_snapshot_path": existing_path(REPORTS / "configs" / (cards_id + ".json")) if local_request else None}
    if args.no_wait:
        return {**output, "status": "submitted"}
    try:
        while True:
            job = api(url, job_path)
            if job["status"] != "running":
                break
            time.sleep(0.5)
    except (URLError, OSError, JobError, KeyboardInterrupt) as exc:
        raise JobError({**output, "error": f"查询实验已中断，可用 job_url 查询进度。{exc}"}) from exc
    output.update(status=job["status"], result_path=existing_path(folder / "result.json"))
    if job["status"] != "done":
        raise JobError({**output, "error": job.get("error") or "实验已取消"})
    return {**output, **job["summary"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", type=canonical_kind, choices=("balance", "bot"), default="balance", help="卡牌评估 balance（默认）或 BOT PK bot")
    parser.add_argument("--cards", required=True, type=Path, help="完整 cards.json 或卡表库快照")
    parser.add_argument("--name", required=True, help="保存到工作台卡表库的名称")
    parser.add_argument("--seed", type=int, default=DEFAULT_OPTIONS["seed"], help="起始种子（默认 1001）")
    parser.add_argument("--pairs", type=int, default=DEFAULT_OPTIONS["pairs"], help="种子对数（默认 3，每对交换座位）")
    parser.add_argument("--max-seconds", type=float, default=DEFAULT_OPTIONS["max_seconds"], help="每局虚拟游戏时限（默认 600 游戏秒）")
    parser.add_argument("--a", type=Path, help="A 的策略 JSON 或库快照，默认使用网页标准强度")
    parser.add_argument("--b", type=Path, help="B 的策略 JSON 或库快照，卡牌评估默认双方同策略，BOT PK 默认偏低强度")
    parser.add_argument("--url", help="运行中的本机工作台地址，省略时自动发现或启动")
    parser.add_argument("--no-wait", action="store_true", help="取得实验 ID 后立即返回")
    try:
        record = submit(parser.parse_args())
    except (OSError, ValueError, KeyError, JobError) as exc:
        details = exc.payload if isinstance(exc, JobError) else {"error": str(exc)}
        print(json.dumps(details, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(record, ensure_ascii=False, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
