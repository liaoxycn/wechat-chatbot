# Python SDK

将 `scripts/` 加入 Python 路径后导入 `wechat_sdk`。

```python
from wechat_sdk import WeChatClient

client = WeChatClient()
messages = client.read('群名', limit=20, sender=True)
client.send('群名', '消息内容')
```

持续监听当前已加载的群消息：

```python
for event in client.watch('群名', sender=True, interval=2):
    print(event.message.sender, event.message.content)
```

首次快照默认不产生事件。传入 `emit_existing=True` 可回放它。使用 `start_watch` 以回调方式在后台监听，返回的句柄调用 `stop()` 停止。监听通过轮询微信当前界面实现，不自动翻页，默认会在短暂 UI 错误后重试；传入 `retry_errors=False` 可立即抛出错误。
