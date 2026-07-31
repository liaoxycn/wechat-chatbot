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
