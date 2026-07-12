# MacPet

一个 macOS 桌面宠物互动原型。宠物会悬浮在桌面上；点击它或从菜单栏选择“拍一拍朋友”，会直接发给同一局域网内运行 MacPet 的伙伴。

## 运行

在本目录执行：

```sh
swift run MacPet
```

需要 macOS 14+ 与 Xcode Command Line Tools。启动后，菜单栏会出现爪印图标；拖动宠物可移动它。

## 当前功能

- 使用 `ai_buddy_assets` 的透明角色素材的桌面宠物窗口
- 左键宠物发送互动；连续快速点击会循环切换不同动作，接收方同步显示同一素材
- 右键宠物打开菜单，可拍一拍、送爱心、一起庆祝、隐藏宠物或关闭应用
- 菜单栏操作、局域网自动发现、显示/隐藏
- Bonjour + TCP 局域网直连；无需外网或服务端

## 下一步：真实两人联机

两台 Mac 连接同一 Wi-Fi 并都启动 MacPet 后，会通过 Bonjour 自动发现。点击任一宠物会把互动发给局域网内已发现的其他 MacPet。`PetInteractionService` 仍是联机边界，之后可额外实现 Supabase Realtime 版本以支持异地好友。
