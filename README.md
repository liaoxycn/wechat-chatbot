# WeChat Chatbot

通过 Windows UI Automation 操作已登录的微信桌面版的 Codex skill，不读取微信数据库。

## 安装 Skill

```powershell
npx skills add liaoxycn/wechat-chatbot --skill wechat-chatbot
```
安装到项目目录

## 使用示例

注意：使用完全访问权限才可使codex操作微信

```text
@wechat-chatbot 查看微信群“多邻国去哪儿”的最近消息
总结“项目讨论群”今天的聊天内容
在“项目讨论群”中参与发言
```
