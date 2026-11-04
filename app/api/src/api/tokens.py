"""Admin tokens read from a mounted Secret at request time. Project 17.

External Secrets copies the tokens from SSM Parameter Store into a Kubernetes
Secret, and the Secret is mounted as a file. The kubelet rewrites a mounted
Secret in place when it changes, so a rotated token reaches the running
process with no restart and no rollout. An environment variable would not:
it is read once, when the container starts (Project 11 needed Reloader to
restart the pods for that reason).

One token per line. More than one line is how a rotation avoids an outage:
add the new token, move the clients to it, then remove the old one.

No file means no admin endpoint: every check fails, and the route answers
404 as if it did not exist.
"""

import hmac
import os
from pathlib import Path

DEFAULT_PATH = "/etc/admin/tokens"


class Tokens:
    def __init__(self, path: str | None = None) -> None:
        resolved: str = path or os.environ.get("ADMIN_TOKENS_FILE") or DEFAULT_PATH
        self.path = Path(resolved)
        self._mtime: float | None = None
        self._tokens: list[str] = []

    def configured(self) -> bool:
        return bool(self._current())

    def valid(self, presented: str) -> bool:
        # compare_digest on each, never `in`: a plain comparison returns at
        # the first differing byte, and the time it takes leaks how much of a
        # guess was right.
        matches = [hmac.compare_digest(presented.encode(), t.encode()) for t in self._current()]
        return any(matches)

    def _current(self) -> list[str]:
        try:
            mtime = self.path.stat().st_mtime
        except FileNotFoundError:
            self._mtime, self._tokens = None, []
            return []
        if mtime != self._mtime:
            lines = self.path.read_text().splitlines()
            self._tokens = [line.strip() for line in lines if line.strip()]
            self._mtime = mtime
        return self._tokens
