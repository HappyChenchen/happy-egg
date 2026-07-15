# MacPet

一个 macOS 桌面宠物互动原型。宠物通过 `wss://happypuppy.io/ws` 进行公网配对，不要求两人连接同一 Wi-Fi。

## 运行

在本目录执行：

```sh
swift run MacPet
```

需要 macOS 14+ 与 Xcode Command Line Tools。启动后，菜单栏会出现爪印图标；拖动宠物可移动它。

## 给朋友安装测试版

### 方式一：发送 MacPet.app

先在项目目录打包，再把生成的 App 压缩后发给朋友：

```sh
./packaging/package-app.sh
ditto -c -k --sequesterRsrc --keepParent outputs/MacPet.app MacPet-test.zip
```

朋友解压后把 `MacPet.app` 放进“应用程序”。当前测试版没有 Apple Developer 公证，首次打开可能出现“无法验证开发者”。请只在确认 App 来源可信时执行：

```sh
xattr -dr com.apple.quarantine /Applications/MacPet.app
open /Applications/MacPet.app
```

也可以先右击 `MacPet.app` 选择“打开”；如果仍被拦截，再使用上面的命令。

### 方式二：朋友从源码打包

这种方式不需要付费 Apple Developer 账号，但朋友的 Mac 需要安装 Xcode Command Line Tools：

```sh
git clone https://github.com/HappyChenchen/happy-egg.git
cd happy-egg
./packaging/package-app.sh
open outputs/MacPet.app
```

如果希望下载后可以直接双击、完全不出现安全提示，需要使用 Apple Developer 的 Developer ID 签名并提交 Apple 公证。

## 当前功能

- 使用 `ai_buddy_assets` 的透明角色素材的桌面宠物窗口
- 左键宠物发送互动；连续快速点击会循环切换不同动作，接收方同步显示同一素材
- 右键宠物打开菜单，创建 8 位短配对码或输入配对码加入；双方都保留好友且在线时可拍一拍、送爱心或一起庆祝，也可隐藏或关闭应用
- 创建配对码后会自动复制到剪贴板，并在菜单栏和右键配对菜单中持续显示；未完成配对的邀请 10 分钟后自动失效
- 配对成功后会保存为长期好友；之后可在右键“好友”里选择当前互动对象
- 菜单栏和宠物右键菜单都提供“好友 / 添加好友 / 删除好友”，未连接时也能管理长期好友
- 好友列表实时显示在线人数，并用 🟢 在线、⚪️ 离线标记每位好友；双方都保留好友且对方的 MacPet 连接着服务器时才显示在线
- 好友使用稳定 profile ID 识别，改名或更换房间不会误合并不同好友
- 同名好友重复配对时自动合并，保留最新的配对连接
- 右键“我的宠物：宠物名”可修改宠物名字；已在线配对时，对方会收到改名提示
- 右键“宠物大小”可选小（80%）、正常（100%）、大（130%）或超大（160%），选择会被记住
- 菜单栏操作、显示/隐藏；互动只会发送给当前选择且在线的好友
- 朋友暂时离线、删除好友或网络中断时会自动更新状态并禁用发送

未配对时，左键仍会播放本地表情和互动气泡；右键发送动作会在配对完成后才出现，同样的点击才会同时发送给朋友。

本地测试两个实例时，可以使用独立配置启动：

```sh
./outputs/MacPet.app/Contents/MacOS/MacPet --instance A
./outputs/MacPet.app/Contents/MacOS/MacPet --instance B
```

带 `--instance` 的实例会使用独立的宠物资料、好友列表和 profile ID；A 默认叫“陈团团”，B 默认叫“团团2”；不带参数正常启动时仍使用正式配置。

## 两台 Mac 公网配对

1. A 右键宠物 → 添加好友 → 生成配对码，把复制的 8 位代码发给 B。
2. B 右键宠物 → 添加好友 → 输入配对码，输入这 8 位代码后加入。
3. 两边完成配对后会自动显示在线；选择当前好友后，点击宠物会向对方发送互动并显示同一张动作素材。
4. “断开连接”只取消当前选择，不会删除好友；“删除好友…”会清除本地好友记录，之后需要重新配对。

新配对码使用易输入的 8 位字符；旧版 64 位十六进制配对码仍可加入。

`PetInteractionService` 是联机边界；当前默认实现连接 `happypuppy.io` 的 WebSocket relay。
