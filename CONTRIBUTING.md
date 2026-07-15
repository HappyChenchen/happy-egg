# 贡献指南

感谢你改进 MacPet。提交修改前，请先阅读本文并确保改动可以在本机复现。

## 开发环境

- macOS 14+
- Xcode Command Line Tools
- Node.js 22+
- Docker（仅部署配置和 relay 镜像验证需要）

```sh
git clone https://github.com/HappyChenchen/happy-egg.git
cd happy-egg
npm ci --prefix relay
make test
```

## 工作方式

1. 从最新 `main` 创建短生命周期分支。
2. 每个提交只解决一个清晰问题。
3. 用户可见行为需要测试；修复缺陷时优先先写回归测试。
4. UI 修改在 Pull Request 中附上截图或录屏。
5. 不提交构建产物、个人配置、私钥或 Token。

建议分支名：

```text
feat/friend-notifications
fix/presence-state
docs/deployment-guide
```

提交信息使用 Conventional Commits 类型前缀，描述可以使用中文：

```text
feat: 增加好友通知
fix: 修复离线状态残留
docs: 更新部署说明
```

## 提交前检查

```sh
make test
make package
```

涉及 relay 或部署时再执行：

```sh
make deploy-config
docker build --tag macpet-relay:local relay
```

需要验证真实公网 WebSocket 链路时，可显式运行不会进入默认 CI 的集成测试：

```sh
MACPET_INTEGRATION_TESTS=1 swift test --filter PublicRelayIntegrationTests
```

## Pull Request

Pull Request 应包含：

- 问题与用户影响
- 实现范围和未解决事项
- 具体验证命令及结果
- UI 变化截图
- 对协议、部署或隐私边界的影响

CI 必须通过后再合并。不要在同一个 Pull Request 中混入无关格式化或重构。

## 安全问题

不要在公开 Issue 中披露未修复漏洞。请遵循 [SECURITY.md](SECURITY.md) 的私密报告流程。
