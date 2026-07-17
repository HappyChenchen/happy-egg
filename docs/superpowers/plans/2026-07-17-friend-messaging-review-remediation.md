# Friend Messaging Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all six Important findings from the final pre-PR review so friend messages are mutually authorized, storage-bounded, durably acknowledged, protocol-consistent, and readable.

**Architecture:** The relay persists server-authorized mutual relationships plus removal tombstones, so stale sessions cannot restore a deleted friend. Its durable queue has active expiry and a global hard cap, while process-wide identity and address rate limits survive reconnects. Web and Mac clients acknowledge only after durable local save or a correlated relay response; all clients count the 300-character protocol limit as Unicode code points, and both UIs retain a readable message history.

**Tech Stack:** Swift 6/AppKit, Node.js 22/`node:test`, browser JavaScript/localStorage, Python Playwright, Docker.

---

### Task 1: Relay authorization and bounded persistence

**Files:**
- Modify: `relay/test/registry.test.mjs`
- Modify: `relay/test/server.test.mjs`
- Modify: `relay/registry.mjs`
- Modify: `relay/server.mjs`

- [x] **Step 1: Write failing registry tests**

Add tests which register Alice and Bob with one-sided lists and expect `enqueueMessage` to throw `not-friends`; create a registry with `messageTotalLimit: 2` and expect a third unique message to throw `message-capacity`; use an injected clock and `messageTTL: 100` and expect an old message to be removed.

- [x] **Step 2: Verify the registry tests fail for the intended reasons**

Run: `node --test --test-name-pattern='mutual|total message|expired message' relay/test/registry.test.mjs`

Expected: failures because one-sided messages are currently accepted, constructor queue options do not exist, and old messages never expire.

- [x] **Step 3: Write failing server tests**

Add a former-friend test where Bob removes Alice via authenticated `friend-remove`, stale sessions cannot restore the relationship, and Alice then receives `friend-message-failed`. Add a two-session test using `messageRateLimit: 1` where Alice's second socket cannot reset the identity-level limit. Update the offline-delivery setup so Bob is registered before going offline.

- [x] **Step 4: Verify the server tests fail for the intended reasons**

Run: `node --test --test-name-pattern='removed friend|across reconnects' relay/test/server.test.mjs`

Expected: the removed-friend send is accepted and the second session bypasses the current socket-local limiter.

- [x] **Step 5: Implement the minimal relay behavior**

Persist normalized server friend IDs and deletion tombstones; add both participants atomically when both remain within the 100-friend limit; expose a mutual-friend check and enforce it inside `enqueueMessage`. Bound friend-request records at 10000 with pending/result TTLs, purge requests and messages from a background timer, reject new unique messages above a 5,000-message global cap, cap WebSocket frames at 16 KiB, bound identities at 100000, and add server-wide per-peer/per-address rate maps for registration, removal, and messaging.

- [x] **Step 6: Run Relay tests green**

Run: `npm test --prefix relay`

Expected: all tests pass with no failures.

### Task 2: Web durable save before ACK

**Files:**
- Modify: `scripts/e2e_friend_messaging.py`
- Modify: `web/app.js`
- Modify: `web/index.html`
- Modify: `web/styles.css`

- [x] **Step 1: Extend E2E with a failing refresh-recovery assertion**

After the offline message is delivered and the relay queue is ACKed, reload recipient B and require both `localStorage['macpet-web-messages']` and `#message-history` to contain the same `messageID` and body.

- [x] **Step 2: Verify the E2E fails at durable Web history**

Run: `python3 scripts/e2e_friend_messaging.py`

Expected: failure because the current Web client has no message storage or history element.

- [x] **Step 3: Implement durable Web history**

Add a `messages` storage key, validate/deduplicate/cap records at 50, synchronously call `localStorage.setItem` before `friend-message-ack`, and do not ACK when persistence throws. Render recent records in a scrollable `#message-history` section so a reload retains readable content.

- [x] **Step 4: Run the E2E green**

Run: `python3 scripts/e2e_friend_messaging.py`

Expected: delivery, ACK, reload, local storage, and visible history all pass.

### Task 3: Shared Unicode message boundary

**Files:**
- Modify: `relay/test/server.test.mjs`
- Modify: `relay/server.mjs`
- Modify: `Sources/MacPet/PetMessage.swift`
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `Tests/MacPetTests/AppModelTests.swift`
- Modify: `web/app.js`

- [x] **Step 1: Write failing boundary tests**

Have Relay accept exactly 300 emoji code points and reject 301. Add a Swift assertion that `PetMessage.normalizedText` returns 300 emoji from a 301-emoji input.

- [x] **Step 2: Verify Relay's test fails**

Run: `node --test --test-name-pattern='Unicode code points' relay/test/server.test.mjs`

Expected: 300 emoji are rejected by the existing UTF-16 `.length` check.

- [x] **Step 3: Implement code-point normalization**

Use `Array.from(trimmed)` in Relay/Web and `trimmed.unicodeScalars.prefix(300)` in Swift. Document that the limit is 300 Unicode code points.

- [x] **Step 4: Verify protocol tests and Swift build**

Run: `npm test --prefix relay && swift build`

Expected: Relay passes and Swift compiles. XCTest execution remains delegated to macOS CI because this workstation's Command Line Tools lacks the `XCTest` module.

### Task 4: Mac waits for relay acceptance

**Files:**
- Modify: `Sources/MacPet/PetInteractionService.swift`
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `Tests/MacPetTests/AppModelTests.swift`

- [x] **Step 1: Add failing model tests**

Configure the local service to return `.rejected("rate limit")` and `.transportFailed`; require the model to show the localized rejection/transport text and never show the success bubble. Keep the existing success test as the accepted case.

- [x] **Step 2: Record the local XCTest limitation**

Run: `make test-mac`

Expected locally: toolchain error `no such module 'XCTest'` before test execution; CI on `macos-15` is the executable XCTest gate.

- [x] **Step 3: Implement response-correlated delivery**

Introduce `PetMessageSendResult` (`accepted`, `rejected(message:)`, `transportFailure`). Make the public service keep continuations and payloads keyed by `messageID`, resolve only on matching `friend-message-sent`/`friend-message-failed`, retain and resend the same ID after a connection loss, and time out after ten seconds. Make `AppModel` show success only for `.accepted`.

- [x] **Step 4: Verify compilation and protocol E2E**

Run: `swift build && make test-e2e`

Expected: Swift compiles and the real two-browser protocol flow remains green.

### Task 5: Readable long-message details

**Files:**
- Modify: `Tests/MacPetTests/PetViewTests.swift`
- Modify: `Sources/MacPet/PetView.swift`
- Modify: `Sources/MacPet/AppDelegate.swift`

- [x] **Step 1: Add a failing bubble-bounds test**

Render a 300-character string in a 220-point `PetView` and assert the computed bubble rectangle stays inside `view.bounds` with a multi-line height.

- [x] **Step 2: Implement bounded preview and full detail**

Measure with `boundingRect(...usesLineFragmentOrigin...)`, cap bubble width to the panel bounds and draw wrapped text. When a history item opens, mark it read and show the complete body in a selectable, vertically scrollable `NSTextView` inside an `NSAlert`.

- [x] **Step 3: Verify Swift build/package**

Run: `swift build && make package`

Expected: both commands exit 0.

### Task 6: Documentation, full verification, and PR

**Files:**
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `web/README.md`

- [x] **Step 1: Update exact guarantees**

Document mutual authorization, seven-day TTL plus the cleanup interval, 5,000-message global cap, code-point length semantics, Web local history, and ACK-after-save behavior.

- [x] **Step 2: Run all available gates**

Run: `PYTHONOPTIMIZE=1 make test-e2e`, `make package`, `make deploy-config`, and `docker build --tag macpet-relay:local relay`.

Expected: all available gates exit 0; `make test` may only fail at the documented local `XCTest` toolchain import, while PR CI runs `make test-mac` on macOS 15.

- [x] **Step 3: Obtain a new independent code review**

Require no Critical or Important findings before committing.

- [ ] **Step 4: Commit, push, and create the PR**

Use Conventional Commits, push `feature/friend-messaging`, create a PR to `main`, and include exact verification/caveat results plus the generated E2E screenshot evidence description.
