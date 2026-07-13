# 配对体验改进 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让公网配对使用易输入的短码，并在等待、断线和旧版配对码场景下给出正确反馈。

**Status:** Implementation completed; tests, clean packaging, and public short-code handshake verified.

**Architecture:** 客户端生成 8 位、排除易混淆字符的短码；relay 同时兼容新短码和旧 64 位十六进制码，并统一房间 ID 大小写。AppModel 只在确认配对后发送远程互动，PublicPetInteractionService 把断线、朋友离线和重连状态通过连接更新流交给 AppModel。

**Tech Stack:** Swift 6 / AppKit / URLSessionWebSocketTask / Node.js `ws` relay / Swift XCTest / Node test runner.

---

### Task 1: Lock the pairing and pending-interaction behavior with tests

**Files:**
- Modify: `Tests/MacPetTests/AppModelTests.swift`
- Modify: `relay/test/server.test.mjs`

- [ ] **Step 1: Add a short-code assertion**

  Assert that `createPublicPairing()` returns exactly 8 characters matching `^[a-hj-km-np-z2-9]{8}$`.

- [ ] **Step 2: Add a pending interaction assertion**

  Create a pairing with `createPublicPairing()`, call `sendInteraction(kind: .poke)`, and assert the bubble remains a local-only message rather than `已拍一拍 配对码已创建`.

- [ ] **Step 3: Add relay compatibility coverage**

  Join one socket with an uppercase short code and another with its lowercase form; assert both receive the normal `joined`/`presence` handshake. Keep a legacy 64-character hex room test so old clients remain compatible.

- [ ] **Step 4: Run the focused tests and observe failures**

  Run `swift test --filter AppModelTests` and `(cd relay && npm test)`. The new short-code and pending-interaction assertions must fail before implementation.

### Task 2: Implement short pairing codes and legacy compatibility

**Files:**
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `relay/server.mjs`
- Modify: `README.md`

- [ ] **Step 1: Generate a short code**

  Use the alphabet `abcdefghjkmnpqrstuvwxyz23456789`, select eight cryptographically random positions, and store/send the resulting lowercase code.

- [ ] **Step 2: Validate both code formats on join**

  Accept the new 8-character alphabet and the existing 64-character hex format; normalize the trimmed input to lowercase before storing `PetPeer.id` and joining.

- [ ] **Step 3: Normalize relay room IDs**

  Change the relay room pattern to accept either format case-insensitively, lowercase the room ID before looking it up, and retain the existing room-size limit.

- [ ] **Step 4: Update user-facing instructions**

  Explain that new pairing codes are 8 characters and that old 64-character codes remain valid.

### Task 3: Fix pending interaction and remove stale LAN metadata

**Files:**
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `packaging/Info.plist`

- [ ] **Step 1: Gate remote sends on confirmed pairing**

  Make `sendInteraction` use `confirmedFriend`; when the friend is pending, keep the local animation and local bubble without sending to relay.

- [ ] **Step 2: Remove obsolete Bonjour declarations**

  Delete `NSBonjourServices` and `NSLocalNetworkUsageDescription` from the packaging plist because transport is now public WebSocket only.

- [ ] **Step 3: Run Swift tests**

  Run `swift test` and confirm all tests pass.

### Task 4: Surface disconnects and retry the current room

**Files:**
- Modify: `Sources/MacPet/PetInteractionService.swift`
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `Tests/MacPetTests/AppModelTests.swift`

- [ ] **Step 1: Extend connection updates**

  Add `peerUnavailable`, `connectionLost`, and `connectionFailed(message:)` cases; handle them in AppModel with concise Chinese status bubbles while retaining the current friend record.

- [ ] **Step 2: Preserve pairing context for reconnect**

  Store the current room and pet name in `PublicPetInteractionService`, cancel them on a new pair or explicit stop, and retry a dropped socket after 2 seconds with the same room.

- [ ] **Step 3: Continue processing relay presence**

  Interpret `presence.connected < 2` as friend offline and keep the room ready for the next presence update.

- [ ] **Step 4: Add a deterministic connection-update test seam**

  Extend `LocalPetInteractionService` with a simulated `peerUnavailable` update and assert AppModel shows `朋友已离线，等待重连` without clearing `pairedFriend`.

### Task 5: Verify, package, deploy, and document

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-07-13-pairing-ux.md`

- [ ] **Step 1: Run all tests**

  Run `swift test` and `(cd relay && npm test)`.

- [ ] **Step 2: Build a clean App bundle**

  Run `./packaging/package-app.sh`, verify the bundle contains no removed assets and the plist has no Bonjour keys.

- [ ] **Step 3: Deploy relay and run a public WSS smoke test**

  Upload `relay/` to `/opt/macpet`, rebuild `deploy-relay-1`, and verify uppercase/lowercase short-code clients receive `joined` and `presence` through `wss://happypuppy.io/ws`.

- [ ] **Step 4: Restart two local instances and commit**

  Start two copies of `outputs/MacPet.app`, confirm both processes exist, then commit with `fix: 优化短码配对与断线反馈` and push `main`.
