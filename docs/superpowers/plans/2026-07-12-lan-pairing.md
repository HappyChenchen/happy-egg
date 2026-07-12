# LAN Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pair one nearby pet by name and send interactions only to that friend.

**Architecture:** Bonjour discovery supplies named `PetPeer` values. `AppModel` owns the selection; the AppKit right-click menu renders nearby names and sends only to the selected peer.

**Tech Stack:** Swift 6, AppKit, Network.framework, XCTest, macOS 14+.

---

## File structure

- `Sources/MacPet/PetPeer.swift` — named peer domain model.
- `Sources/MacPet/PetInteractionService.swift` — discovery directory and targeted sending.
- `Sources/MacPet/AppModel.swift` — selected friend and interaction gating.
- `Sources/MacPet/PetView.swift` — right-click pairing menu.
- `Sources/MacPet/PetPanelController.swift` and `Sources/MacPet/AppDelegate.swift` — UI state wiring.
- `Tests/MacPetTests/AppModelTests.swift` — pairing tests.
- `README.md` — two-Mac instructions.

### Task 1: Return named nearby peers

**Files:**

- Create: `Sources/MacPet/PetPeer.swift`
- Modify: `Sources/MacPet/PetInteractionService.swift`
- Test: `Tests/MacPetTests/AppModelTests.swift`

- [ ] **Step 1: Add the failing directory test**

```swift
func testDirectoryReturnsNamedPeer() async {
    let service = LocalPetInteractionService()
    await service.setPeers([PetPeer(id: "alice-device", name: "Alice")])
    XCTAssertEqual(await service.availablePeers(), [PetPeer(id: "alice-device", name: "Alice")])
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter AppModelTests/testDirectoryReturnsNamedPeer`

Expected: compilation fails because `PetPeer` and `availablePeers` are absent.

- [ ] **Step 3: Add the exact directory interface**

```swift
struct PetPeer: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

protocol PetInteractionService: Sendable {
    func availablePeers() async -> [PetPeer]
    func send(_ event: PetEvent, to peerID: String) async
    func incomingEvents() async -> AsyncStream<PetEvent>
}
```

`LocalPetInteractionService` must store test peers. `LocalNetworkPetInteractionService` must advertise a persistent device ID and an encoded display name in its Bonjour service name, parse each discovered service into `PetPeer`, and retain the matching `NWBrowser.Result` by `PetPeer.id`.

- [ ] **Step 4: Run and commit**

Run: `swift test --filter AppModelTests/testDirectoryReturnsNamedPeer`

Expected: one passing test.

```bash
git add Sources/MacPet/PetPeer.swift Sources/MacPet/PetInteractionService.swift Tests/MacPetTests/AppModelTests.swift
git commit -m "feat: 提供局域网宠物发现目录"
```

### Task 2: Pair a friend and gate delivery

**Files:**

- Modify: `Sources/MacPet/AppModel.swift`
- Test: `Tests/MacPetTests/AppModelTests.swift`

- [ ] **Step 1: Add failing pairing tests**

```swift
func testPairingStoresFriendName() {
    let model = AppModel(service: LocalPetInteractionService())
    model.pair(with: PetPeer(id: "alice-device", name: "Alice"))
    XCTAssertEqual(model.pairedFriend?.name, "Alice")
}

func testInteractionWithoutPairingExplainsWhatToDo() async {
    let model = AppModel(service: LocalPetInteractionService())
    await model.sendInteraction(kind: .poke)
    XCTAssertEqual(model.bubbleText, "请先右键宠物，选择要配对的朋友")
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter AppModelTests/testPairingStoresFriendName --filter AppModelTests/testInteractionWithoutPairingExplainsWhatToDo`

Expected: compilation fails for the missing pairing API.

- [ ] **Step 3: Add model state and targeted delivery**

```swift
private(set) var nearbyPeers: [PetPeer] = []
private(set) var pairedFriend: PetPeer?
var onPeersChange: (() -> Void)?

func refreshPeers() async {
    nearbyPeers = await service.availablePeers()
    onPeersChange?()
}

func pair(with peer: PetPeer) { pairedFriend = peer; onPeersChange?() }
func unpair() { pairedFriend = nil; onPeersChange?() }
```

`sendInteraction` must use `service.send(event, to: pairedFriend.id)`. With no pairing it shows exactly `请先右键宠物，选择要配对的朋友`; when paired it says `已拍一拍 <name>`.

- [ ] **Step 4: Run and commit**

Run: `swift test --filter AppModelTests`

Expected: all model tests pass.

```bash
git add Sources/MacPet/AppModel.swift Tests/MacPetTests/AppModelTests.swift
git commit -m "feat: 添加宠物配对和定向互动"
```

### Task 3: Expose pairing in the right-click menu

**Files:**

- Modify: `Sources/MacPet/PetView.swift`
- Modify: `Sources/MacPet/PetPanelController.swift`
- Modify: `Sources/MacPet/AppDelegate.swift`

- [ ] **Step 1: Add the view contract**

```swift
var nearbyPeers: [PetPeer] = []
var pairedFriend: PetPeer?
var onPair: ((PetPeer) -> Void)?
var onUnpair: (() -> Void)?
```

The menu must show `已配对：Alice` and `取消配对` when selected. Without a pairing, it must show a `配对附近宠物` submenu containing each `PetPeer.name`, or one disabled `正在寻找附近的 MacPet…` item.

- [ ] **Step 2: Wire refresh and callbacks**

```swift
model.onPeersChange = { [weak self] in self?.renderPet() }
model.startRefreshingPeers()
// Pass `model.nearbyPeers`, `model.pairedFriend`, `model.pair(with:)`, and `model.unpair()` through PetPanelController.
```

- [ ] **Step 3: Build and commit**

Run: `swift build`

Expected: `Build complete!`.

```bash
git add Sources/MacPet/PetView.swift Sources/MacPet/PetPanelController.swift Sources/MacPet/AppDelegate.swift
git commit -m "feat: 在宠物菜单显示配对好友"
```

### Task 4: Verify and document

**Files:**

- Modify: `README.md`

- [ ] **Step 1: Add manual verification**

```markdown
1. 两台 Mac 连接同一 Wi-Fi，分别启动 MacPet。
2. 右键 A 的宠物，在“配对附近宠物”中选择 B 的名称。
3. 确认菜单显示“已配对：<B 名称>”。
4. 点击 A 的宠物；只有 B 收到相同动作。
5. 取消配对后，再次点击 A 会提示先配对。
```

- [ ] **Step 2: Test, package, commit, and push**

Run: `swift test && packaging/package-app.sh`

Expected: all tests pass and `outputs/MacPet.app` exists.

```bash
git add README.md
git commit -m "docs: 补充局域网配对说明"
git push origin main
```

## Self-review

- Discovery and visible names are covered in Task 1 and Task 3.
- Pairing and target-only delivery are covered in Task 2.
- Two-Mac instructions and packaging are covered in Task 4.
- The same `PetPeer.id`, `PetPeer.name`, `availablePeers()`, `pairedFriend`, and `send(_:to:)` names are used throughout.

### Task 5: Add persistent pet size controls

**Files:**

- Modify: `Sources/MacPet/PetView.swift`
- Modify: `Sources/MacPet/PetPanelController.swift`
- Modify: `Sources/MacPet/AppModel.swift`
- Test: `Tests/MacPetTests/AppModelTests.swift`

- [ ] **Step 1: Add a failing size-state test**

```swift
func testPetSizeChangesToChosenScale() {
    let model = AppModel(service: LocalPetInteractionService())
    model.setPetScale(.large)
    XCTAssertEqual(model.petScale, .large)
}
```

- [ ] **Step 2: Add `PetScale` and the exact menu options**

```swift
enum PetScale: CGFloat, CaseIterable { case small = 0.8, normal = 1, large = 1.3, extraLarge = 1.6 }
```

The right-click menu has a `宠物大小` submenu with `小 (80%)`、`正常 (100%)`、`大 (130%)`、`超大 (160%)`; the active option shows a checkmark. `PetPanelController` resizes the panel and its content view around the current screen location when the value changes.

- [ ] **Step 3: Run test and build**

Run: `swift test && swift build`

Expected: all tests pass and the panel has no fixed-size assumption.
