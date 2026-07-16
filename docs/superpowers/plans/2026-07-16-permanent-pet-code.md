# Permanent Pet Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace one-time pairing rooms with a persistent six-digit pet number and owner-approved friend requests while preserving existing friends and old-client relay compatibility.

**Architecture:** A focused JSON-backed registry owns pet-number allocation, device-token verification, pending requests, and offline result delivery. The existing presence WebSocket carries the new protocol, so accepted friends immediately reuse the stable-ID presence and interaction path. The macOS and web clients store a device token locally; legacy room messages remain available only for older clients during migration.

**Tech Stack:** Swift 6/AppKit, Foundation WebSocket, Node.js 22, `ws`, atomic JSON persistence, Docker Compose.

---

### Task 1: Persistent pet identity registry

**Files:**
- Create: `relay/registry.mjs`
- Create: `relay/test/registry.test.mjs`

- [ ] **Step 1: Write the failing allocation and persistence test**

```js
const first = registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
assert.match(first.petCode, /^\d{6}$/);
const restored = new PetRegistry({ filePath }).registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
assert.equal(restored.petCode, first.petCode);
```

- [ ] **Step 2: Run `node --test relay/test/registry.test.mjs` and verify it fails because `PetRegistry` does not exist.**

- [ ] **Step 3: Implement `PetRegistry` with SHA-256 token hashes, unique codes from `100000...999999`, atomic temp-file rename, and in-memory mode when no path is supplied.**

- [ ] **Step 4: Add and pass tests for wrong-token rejection and code reset invalidating the old code.**

- [ ] **Step 5: Commit with `feat: 增加持久宠物号注册表`.**

### Task 2: Friend-request relay protocol

**Files:**
- Modify: `relay/registry.mjs`
- Modify: `relay/server.mjs`
- Modify: `relay/test/server.test.mjs`

- [ ] **Step 1: Write one failing WebSocket test that registers two authenticated profiles and receives stable six-digit `pet-code` messages.**

```js
alice.send(JSON.stringify({ type: 'presence-register', peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: [] }));
assert.match((await messagesUntil(alice, 'pet-code')).petCode, /^\d{6}$/);
```

- [ ] **Step 2: Extend presence registration to authenticate via `PetRegistry`, emit `pet-code`, and keep unauthenticated legacy presence registration working.**

- [ ] **Step 3: Write a failing request/accept test for `friend-request-create`, `friend-request-incoming`, `friend-request-respond`, and `friend-request-accepted`.**

- [ ] **Step 4: Implement request persistence, self-request rejection, per-connection rate limiting, online delivery, reconnect delivery, and `friend-request-ack` cleanup.**

- [ ] **Step 5: Add passing tests for rejection, offline acceptance delivery, invalid codes, and reset codes.**

- [ ] **Step 6: Commit with `feat: 增加好友申请中继协议`.**

### Task 3: macOS transport and state model

**Files:**
- Create: `Sources/MacPet/PetFriendRequest.swift`
- Modify: `Sources/MacPet/PetInteractionService.swift`
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `Tests/MacPetTests/AppModelTests.swift`
- Modify: `Tests/MacPetTests/PublicRelayIntegrationTests.swift`

- [ ] **Step 1: Add a failing model test asserting that a first launch creates a 64-character device token and later launches reuse it.**

- [ ] **Step 2: Persist `com.macpet.auth-token` and `com.macpet.pet-code`; include the token in presence registration and map `pet-code` messages into model state.**

- [ ] **Step 3: Add a failing test where `sendFriendRequest("123456")` records a request and reports invalid input without sending.**

- [ ] **Step 4: Add service methods `requestFriend(code:)`, `respondToFriendRequest(id:accept:)`, `resetPetCode()`, and `acknowledgeFriendRequest(id:)`.**

- [ ] **Step 5: Add failing then passing model tests for incoming request deduplication, accept saving/selecting the friend, rejection removal, and accepted result idempotency.**

- [ ] **Step 6: Extend the live production integration test to register two identities, create/accept a request, become mutually online, and deliver an acknowledged poke.**

- [ ] **Step 7: Commit with `feat: 接入永久宠物号与好友申请`.**

### Task 4: AppKit friend-request interface

**Files:**
- Modify: `Sources/MacPet/AppDelegate.swift`
- Modify: `Sources/MacPet/PetPanelController.swift`
- Modify: `Sources/MacPet/PetView.swift`

- [ ] **Step 1: Replace “生成配对码” and “输入配对码” with a persistent pet-number row, copy/reset actions, and “输入宠物号…”.**

- [ ] **Step 2: Show `好友申请（N）` in both menus and route a selected request to an accept/reject `NSAlert`.**

- [ ] **Step 3: Keep current friend selection, delete-friend, double-click poke, and legacy saved friends unchanged.**

- [ ] **Step 4: Build with `swift build` and manually verify menu titles through the running app.**

- [ ] **Step 5: Commit with `feat: 更新宠物号好友申请界面`.**

### Task 5: Web companion migration

**Files:**
- Modify: `web/index.html`
- Modify: `web/app.js`
- Modify: `web/styles.css`
- Modify: `web/README.md`

- [ ] **Step 1: Store a web auth token next to the stable peer ID and register through presence instead of a temporary room.**

- [ ] **Step 2: Replace the 4-digit form with a 6-digit pet-number friend request and show incoming accept/reject controls.**

- [ ] **Step 3: After acceptance, persist the peer, subscribe mutually, and send interactions through `friend-event` with delivery acknowledgement.**

- [ ] **Step 4: Run `node --check web/app.js` and browser-test request, acceptance, online state, and interaction.**

- [ ] **Step 5: Commit with `feat: 网页端接入永久宠物号`.**

### Task 6: Deployment, documentation, and release verification

**Files:**
- Modify: `relay/Dockerfile`
- Modify: `deploy/compose.yaml`
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/DEPLOYMENT.md`

- [ ] **Step 1: Create `/data` as the node user and mount a named `relay_data` volume with `MACPET_REGISTRY_PATH=/data/registry.json`.**

- [ ] **Step 2: Document permanent pet numbers, device-token security, approval flow, reset behavior, and legacy compatibility.**

- [ ] **Step 3: Run `make test`, `make package`, Docker Compose config validation, and production two-client integration.**

- [ ] **Step 4: Deploy the Relay, confirm `/health`, verify registry persistence across a container restart, and restart the local app.**

- [ ] **Step 5: Push `main`, wait for GitHub CI success, and report the new app path and operational behavior.**

