# Public Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace LAN-only discovery with a secure public WebSocket relay hosted at `happypuppy.io`.

**Architecture:** A Node.js relay maintains transient rooms keyed by a high-entropy pairing secret and forwards validated interaction messages only to the other connection in that room. Caddy terminates TLS and exposes the relay as `wss://happypuppy.io/ws`; the Mac client replaces Bonjour transport with `URLSessionWebSocketTask` while preserving `PetEvent` and pairing UI.

**Tech Stack:** Node.js 22, `ws`, Docker Compose, Caddy, Swift 6 `URLSessionWebSocketTask`, XCTest.

---

### Task 1: Build a tested relay service

**Files:**

- Create: `relay/package.json`
- Create: `relay/server.mjs`
- Create: `relay/Dockerfile`
- Create: `relay/test/server.test.mjs`

- [ ] **Step 1: Write a failing relay test**

```js
test('forwards a poke only to the other socket in the same room', async () => {
  const { a, b, c } = await connectThreeClients();
  a.send(JSON.stringify({ type: 'join', room: '64-char-secret', name: 'Alice' }));
  b.send(JSON.stringify({ type: 'join', room: '64-char-secret', name: 'Bob' }));
  c.send(JSON.stringify({ type: 'join', room: 'another-64-char-secret', name: 'Cara' }));
  a.send(JSON.stringify({ type: 'event', kind: 'poke', frameName: 'ai_buddy_00' }));
  expect(await nextMessage(b)).toMatchObject({ type: 'event', senderName: 'Alice', kind: 'poke' });
  await expectNoMessage(c);
});
```

- [ ] **Step 2: Run the test and verify failure**

Run: `npm test`

Expected: failure because relay files do not exist.

- [ ] **Step 3: Implement the protocol**

`join` requires a 32-byte hex room secret and a 1–32 character name. Each room accepts at most two sockets. `event` only accepts `poke`, `heart`, or `celebrate` plus a known frame name; the server adds `senderName`, never trusts a caller-supplied recipient, rate-limits each socket to 20 events/minute, and closes invalid clients with code 1008.

- [ ] **Step 4: Run the test and build image**

Run: `npm test && docker build -t macpet-relay ./relay`

Expected: all relay tests pass and Docker builds the image.

### Task 2: Add a Caddy deployment stack

**Files:**

- Create: `deploy/compose.yaml`
- Create: `deploy/Caddyfile`
- Create: `deploy/.env.example`

- [ ] **Step 1: Define exact proxy configuration**

```caddyfile
happypuppy.io {
  reverse_proxy /ws* relay:8080
}
```

`compose.yaml` publishes only `80:80` and `443:443` from Caddy, keeps the relay internal, restarts both services unless stopped, and persists Caddy certificate data in named volumes.

- [ ] **Step 2: Verify configuration**

Run: `docker compose -f deploy/compose.yaml config`

Expected: a valid rendered Compose configuration.

### Task 3: Install and deploy on the public server

**Files:**

- Create: `deploy/install-server.sh`
- Modify: `README.md`

- [ ] **Step 1: Install Docker Engine and Compose on Alibaba Cloud Linux**

Run: `ssh happypuppy 'sudo dnf install -y docker docker-compose-plugin && sudo systemctl enable --now docker'`

Expected: `docker --version` and `docker compose version` both succeed.

- [ ] **Step 2: Copy only deployment sources and launch**

Run: `rsync -az --delete relay deploy happypuppy:/opt/macpet/ && ssh happypuppy 'cd /opt/macpet && docker compose -f deploy/compose.yaml up -d --build'`

Expected: `relay` and `caddy` both report `running` in `docker compose ps`.

- [ ] **Step 3: Verify the public endpoint**

Run: `curl -fsSI https://happypuppy.io && wscat -c wss://happypuppy.io/ws`

Expected: a trusted TLS response and a successful WebSocket handshake.

### Task 4: Replace Bonjour with public pairing transport

**Files:**

- Modify: `Sources/MacPet/PetInteractionService.swift`
- Modify: `Sources/MacPet/AppModel.swift`
- Modify: `Sources/MacPet/PetView.swift`
- Modify: `Tests/MacPetTests/AppModelTests.swift`

- [ ] **Step 1: Write failing connection-state tests**

```swift
func testPairingSecretHasSixtyFourHexCharacters() {
    XCTAssertTrue(PublicPairingSecret.make().value.wholeMatch(of: /[0-9a-f]{64}/) != nil)
}
```

- [ ] **Step 2: Implement public pairing**

The first user creates a 64-hex-character secret represented as a short copyable code plus QR payload; the friend joins using that exact payload. Both clients connect only to `wss://happypuppy.io/ws`, emit `join`, and use server-delivered presence plus event messages. Remove Bonjour browsing and never expose device names before a successful room join.

- [ ] **Step 3: Run client tests and package**

Run: `swift test && packaging/package-app.sh`

Expected: all client tests pass and a signed local app bundle exists.

## Self-review

- The relay cannot broadcast across rooms, accepts only two room members, and validates all fields.
- TLS is terminated at Caddy; clients use WSS only.
- Server deploy is reproducible from the repository and requires no manually edited runtime code.
