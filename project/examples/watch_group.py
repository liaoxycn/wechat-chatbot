import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from wechat_sdk import WeChatClient


client = WeChatClient()
for event in client.watch("群名", sender=True):
    print(f"[{event.chat}] {event.message.sender}: {event.message.content}")
