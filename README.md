# WeChat Chatbot

Windows 微信桌面版的本地 UI Automation CLI 与 Codex skill。不会读取微信数据库。

## 安装 Skill

```powershell
npx skills add liaoxycn/wechat-chatbot --skill wechat-chatbot
```

安装后新开一个 Codex 会话。首次需要昵称 OCR 时，在 skill 目录执行：

```powershell
.\scripts\setup.ps1
```

## 项目 CLI

```powershell
cd project
.\scripts\setup.ps1
.\scripts\wechat-cli.ps1 open
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json -NoSenderCache
.\scripts\wechat-cli.ps1 read '群名' -Limit 20 -Json -Sender
```

OCR 使用 Codex 内置 Python 3.12；若不在 Codex 环境，可通过 `-Python` 指定 Python 3.10-3.12。`data/` 仅存本地缓存和导出媒体，不应提交。
