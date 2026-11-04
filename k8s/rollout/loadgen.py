"""Steady traffic against a Service, counting every failure. Project 12.

Runs inside the cluster (see loadgen.yaml), so it goes through the Service
the way another pod would, and nothing on the laptop is in the path.

Each request opens a new connection on purpose. A kept-alive connection
stays pinned to one pod, and a pod that is going away would only show up
when that connection breaks. A new connection per request asks the Service
for a pod every time, which is the question a rollout puts at risk.

Environment:
  TARGET       URL to request             (default http://api/version)
  DURATION     seconds to run              (default 60)
  CONCURRENCY  parallel clients            (default 4)
  BODY         JSON to POST instead of a GET (Project 15)

Project 15: when the response carries an x-build header (the commit that
served it), outcomes are also counted per build, which measures how much of
the traffic a canary received.
"""

import collections
import json
import os
import threading
import time
import urllib.error
import urllib.request

TARGET = os.getenv("TARGET", "http://api/version")
DURATION = float(os.getenv("DURATION", "60"))
CONCURRENCY = int(os.getenv("CONCURRENCY", "4"))
BODY = os.getenv("BODY", "").encode() or None

lock = threading.Lock()
per_second: dict[int, collections.Counter] = collections.defaultdict(collections.Counter)
first_errors: list[str] = []
by_build: collections.Counter = collections.Counter()
start = time.monotonic()


def outcome(exc: BaseException | None, status: int | None) -> str:
    if exc is None:
        return "ok" if status and status < 500 else f"http_{status}"
    if isinstance(exc, urllib.error.HTTPError):
        return f"http_{exc.code}"
    reason = getattr(exc, "reason", exc)
    return type(reason).__name__


def client() -> None:
    while (now := time.monotonic() - start) < DURATION:
        exc, status, build = None, None, None
        request = urllib.request.Request(
            TARGET, data=BODY, headers={"content-type": "application/json"} if BODY else {}
        )
        try:
            with urllib.request.urlopen(request, timeout=3) as resp:
                resp.read()
                status = resp.status
                build = resp.headers.get("x-build")
        except Exception as e:  # noqa: BLE001 - every failure is data here
            exc = e
            build = getattr(e, "headers", None) and e.headers.get("x-build")
        result = outcome(exc, status)
        with lock:
            per_second[int(now)][result] += 1
            if build:
                # A commit SHA is shortened; a suffix ("-v2", "-bad") is kept,
                # so builds of the same commit stay apart.
                sha, _, suffix = build.partition("-")
                by_build[(sha[:7] + (f"-{suffix}" if suffix else ""), result)] += 1
            if result != "ok" and len(first_errors) < 10:
                first_errors.append(f"t={now:6.2f}s {result}: {exc}")


threads = [threading.Thread(target=client) for _ in range(CONCURRENCY)]
for t in threads:
    t.start()
for t in threads:
    t.join()

total: collections.Counter = collections.Counter()
for second in sorted(per_second):
    counts = per_second[second]
    total.update(counts)
    failed = {k: v for k, v in counts.items() if k != "ok"}
    if failed:
        print(f"t={second:3d}s ok={counts['ok']:4d} failed={failed}")

print("\n".join(first_errors))
requests = sum(total.values())
print(
    json.dumps(
        {
            "target": TARGET,
            "seconds": DURATION,
            "concurrency": CONCURRENCY,
            "requests": requests,
            "failed": requests - total["ok"],
            "outcomes": dict(total),
            "by_build": {f"{b} {r}": n for (b, r), n in sorted(by_build.items())},
        }
    )
)
