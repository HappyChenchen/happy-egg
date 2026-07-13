# 配对身份与邀请生命周期 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让长期好友使用稳定身份保存，并让未完成的邀请自动过期；配对通过剪贴板传递短配对码。

**Status:** Implementation completed; all tests, packaging, deployment, and public profile-ID handshake verified.

**Architecture:** 客户端为每个安装生成持久化 32 位 profile ID，relay 在 `joined`、`presence` 和 `profile` 中转发该 ID；好友记录同时保存临时房间码和稳定 ID，旧记录没有 ID 时按名字兼容。relay 只对单人等待房间设置 10 分钟定时器，第二人加入后取消定时器；创建邀请后短配对码复制到剪贴板。客户端拒绝与自身 profile ID 配对，并清理旧的同名自我好友记录。

**Tech Stack:** Swift 6 / AppKit / URLSessionWebSocketTask / Node.js `ws` / XCTest / Node test runner.

---

### Task 1: Lock identity and expiry behavior with tests

**Files:**
- Modify: `Tests/MacPetTests/AppModelTests.swift`
- Modify: `relay/test/server.test.mjs`

- [ ] Add a test that two saved friends with the same name but different stable IDs remain distinct, while legacy records without IDs still deduplicate by name.
- [ ] Add a relay test that an unjoined room expires with `配对码已过期` and a room with two peers is not expired.
- [ ] Run `swift test --filter AppModelTests` and `(cd relay && npm test)` before implementation; the new tests must fail.

### Task 2: Add stable profile IDs and relay propagation

**Files:**
- Modify: `Sources/MacPet/PetPeer.swift`
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `Sources/MacPet/PetInteractionService.swift`
- Modify: `relay/server.mjs`

- [ ] Persist a random lowercase 32-hex `com.macpet.peer-id` per installation.
- [ ] Include that ID in `join` and `profile` messages, propagate it in `joined`/`presence`/`profile`, and preserve missing IDs for old clients.
- [ ] Store `PetPeer.peerID` as an optional Codable field and deduplicate by stable ID when available.

### Task 3: Expire unjoined rooms

**Files:**
- Modify: `relay/server.mjs`
- Modify: `relay/test/server.test.mjs`

- [ ] Add a configurable `pairingTTL` defaulting to 10 minutes.
- [ ] Start a timer for a one-peer room, cancel it when a second peer joins or the room empties, and send an expiry error before closing sockets.
- [ ] Map the expiry error to the existing client connection-failed status without retrying an invalid room.

### Task 4: Keep clipboard-only invitations and filter self pairing

**Files:**
- Modify: `Sources/MacPet/AppDelegate.swift`
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `README.md`

- [x] Keep invitation creation clipboard-only; remove the QR modal and Core Image dependency.
- [x] Reject a peer that reports this installation's stable profile ID, and remove legacy same-name self records.

### Task 5: Verify, package, deploy, and publish

**Files:**
- Modify: `docs/superpowers/plans/2026-07-13-pairing-identity-expiry-qr.md`

- [ ] Run all Swift and relay tests.
- [x] Build `outputs/MacPet.app`, verify the clipboard-only build and no removed assets.
- [ ] Deploy relay to `/opt/macpet`, run public WSS short-code and expiry smoke tests, restart two local instances, commit `feat: 增强配对身份与邀请管理`, and push `main`.
