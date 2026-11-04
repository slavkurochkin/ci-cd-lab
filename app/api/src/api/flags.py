"""Feature flags read from a file at request time. Project 15.

The file is a JSON object of flag name to true/false, mounted from a
ConfigMap. Kubernetes rewrites a mounted ConfigMap in place when it changes,
so flipping a flag needs no new image, no new pod and no restart: the next
request after the kubelet syncs the file sees the new value.

Anything that is not exactly `true` is off. A missing file means every flag
is off, and a file that fails to parse keeps the last good values, so a typo
in the ConfigMap cannot switch every feature off at once.
"""

import json
import os
from pathlib import Path

DEFAULT_PATH = "/etc/flags/flags.json"


class Flags:
    def __init__(self, path: str | None = None) -> None:
        resolved: str = path or os.environ.get("FLAGS_FILE") or DEFAULT_PATH
        self.path = Path(resolved)
        self._mtime: float | None = None
        self._values: dict[str, bool] = {}

    def enabled(self, name: str) -> bool:
        try:
            mtime = self.path.stat().st_mtime
        except FileNotFoundError:
            self._mtime, self._values = None, {}
            return False
        if mtime != self._mtime:
            try:
                data = json.loads(self.path.read_text())
            except (OSError, ValueError):
                return self._values.get(name, False)
            values = data if isinstance(data, dict) else {}
            self._values = {key: value is True for key, value in values.items()}
            self._mtime = mtime
        return self._values.get(name, False)
