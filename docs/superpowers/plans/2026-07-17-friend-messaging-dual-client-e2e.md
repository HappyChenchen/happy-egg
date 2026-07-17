# Friend Messaging Dual-Client E2E Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the friend-messaging feature works across two independent real clients, including friendship establishment, bidirectional online messaging, stickers, offline queueing, relay restart persistence, redelivery, and acknowledgement.

**Architecture:** Run the production Relay implementation with an isolated persisted registry and serve the real `web/` client. Use two independent Chromium BrowserContexts to create isolated `localStorage` identities, then validate UI state against the persisted Relay queue. Keep all runtime evidence under ignored `work/`; do not modify production code unless an observed failure is reproducible.

**Tech Stack:** Node.js 25, `ws`, Python Playwright with system Google Chrome, HTML/CSS/JavaScript client, JSON registry persistence, Swift Package Manager verification.

---

### Task 1: Establish a clean and isolated acceptance environment

**Files:**
- Inspect: `relay/server.mjs`
- Inspect: `web/app.js`
- Runtime evidence: `work/e2e-acceptance-result.json`, `work/e2e-evidence/*.png`
- Runtime state: `work/e2e-registry.json`
- Runtime harness: `scripts/e2e_friend_messaging.py`

- [x] **Step 1: Verify the tracked harness prerequisites**

Run:

```bash
git status --short --branch
python3 -c 'import playwright; print(playwright.__file__)'
test -x '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
```

Expected: the existing feature changes remain untouched, Python Playwright imports, and system Chrome is executable. The harness chooses free dynamic ports and verifies that its own child PIDs own them.

- [x] **Step 2: Run the complete repeatable acceptance command**

Run from the repository root:

```bash
make test-e2e
```

Expected: the command exits 0 and writes `accepted: true` to `work/e2e-acceptance-result.json`.

- [x] **Step 3: Prove the spawned services own their dynamic ports**

The harness starts `node relay/server.mjs` and `python3 -m http.server`, then uses `lsof` to require each child PID to own its selected listening port before any health request is accepted.

Expected: an occupied override port causes a startup failure rather than connecting to an incumbent process.

- [x] **Step 4: Verify both services before browser interaction**

Run after acceptance:

```bash
jq '{services, accepted}' work/e2e-acceptance-result.json
```

Expected: Relay health is true, the two recorded Relay PIDs differ across restart, and `accepted` is true.

### Task 2: Create two independent real client identities and become friends

**Files:**
- Exercise: `web/index.html`
- Exercise and repair observed stale status: `web/app.js`
- Inspect runtime state: `work/e2e-registry.json`

- [x] **Step 1: Open two storage-isolated clients**

Open the same local client in two independent BrowserContexts:

```text
http://127.0.0.1:<dynamic-web-port>/web/?relay=ws://127.0.0.1:<dynamic-relay-port>/ws
```

Expected: both display different six-digit pet codes because BrowserContexts do not share storage.

- [x] **Step 2: Assign deterministic visible names**

Set the first client's `网页端名字` input to `验收甲`, and the second client's input to `验收乙`; trigger each input's change event.

Expected: `work/e2e-registry.json` contains two identities with those names and different peer IDs and pet codes.

- [x] **Step 3: Establish friendship through the real UI**

Open both operation menus. Enter 乙's six-digit pet code into 甲's `输入 6 位宠物号` field, click `申请`, then click `接受` in 乙's incoming request panel.

Expected: both clients select the other as a friend, both connection labels become `在线`, and the Relay request disappears after both clients acknowledge it.

### Task 3: Verify bidirectional online text and sticker delivery

**Files:**
- Exercise: `web/app.js`
- Inspect runtime state: `work/e2e-registry.json`

- [x] **Step 1: Send text from 甲 to 乙**

Enter `甲到乙-在线文字` in 甲's `留言内容` input and click `留言`.

Expected: 甲 displays `留言已发送`; 乙 displays `验收甲：甲到乙-在线文字`.

- [x] **Step 2: Send text from 乙 to 甲**

Enter `乙到甲-在线文字` in 乙's `留言内容` input and click `留言`.

Expected: 乙 displays `留言已发送`; 甲 displays `验收乙：乙到甲-在线文字`.

- [x] **Step 3: Send a preset sticker through the real UI**

Click the `❤️` sticker button in 甲's operation menu.

Expected: 甲 displays `留言已发送`; 乙 displays `验收甲 发来 ❤️`.

- [x] **Step 4: Confirm online deliveries were acknowledged**

Run:

```bash
jq '{requests, messages}' work/e2e-registry.json
```

Expected: both objects are empty after the browser clients send their ACK messages.

### Task 4: Verify offline queueing, relay restart persistence, redelivery, and ACK removal

**Files:**
- Exercise: `web/app.js`
- Runtime state: `work/e2e-registry.json`
- Runtime evidence: `work/e2e-acceptance-result.json`

- [x] **Step 1: Intentionally disconnect 乙**

Click `断开连接` in 乙's operation menu and wait for 甲 to display `好友离线`.

Expected: 乙 displays `已断开`; 甲 observes 乙 offline after the Relay grace period.

- [x] **Step 2: Send an offline message from 甲**

Enter `离线跨重启留言` in 甲's message input and click `留言`.

Expected: 甲 displays `留言已发送`, and `jq '.messages' work/e2e-registry.json` contains exactly one message addressed to 乙.

- [x] **Step 3: Restart the real Relay without clearing persistence**

The harness stops only its verified Relay child, then starts a new verified child on the same dynamic port with the same absolute registry path.

Expected: the two Relay PIDs differ and the queued message remains in `work/e2e-registry.json`.

- [x] **Step 4: Reconnect 乙 and observe redelivery**

Wait for 甲 to reconnect automatically, then click `重新连接` in 乙.

Expected: 乙 displays `验收甲：离线跨重启留言` and returns an ACK; 甲 and 乙 both return to `在线`.

- [x] **Step 5: Confirm the ACK removed the persisted queue item**

Run:

```bash
jq '.messages' work/e2e-registry.json
```

Expected: `{}`.

### Task 5: Run the complete regression gate and report evidence

**Files:**
- Verify: `relay/test/registry.test.mjs`
- Verify: `relay/test/server.test.mjs`
- Verify: `Sources/MacPet/**/*.swift`
- Verify: `web/app.js`

- [x] **Step 1: Run Relay tests without output filtering**

Run:

```bash
npm test --prefix relay
```

Expected: 29 tests pass and zero fail.

- [x] **Step 2: Run JavaScript syntax checks**

Run:

```bash
node --check relay/server.mjs
node --check web/app.js
```

Expected: both commands exit 0.

- [x] **Step 3: Build the native client**

Run:

```bash
swift build
```

Expected: `Build complete!` and exit 0.

- [x] **Step 4: Reconcile requirements against evidence**

Verify each UI expectation, the registry transition from one queued message to none, service health, full automated test output, JS syntax exit codes, and Swift build exit code. Report any failed requirement explicitly; do not call the feature accepted if any required observation is missing.

Run:

```bash
jq '{accepted, regression, browser_observations}' work/e2e-acceptance-result.json
```

Expected: `accepted` is true, every regression command has exit code 0, unexpected console/page error arrays are empty, and only connection-refused errors captured during the deliberate Relay outage appear in the expected-outage arrays.
