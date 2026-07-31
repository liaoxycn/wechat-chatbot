"""Watch new messages in the AI大数据开发 group."""

from __future__ import annotations

import argparse
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from wechat_sdk import WeChatClient, WeChatError


CHAT_NAME = "AI大数据开发"


def main() -> int:
    parser = argparse.ArgumentParser(description=f"Watch new messages in {CHAT_NAME}")
    parser.add_argument("--interval", type=float, default=2, help="poll interval in seconds")
    parser.add_argument("--limit", type=int, default=50, help="number of visible messages to compare")
    parser.add_argument("--sender", action="store_true", help="run sender OCR/cache lookup")
    parser.add_argument("--existing", action="store_true", help="emit the initial visible messages")
    parser.add_argument("--duration", type=float, default=0, help="stop after this many seconds; 0 means forever")
    args = parser.parse_args()

    client = WeChatClient()
    stop_event = threading.Event()
    if args.duration > 0:
        threading.Timer(args.duration, stop_event.set).start()
    print(f"监听群：{CHAT_NAME}，间隔：{args.interval:g}s", flush=True)
    try:
        for event in client.watch(
            CHAT_NAME,
            interval=args.interval,
            limit=args.limit,
            sender=args.sender,
            emit_existing=args.existing,
            stop_event=stop_event,
        ):
            message = event.message
            sender = message.sender or "未知发送者"
            print(f"[{sender}] {message.type}: {message.content}", flush=True)
    except KeyboardInterrupt:
        print("监听已停止。", flush=True)
    except WeChatError as exc:
        print(f"微信操作失败：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
