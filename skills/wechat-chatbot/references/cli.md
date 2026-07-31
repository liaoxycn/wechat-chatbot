# CLI 参考

从技能根目录运行：

```powershell
.\scripts\wechat-cli.ps1 open
.\scripts\wechat-cli.ps1 select '群名'
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json -Sender
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json -NoSenderCache
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json -Ocr
.\scripts\wechat-cli.ps1 send '群名' '消息内容'
```

字段：`sender`、`senderConfidence`、`senderId`、`type`、`content`、`mediaPath`。

- `senderId` 是头像感知哈希，不是微信账号 ID。
- `type` 可为 `text`、`image`、`sticker`、`video`、`file`、`time`、`system`。
- `-Sender` 是日常昵称读取模式；新头像无法识别时会返回 `未知`。
- `-NoSenderCache` 不启动头像识别，速度最快。
- 微信里若未登录、群名不唯一或窗口被关闭，先恢复微信状态后重试。
