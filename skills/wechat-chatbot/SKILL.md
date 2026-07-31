---
name: wechat-chatbot
description: Operate the logged-in Windows WeChat desktop client with local UI Automation. Use for reading, summarizing, monitoring, drafting, or sending messages in WeChat chats and groups.
---

# 微信聊天机器人

使用 `scripts/wechat-cli.ps1` 操作已登录的 Windows 微信桌面版，不读取微信数据库。

首次使用昵称识别、OCR 或媒体导出前，执行：

```powershell
.\scripts\setup.ps1
```
必须使用powershell执行命令

# CLI 参考

从技能根目录运行：

```powershell
#打开微信
.\scripts\wechat-cli.ps1 open
#微信切换窗口到指定群
.\scripts\wechat-cli.ps1 select '群名'
#获取群聊天内容 json列表
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json -Sender
#发送消息
.\scripts\wechat-cli.ps1 send '群名' '消息内容'
```

字段：`sender`、`senderConfidence`、`senderId`、`type`、`content`、`mediaPath`。

- `senderId` 是头像感知哈希，不是微信账号 ID。
- `type` 可为 `text`、`image`、`sticker`、`video`、`file`、`time`、`system`。
- `-Sender` 是日常昵称读取模式；新头像无法识别时会返回 `未知`。
- `-NoSenderCache` 不启动头像识别，速度最快。
- 微信里若未登录、群名不唯一或窗口被关闭，先恢复微信状态后重试。

读取 `references/cli.md` 获取完整命令与故障处理。

微信操作仅执行scripts/wechat-cli.ps1相关命令，每个都会操作结果，报错则停下