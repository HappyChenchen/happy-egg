# MacPet

[![CI](https://github.com/HappyChenchen/happy-egg/actions/workflows/ci.yml/badge.svg)](https://github.com/HappyChenchen/happy-egg/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)

MacPet 是一个支持好友互动的 macOS 桌面宠物。两只宠物通过 `happypuppy.io` 公网 relay 配对，不要求处于同一局域网。

> 项目状态：Beta。核心配对、好友、在线状态和互动链路可用；应用尚未进行 Apple Developer 签名与公证。

## 核心能力

- 原生 AppKit 悬浮宠物，可拖动、缩放、隐藏或退出
- 4 位数字配对码，首次配对后保存为长期好友
- 双向好友在线状态；一方删除好友后立即停止在线与互动
- 拍一拍、送爱心、一起庆祝，并同步显示动作素材
- 每个安装使用独立的稳定宠物 ID，改名不会破坏好友关系
- 公网 WebSocket relay，带输入校验、房间人数限制和发送频率限制
- 本地网页联动台，用于演示和调试一次性配对房间

## 快速开始

### 环境要求

- macOS 14 或更高版本
- Xcode Command Line Tools（仅源码构建需要）
- Node.js 22 或更高版本（仅 relay 开发需要）

安装命令行工具：

```sh
xcode-select --install
```

### 从源码构建

```sh
git clone https://github.com/HappyChenchen/happy-egg.git
cd happy-egg
make package
open outputs/MacPet.app
```

也可以直接运行调试版本：

```sh
make run
```

## 配对与互动

1. A 右击宠物，选择“添加好友”→“生成配对码”。
2. A 把自动复制的 4 位数字配对码发给 B。
3. B 选择“添加好友”→“输入配对码…”，输入配对码完成配对。
4. 双方都保留好友且 MacPet 在线时，好友列表会显示在线并开放互动。

单击宠物只切换自己的表情；双击宠物会拍一拍当前在线好友。拖动宠物不会触发互动，爱心和庆祝仍可从右键菜单发送。

选择好友只会切换当前互动对象，不需要手动建立长期连接。App 会记住上次选择；如果只有一个好友，启动时会自动选中。删除好友后需要重新配对才能再次互动。

## 安装与分发

生成 App 和压缩包：

```sh
make package
ditto -c -k --sequesterRsrc --keepParent outputs/MacPet.app MacPet.zip
```

当前版本使用本地临时签名。若 macOS 首次打开时提示无法验证开发者，请确认文件来源可信，然后执行：

```sh
xattr -dr com.apple.quarantine /Applications/MacPet.app
open /Applications/MacPet.app
```

要实现下载后直接双击，需要使用 Apple Developer 的 Developer ID 证书签名并提交 Apple 公证。

## 开发

| 命令 | 说明 |
| --- | --- |
| `make run` | 从源码运行 macOS 客户端 |
| `make test` | 运行 Swift、relay 测试和 JavaScript 语法检查 |
| `make package` | 生成 `outputs/MacPet.app` |
| `make web` | 在 `http://localhost:4173/web/` 启动网页联动台 |
| `make relay` | 在 `http://localhost:8080` 启动本地 relay |
| `make deploy-config` | 验证 Docker Compose 配置 |

首次运行 relay 测试前安装依赖：

```sh
npm ci --prefix relay
make test
```

本地同时启动两个隔离实例：

```sh
make package
./outputs/MacPet.app/Contents/MacOS/MacPet --instance A
./outputs/MacPet.app/Contents/MacOS/MacPet --instance B
```

A 默认名为“陈团团”，B 默认名为“团团2”；两者使用独立的宠物资料、好友列表和稳定 ID。

## 仓库结构

```text
Sources/MacPet/        macOS 客户端
Tests/MacPetTests/     Swift 单元测试
relay/                 Node.js WebSocket relay 与测试
web/                   本地网页联动台
deploy/                Caddy 与 Docker Compose 配置
packaging/             macOS App 打包脚本和 Info.plist
docs/                  架构与部署文档
```

进一步阅读：

- [架构与协议](docs/ARCHITECTURE.md)
- [Relay 部署](docs/DEPLOYMENT.md)
- [网页联动台](web/README.md)
- [贡献指南](CONTRIBUTING.md)
- [安全策略](SECURITY.md)

## 隐私与安全

宠物名字、稳定 ID 和好友列表保存在本机。Relay 只在内存中维护当前连接、临时配对房间和在线关系，不持久化消息内容。当前版本没有账户系统，不能替代高安全等级的身份认证方案；详细边界见 [SECURITY.md](SECURITY.md)。

## 许可证

本仓库目前未声明开源许可证。除非版权所有者另行授权，否则不授予复制、修改或分发代码的权利。
