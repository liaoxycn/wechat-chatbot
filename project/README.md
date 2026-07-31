# 微信聊天机器人

Windows 微信桌面版的本地自动化 CLI。通过 UI Automation 操作界面，不读取微信数据库。

## 结构

```text
scripts/   CLI、OCR 助手、环境初始化和依赖清单
data/      运行时昵称缓存与导出媒体
```

## 初始化

```powershell
.\scripts\setup.ps1
```

## 用法

```powershell
.\scripts\wechat-cli.ps1 open
.\scripts\wechat-cli.ps1 select '群名'
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json -Sender
.\scripts\wechat-cli.ps1 send '群名' '消息内容'
```

`-Sender` 仅为缓存中不存在的头像执行 OCR，并写入 `data/sender-cache.json`。`-NoSenderCache` 跳过头像识别，适合只读取文本与消息类型。图片和表情导出至 `data/media/`。

## Python SDK

```python
from scripts.wechat_sdk import WeChatClient

client = WeChatClient()
messages = client.read('群名', limit=20, sender=True)
client.send('群名', '消息内容')

for event in client.watch('群名', sender=True, interval=2):
    print(event.message.sender, event.message.content)
```

`watch` 通过轮询当前已加载的消息列表产生增量事件，不自动翻页。首次快照默认不回放；传入 `emit_existing=True` 可回放。调用 `start_watch` 可在后台线程监听，返回句柄调用 `stop()` 停止。监听默认会在短暂 UI 错误后重试；传入 `retry_errors=False` 可立即抛出错误。
