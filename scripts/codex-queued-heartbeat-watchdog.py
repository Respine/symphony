#!/usr/bin/env python3
"""Queue a non-interrupting progress reminder at each session-local 30 minute boundary."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
from datetime import datetime
from urllib.request import urlopen
from urllib.error import URLError

INTERVAL_SECONDS = 30 * 60
POLL_SECONDS = 15
SERVICES = (4101, 4102, 4103, 4104)
STATE_DEFAULT = Path.home() / ".local/state/oh-my-symphony/codex-heartbeat.json"
LOCK_DEFAULT = Path.home() / ".local/state/oh-my-symphony/codex-heartbeat.lock"
MESSAGE = (
    "定时汇报提醒：继续手头工作，不要停止、暂停或等待，也不要因为本提醒中断正在执行的命令或长任务。"
    "请在本次工作合适的阶段更新 Linear Workpad，并追加一条中文 checkpoint，写明当前阶段、已完成、未完成、阻塞和下一步。"
)


def read_json(url: str) -> dict:
    with urlopen(url, timeout=3) as response:
        return json.load(response)


def active_workspaces() -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for port in SERVICES:
        try:
            state = read_json(f"http://127.0.0.1:{port}/api/v1/state")
        except (OSError, URLError, ValueError):
            continue
        for row in state.get("running") or []:
            issue = row.get("issue_identifier") or row.get("issue_id")
            if not issue:
                continue
            try:
                detail = read_json(f"http://127.0.0.1:{port}/api/v1/{issue}")
            except (OSError, URLError, ValueError):
                continue
            workspace = ((detail.get("workspace") or {}).get("path") or "").strip()
            if workspace:
                found.append((workspace, issue))
    return list(dict.fromkeys(found))


def session_meta(workspace: str) -> tuple[str, float] | None:
    best: tuple[float, str] | None = None
    root = Path.home() / ".codex/sessions"
    for path in root.glob("**/rollout-*.jsonl"):
        try:
            with path.open(encoding="utf-8") as stream:
                first = json.loads(stream.readline())
            if first.get("type") != "session_meta":
                continue
            payload = first.get("payload") or {}
            if os.path.realpath(payload.get("cwd", "")) != os.path.realpath(workspace):
                continue
            stamp = payload.get("timestamp") or first.get("timestamp")
            if not stamp:
                continue
            started = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
            thread_id = payload.get("session_id") or payload.get("id")
            if not thread_id:
                continue
            if best is None or started > best[0]:
                best = (started, thread_id)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    return None if best is None else (best[1], best[0])


def process_rows() -> list[tuple[int, int, str]]:
    result = subprocess.run(
        ["ps", "-eo", "pid=,ppid=,args="],
        check=False,
        capture_output=True,
        text=True,
    )
    rows: list[tuple[int, int, str]] = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
        except ValueError:
            pass
    return rows


def proc_link(pid: int, fd: str) -> str:
    try:
        path = f"/proc/{pid}/cwd" if fd == "cwd" else f"/proc/{pid}/fd/{fd}"
        return os.readlink(path)
    except OSError:
        return ""


def writable_fd(pid: int, target: str) -> str | None:
    try:
        entries = list(Path(f"/proc/{pid}/fd").iterdir())
    except OSError:
        return None
    for entry in entries:
        try:
            if os.readlink(entry) != target:
                continue
            info = Path(f"/proc/{pid}/fdinfo/{entry.name}").read_text()
            flags_text = info.split("flags:", 1)[1].splitlines()[0].strip()
            if int(flags_text, 8) & 0o3:
                return str(entry)
        except (OSError, ValueError, IndexError):
            continue
    return None


def app_server_writer(workspace: str) -> str | None:
    """Find the parent-owned writable stdin pipe for a Codex app-server.

    The parent can be Python Symphony or the official Elixir/OTP Symphony, so
    do not key this lookup to one orchestrator executable name.
    """
    rows = process_rows()
    app_servers = [
        pid
        for pid, _, args in rows
        if "app-server" in args
        and os.path.realpath(proc_link(pid, "cwd")) == os.path.realpath(workspace)
    ]
    for app_pid in app_servers:
        target = proc_link(app_pid, "0")
        if not target.startswith("pipe:["):
            continue
        for parent_pid, _, _ in rows:
            if parent_pid == app_pid:
                continue
            writer = writable_fd(parent_pid, target)
            if writer:
                return writer
    return None


def queue_message(thread_id: str, writer_path: str) -> None:
    payload = {
        "jsonrpc": "2.0",
        "id": f"watchdog-{uuid.uuid4()}",
        "method": "thread/queue/add",
        "params": {
            "threadId": thread_id,
            "clientUserMessageId": f"watchdog-{uuid.uuid4()}",
            "input": [{"type": "text", "text": MESSAGE}],
        },
    }
    data = (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    fd = os.open(writer_path, os.O_WRONLY)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def load_state(path: Path) -> dict[str, int]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return {str(key): int(bucket) for key, bucket in value.items()}
    except (OSError, ValueError, TypeError):
        return {}


def save_state(path: Path, state: dict[str, int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def run_once(state_path: Path, dry_run: bool = False) -> list[str]:
    state = load_state(state_path)
    now = time.time()
    actions: list[str] = []
    live_threads: set[str] = set()
    for workspace, issue in active_workspaces():
        meta = session_meta(workspace)
        if meta is None:
            actions.append(f"{issue}: no matching Codex session")
            continue
        thread_id, started = meta
        live_threads.add(thread_id)
        bucket = int(max(0.0, now - started) // INTERVAL_SECONDS)
        if bucket <= 0 or bucket <= state.get(thread_id, 0):
            continue
        writer = app_server_writer(workspace)
        if not writer:
            actions.append(f"{issue} {thread_id}: boundary {bucket} reached, app-server writer unavailable")
            continue
        if dry_run:
            actions.append(f"{issue} {thread_id}: would queue boundary {bucket}")
        else:
            queue_message(thread_id, writer)
            actions.append(f"{issue} {thread_id}: queued boundary {bucket}")
        state[thread_id] = bucket
    state = {thread: bucket for thread, bucket in state.items() if thread in live_threads}
    save_state(state_path, state)
    return actions


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--state", type=Path, default=STATE_DEFAULT)
    args = parser.parse_args()
    args.state.parent.mkdir(parents=True, exist_ok=True)
    with LOCK_DEFAULT.open("w") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("watchdog already running")
            return 0
        while True:
            try:
                for line in run_once(args.state, args.dry_run):
                    print(line, flush=True)
            except Exception as exc:
                print(f"watchdog error: {type(exc).__name__}: {exc}", flush=True)
            if args.once:
                return 0
            time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    raise SystemExit(main())
