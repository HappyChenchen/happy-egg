# MacPet 本地网页联动台

这是第一版本地网页 MVP，使用现有的 `happypuppy.io` relay，不需要部署网站。

在仓库根目录运行：

```sh
python3 -m http.server 4173 --directory .
```

然后打开 [http://localhost:4173/web/](http://localhost:4173/web/)。

使用方式：

1. 在 MacPet 右键 → 公网配对 → 创建短配对码。
2. 在网页输入 8 位配对码，点击“连接”。
3. 配对成功后可以从网页发送拍一拍、爱心和庆祝。

网页默认连接 `wss://happypuppy.io/ws`。如果本地 relay 已运行，可以访问：

```text
http://localhost:4173/web/?relay=ws://localhost:8080/ws
```

当前 relay 每个房间最多两个连接，因此网页测试时 MacPet 需要暂时没有和另一位好友占用同一个房间。
