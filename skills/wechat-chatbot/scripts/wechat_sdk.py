"""Python SDK for the local WeChat UI Automation CLI."""

from __future__ import annotations

import json
import shutil
import subprocess
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class WeChatError(RuntimeError):
    """Raised when the PowerShell automation CLI cannot complete a command."""


@dataclass(frozen=True)
class Message:
    sender: str | None
    sender_confidence: float | None
    sender_id: str | None
    type: str
    content: str
    media_path: str | None

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "Message":
        return cls(
            sender=value.get("sender"),
            sender_confidence=value.get("senderConfidence"),
            sender_id=value.get("senderId"),
            type=value.get("type", "text"),
            content=value.get("content", ""),
            media_path=value.get("mediaPath"),
        )

    @property
    def key(self) -> tuple[str | None, str, str, str | None]:
        return self.sender_id, self.type, self.content, self.media_path


@dataclass(frozen=True)
class MessageEvent:
    chat: str
    message: Message


class WatchHandle:
    def __init__(self, thread: threading.Thread, stop_event: threading.Event) -> None:
        self._thread = thread
        self._stop_event = stop_event

    def stop(self, timeout: float | None = None) -> None:
        self._stop_event.set()
        self._thread.join(timeout)

    @property
    def is_running(self) -> bool:
        return self._thread.is_alive()


class WeChatClient:
    """Programmatic wrapper around ``wechat-cli.ps1``."""

    def __init__(
        self,
        cli_path: str | Path | None = None,
        *,
        powershell: str | None = None,
        timeout: float = 30,
    ) -> None:
        self.cli_path = Path(cli_path) if cli_path else Path(__file__).with_name("wechat-cli.ps1")
        self.powershell = powershell or shutil.which("pwsh") or "powershell"
        self.timeout = timeout

    def open(self) -> str:
        return self._run("open").strip()

    def select(self, chat: str, *, exact: bool = False) -> str:
        arguments = [chat]
        if exact:
            arguments.append("-Exact")
        return self._run("select", *arguments).strip()

    def read(
        self,
        chat: str | None = None,
        *,
        limit: int = 20,
        sender: bool = False,
        ocr: bool = False,
        no_sender_cache: bool = False,
    ) -> list[Message]:
        if sender and ocr:
            raise ValueError("sender and ocr cannot both be enabled")
        arguments: list[str] = []
        if chat is not None:
            arguments.append(chat)
        arguments.extend(["-Limit", str(limit), "-Json"])
        if sender:
            arguments.append("-Sender")
        elif ocr:
            arguments.append("-Ocr")
        elif no_sender_cache:
            arguments.append("-NoSenderCache")
        payload = self._run("read", *arguments)
        decoded = json.loads(payload) if payload.strip() else []
        return [Message.from_dict(item) for item in self._as_list(decoded)]

    def send(self, chat: str, text: str, *, exact: bool = False) -> None:
        arguments = [chat, text]
        if exact:
            arguments.append("-Exact")
        self._run("send", *arguments)

    def watch(
        self,
        chat: str,
        *,
        interval: float = 2,
        limit: int = 50,
        sender: bool = False,
        emit_existing: bool = False,
        retry_errors: bool = True,
        stop_event: threading.Event | None = None,
    ) -> Iterator[MessageEvent]:
        """Yield only messages appended after the previous successful poll."""
        if interval <= 0:
            raise ValueError("interval must be greater than zero")
        stopper = stop_event or threading.Event()
        previous: list[Message] | None = None
        while not stopper.is_set():
            try:
                current = self.read(chat, limit=limit, sender=sender, no_sender_cache=not sender)
            except WeChatError:
                if not retry_errors:
                    raise
                stopper.wait(interval)
                continue
            if previous is None:
                new_messages = current if emit_existing else []
            else:
                new_messages = current[self._overlap(previous, current) :]
            for message in new_messages:
                yield MessageEvent(chat=chat, message=message)
            previous = current
            stopper.wait(interval)

    def start_watch(
        self,
        chat: str,
        callback: Callable[[MessageEvent], None],
        **watch_options: Any,
    ) -> WatchHandle:
        stop_event = threading.Event()

        def run() -> None:
            for event in self.watch(chat, stop_event=stop_event, **watch_options):
                callback(event)

        thread = threading.Thread(target=run, name=f"wechat-watch:{chat}", daemon=True)
        thread.start()
        return WatchHandle(thread, stop_event)

    def _run(self, command: str, *arguments: str) -> str:
        if not self.cli_path.is_file():
            raise WeChatError(f"WeChat CLI not found: {self.cli_path}")
        process = subprocess.run(
            [self.powershell, "-NoProfile", "-File", str(self.cli_path), command, *arguments],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=self.timeout,
            check=False,
        )
        if process.returncode != 0:
            details = process.stderr.strip() or process.stdout.strip()
            raise WeChatError(details or f"WeChat command failed: {command}")
        return process.stdout

    @staticmethod
    def _as_list(value: Any) -> list[dict[str, Any]]:
        if isinstance(value, dict):
            return [value]
        if isinstance(value, list):
            return value
        raise WeChatError("Unexpected JSON returned by WeChat CLI")

    @staticmethod
    def _overlap(previous: list[Message], current: list[Message]) -> int:
        maximum = min(len(previous), len(current))
        for size in range(maximum, 0, -1):
            if [item.key for item in previous[-size:]] == [item.key for item in current[:size]]:
                return size
        return 0


__all__ = ["Message", "MessageEvent", "WatchHandle", "WeChatClient", "WeChatError"]
