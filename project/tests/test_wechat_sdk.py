import threading
import unittest
from unittest.mock import patch
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
from wechat_sdk import Message, WeChatClient


def message(content: str) -> Message:
    return Message(None, None, None, "text", content, None)


class ScriptedClient(WeChatClient):
    def __init__(self, snapshots: list[list[Message]], stop_event: threading.Event) -> None:
        self._snapshots = iter(snapshots)
        self._stop_event = stop_event

    def read(self, *args, **kwargs):
        snapshot = next(self._snapshots)
        if snapshot[-1].content == "new":
            self._stop_event.set()
        return snapshot


class WeChatSdkTest(unittest.TestCase):
    def test_client_prefers_pwsh_when_available(self):
        with patch("wechat_sdk.shutil.which", return_value="C:/Program Files/PowerShell/pwsh.exe"):
            client = WeChatClient()
        self.assertEqual(client.powershell, "C:/Program Files/PowerShell/pwsh.exe")

    def test_overlap_detects_appended_messages(self):
        self.assertEqual(WeChatClient._overlap([message("a"), message("b")], [message("b"), message("c")]), 1)

    def test_watch_ignores_initial_snapshot_and_yields_new_message(self):
        stop_event = threading.Event()
        client = ScriptedClient([[message("old")], [message("old"), message("new")]], stop_event)
        events = list(client.watch("group", interval=0.01, stop_event=stop_event))
        self.assertEqual([event.message.content for event in events], ["new"])


if __name__ == "__main__":
    unittest.main()
