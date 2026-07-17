import test from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { createRelayServer } from '../server.mjs';
import { PetRegistry, RegistryError } from '../registry.mjs';

const room = 'a'.repeat(64);

function connect(url, options = {}) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, options);
    socket.once('open', () => resolve(socket));
    socket.once('error', reject);
  });
}

function nextMessage(socket) {
  return new Promise((resolve) => socket.once('message', (data) => resolve(JSON.parse(data.toString()))));
}

function nextClose(socket) {
  return new Promise((resolve) => {
    socket.once('close', (code, reason) => resolve({ code, reason: reason.toString() }));
  });
}

function nextMessageWithin(socket, timeout = 300) {
  return Promise.race([
    nextMessage(socket),
    new Promise((_, reject) => setTimeout(() => reject(new Error('timed out waiting for websocket message')), timeout))
  ]);
}

async function nextMessageOfType(socket, type, timeout = 500) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const message = await nextMessageWithin(socket, Math.max(1, deadline - Date.now()));
    if (message.type === type) return message;
  }
  throw new Error(`timed out waiting for ${type}`);
}

test('serves a JSON health response', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());

  const response = await fetch(`http://127.0.0.1:${address.port}/health`);

  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'application/json');
  assert.deepEqual(await response.json(), { ok: true });
});

test('closes an oversized websocket frame before application parsing', async (context) => {
  const relay = createRelayServer({ maxPayload: 1_024 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const socket = await connect(url);
  context.after(() => socket.close());
  const closed = new Promise((resolve) => {
    socket.once('close', (code, reason) => resolve({ code, reason: reason.toString() }));
  });

  socket.send(JSON.stringify({ type: 'presence-register', padding: 'x'.repeat(2_048) }));

  assert.deepEqual(await closed, { code: 1009, reason: '' });
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/health`)).status, 200);
});

test('rejects JSON primitives without crashing the relay', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;

  for (const payload of ['null', '42', 'true', '"hello"', '[]']) {
    const socket = await connect(url);
    const rejected = nextMessage(socket);
    socket.send(payload);

    assert.deepEqual(await rejected, { type: 'error', message: 'invalid message' });
    assert.equal((await fetch(`http://127.0.0.1:${address.port}/health`)).status, 200);
  }
});

test('eagerly removes expired registry records while the relay is otherwise idle', async (context) => {
  let clock = 1_000;
  const registry = new PetRegistry({ now: () => clock, messageTTL: 20, requestPendingTTL: 20 });
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  registry.registerIdentity({
    peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  });
  const bob = registry.registerIdentity({
    peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  });
  registry.enqueueMessage({
    id: '0'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'expires'
  });
  registry.createFriendRequest({ fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice' });
  const relay = createRelayServer({ registry, messageCleanupInterval: 5 });
  await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());

  clock += 21;
  await new Promise((resolve) => setTimeout(resolve, 30));

  assert.equal(Object.keys(registry.state.messages).length, 0);
  assert.equal(Object.keys(registry.state.requests).length, 0);
});

test('contains background registry cleanup failures and keeps serving', async (context) => {
  const registry = new PetRegistry();
  const originalMessageCleanup = registry.purgeExpiredMessages.bind(registry);
  const originalRequestCleanup = registry.purgeExpiredRequests.bind(registry);
  let messageCleanupCalls = 0;
  let requestCleanupCalls = 0;
  registry.purgeExpiredMessages = () => {
    messageCleanupCalls += 1;
    if (messageCleanupCalls === 1) throw new Error('message persistence failed');
    return originalMessageCleanup();
  };
  registry.purgeExpiredRequests = () => {
    requestCleanupCalls += 1;
    if (requestCleanupCalls === 1) throw new Error('request persistence failed');
    return originalRequestCleanup();
  };
  const backgroundErrors = [];
  const relay = createRelayServer({
    registry,
    messageCleanupInterval: 5,
    onBackgroundError: (error) => backgroundErrors.push(error)
  });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());

  await new Promise((resolve) => setTimeout(resolve, 30));

  assert.deepEqual(backgroundErrors.map((error) => error.message), [
    'message persistence failed',
    'request persistence failed'
  ]);
  assert.ok(messageCleanupCalls >= 2);
  assert.ok(requestCleanupCalls >= 2);
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/health`)).status, 200);
});

test('assigns permanent pet codes and routes an accepted friend request', async (context) => {
  let nextCode = 345678;
  const relay = createRelayServer({ registry: new PetRegistry({ randomIntFn: () => nextCode++ }) });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);

  const aliceCode = nextMessageOfType(alice, 'pet-code');
  const bobCode = nextMessageOfType(bob, 'pet-code');
  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  }));
  bob.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  }));
  assert.deepEqual(await aliceCode, { type: 'pet-code', petCode: '345678' });
  assert.deepEqual(await bobCode, { type: 'pet-code', petCode: '345679' });

  const incoming = nextMessageOfType(bob, 'friend-request-incoming');
  const created = nextMessageOfType(alice, 'friend-request-created');
  alice.send(JSON.stringify({ type: 'friend-request-create', petCode: '345679' }));
  const request = await incoming;
  assert.equal(request.senderPeerID, aliceID);
  assert.equal(request.senderName, 'Alice');
  assert.equal((await created).requestID, request.requestID);

  const aliceAccepted = nextMessageOfType(alice, 'friend-request-accepted');
  const bobAccepted = nextMessageOfType(bob, 'friend-request-accepted');
  bob.send(JSON.stringify({ type: 'friend-request-respond', requestID: request.requestID, accept: true }));
  assert.deepEqual(await aliceAccepted, {
    type: 'friend-request-accepted', requestID: request.requestID, peerID: bobID, name: 'Bob'
  });
  assert.deepEqual(await bobAccepted, {
    type: 'friend-request-accepted', requestID: request.requestID, peerID: aliceID, name: 'Alice'
  });
});

test('requires the device token after a peer id has been claimed', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const peerID = 'a'.repeat(32);
  const owner = await connect(url);
  const registered = nextMessage(owner);
  owner.send(JSON.stringify({
    type: 'presence-register', peerID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  }));
  assert.equal((await registered).type, 'pet-code');
  assert.equal(registry.identity(peerID)?.name, 'Alice');

  const impostor = await connect(url);
  context.after(() => [owner, impostor].forEach((socket) => socket.close()));
  const rejected = Promise.race([
    nextMessage(impostor).then((message) => ({ message })),
    new Promise((resolve) => impostor.once('close', (code, reason) => resolve({ code, reason: reason.toString() })))
  ]);
  impostor.send(JSON.stringify({ type: 'presence-register', peerID, name: 'Mallory', friendPeerIDs: [] }));

  assert.deepEqual(await rejected, { message: { type: 'error', message: 'authentication required' } });
});

test('rate limits new identity creation by source address before persistence', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry, newIdentityAddressRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const socket = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => socket.close());
  const messages = collect(socket);
  socket.send(JSON.stringify({
    type: 'presence-register', peerID: 'a'.repeat(32), authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(messages, 'presence-snapshot');

  socket.send(JSON.stringify({
    type: 'presence-register', peerID: 'b'.repeat(32), authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  }));

  assert.deepEqual(await waitForType(messages, 'error'), { type: 'error', message: 'rate limit' });
  assert.equal(Object.keys(registry.state.identities).length, 1);
});

test('ignores spoofed forwarded addresses unless a proxy is explicitly trusted', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry, newIdentityAddressRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const first = await connect(url, { headers: { 'x-forwarded-for': '198.51.100.10' } });
  const second = await connect(url, { headers: { 'x-forwarded-for': '203.0.113.20' } });
  context.after(() => [first, second].forEach((socket) => socket.close()));
  const firstMessages = collect(first);
  const secondMessages = collect(second);

  first.send(JSON.stringify({
    type: 'presence-register', peerID: 'a'.repeat(32), authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(firstMessages, 'presence-snapshot');
  second.send(JSON.stringify({
    type: 'presence-register', peerID: 'b'.repeat(32), authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  }));

  assert.deepEqual(await waitForType(secondMessages, 'error'), { type: 'error', message: 'rate limit' });
  assert.equal(Object.keys(registry.state.identities).length, 1);
});

test('uses forwarded addresses when the deployment explicitly trusts its proxy', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry, newIdentityAddressRateLimit: 1, trustProxy: true });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const first = await connect(url, { headers: { 'x-forwarded-for': '198.51.100.10' } });
  const second = await connect(url, { headers: { 'x-forwarded-for': '203.0.113.20' } });
  context.after(() => [first, second].forEach((socket) => socket.close()));
  const firstMessages = collect(first);
  const secondMessages = collect(second);

  first.send(JSON.stringify({
    type: 'presence-register', peerID: 'a'.repeat(32), authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(firstMessages, 'presence-snapshot');
  second.send(JSON.stringify({
    type: 'presence-register', peerID: 'b'.repeat(32), authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  }));

  assert.deepEqual(await waitForType(secondMessages, 'presence-snapshot'), {
    type: 'presence-snapshot', onlinePeerIDs: []
  });
  assert.equal(Object.keys(registry.state.identities).length, 2);
});

test('rate limits authenticated identity registration across reconnects before persistence', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry, presenceRegistrationRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const first = await connect(url);
  const firstMessages = collect(first);
  const registration = {
    type: 'presence-register', peerID: 'a'.repeat(32), authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  };
  first.send(JSON.stringify(registration));
  await waitForType(firstMessages, 'presence-snapshot');
  await new Promise((resolve) => {
    first.once('close', resolve);
    first.close();
  });

  const replacement = await connect(url);
  context.after(() => replacement.close());
  const replacementMessages = collect(replacement);
  replacement.send(JSON.stringify(registration));

  assert.deepEqual(await waitForType(replacementMessages, 'error'), { type: 'error', message: 'rate limit' });
  assert.equal(registry.identity('a'.repeat(32))?.name, 'Alice');
});

test('forwards an event only to the other socket in the room', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob, cara] = await Promise.all([connect(url), connect(url), connect(url)]);
  context.after(() => [alice, bob, cara].forEach((socket) => socket.close()));
  alice.send(JSON.stringify({ type: 'join', room, name: 'Alice' }));
  await nextMessage(alice);
  bob.send(JSON.stringify({ type: 'join', room, name: 'Bob' }));
  await nextMessage(bob);
  cara.send(JSON.stringify({ type: 'join', room: 'b'.repeat(64), name: 'Cara' }));
  await nextMessage(cara);
  const received = nextMessage(bob);
  alice.send(JSON.stringify({ type: 'event', kind: 'poke', frameName: 'ai_buddy_00' }));
  assert.deepEqual(await received, { type: 'event', kind: 'poke', frameName: 'ai_buddy_00', senderName: 'Alice' });
});

test('forwards profile changes and uses the new name for later events', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));

  alice.send(JSON.stringify({ type: 'join', room, name: 'Alice' }));
  await nextMessage(alice);
  bob.send(JSON.stringify({ type: 'join', room, name: 'Bob' }));
  await nextMessage(bob);
  await nextMessage(alice);

  const renamed = nextMessage(bob);
  alice.send(JSON.stringify({ type: 'profile', name: 'Alicia' }));
  assert.deepEqual(await renamed, { type: 'profile', peerName: 'Alicia' });

  const received = nextMessage(bob);
  alice.send(JSON.stringify({ type: 'event', kind: 'poke', frameName: 'ai_buddy_00' }));
  assert.deepEqual(await received, { type: 'event', kind: 'poke', frameName: 'ai_buddy_00', senderName: 'Alicia' });
});

test('matches uppercase and lowercase forms of the same pairing code', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const uppercaseRoom = 'ABCD2345';
  const lowercaseRoom = uppercaseRoom.toLowerCase();

  alice.send(JSON.stringify({ type: 'join', room: uppercaseRoom, name: 'Alice' }));
  assert.deepEqual(await nextMessage(alice), { type: 'joined', connected: 1, peerName: null });
  const alicePresence = nextMessage(alice);
  bob.send(JSON.stringify({ type: 'join', room: lowercaseRoom, name: 'Bob' }));
  assert.deepEqual(await nextMessage(bob), { type: 'joined', connected: 2, peerName: 'Alice' });
  assert.deepEqual(await alicePresence, { type: 'presence', connected: 2, peerName: 'Bob' });
});

test('accepts a four digit pairing code', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const alice = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => alice.close());

  alice.send(JSON.stringify({ type: 'join', room: '2048', name: 'Alice' }));

  assert.deepEqual(await nextMessage(alice), { type: 'joined', connected: 1, peerName: null });
});

test('expires an unjoined pairing room', async (context) => {
  const relay = createRelayServer({ pairingTTL: 25 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const alice = await connect(url);
  context.after(() => alice.close());
  alice.send(JSON.stringify({ type: 'join', room: 'ABCD2345', name: 'Alice' }));
  assert.deepEqual(await nextMessage(alice), { type: 'joined', connected: 1, peerName: null });
  const expired = await Promise.race([
    nextMessage(alice),
    new Promise((resolve) => setTimeout(() => resolve(null), 100))
  ]);
  assert.deepEqual(expired, { type: 'error', message: '配对码已过期' });
});

test('propagates stable profile IDs with presence and profile updates', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  alice.send(JSON.stringify({ type: 'join', room, name: 'Alice', peerID: aliceID }));
  await nextMessage(alice);
  const alicePresence = nextMessage(alice);
  bob.send(JSON.stringify({ type: 'join', room, name: 'Bob', peerID: bobID }));
  assert.deepEqual(await nextMessage(bob), { type: 'joined', connected: 2, peerName: 'Alice', peerID: aliceID });
  assert.deepEqual(await alicePresence, { type: 'presence', connected: 2, peerName: 'Bob', peerID: bobID });
  const renamed = nextMessage(bob);
  alice.send(JSON.stringify({ type: 'profile', name: 'Alicia', peerID: aliceID }));
  assert.deepEqual(await renamed, { type: 'profile', peerName: 'Alicia', peerID: aliceID });
});

test('reports online snapshots and realtime friend presence changes', async (context) => {
  const relay = createRelayServer({ presenceOfflineGrace: 0 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);

  alice.send(JSON.stringify({ type: 'presence-register', peerID: aliceID, name: 'Alice', friendPeerIDs: [bobID] }));
  assert.deepEqual(await nextMessage(alice), { type: 'presence-snapshot', onlinePeerIDs: [] });

  const bobOnline = nextMessage(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [aliceID] }));
  assert.deepEqual(await nextMessage(bob), { type: 'presence-snapshot', onlinePeerIDs: [aliceID] });
  assert.deepEqual(await bobOnline, { type: 'friend-presence', peerID: bobID, online: true });

  const bobOffline = nextMessage(alice);
  bob.close();
  assert.deepEqual(await bobOffline, { type: 'friend-presence', peerID: bobID, online: false });
});

test('does not flash offline when a friend reconnects within the grace period', async (context) => {
  const relay = createRelayServer({ presenceOfflineGrace: 80 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);

  alice.send(JSON.stringify({ type: 'presence-register', peerID: aliceID, name: 'Alice', friendPeerIDs: [bobID] }));
  await nextMessage(alice);
  const bobOnline = nextMessage(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [aliceID] }));
  await nextMessage(bob);
  await bobOnline;

  const observed = [];
  alice.on('message', (data) => observed.push(JSON.parse(data.toString())));
  bob.close();
  await new Promise((resolve) => setTimeout(resolve, 25));
  const replacement = await connect(url);
  context.after(() => replacement.close());
  replacement.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [aliceID] }));
  await nextMessage(replacement);
  await new Promise((resolve) => setTimeout(resolve, 100));

  assert.equal(observed.some((message) => message.type === 'friend-presence' && message.peerID === bobID && message.online === false), false);
});

test('reports a friend online only while both profiles keep each other', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);

  alice.send(JSON.stringify({ type: 'presence-register', peerID: aliceID, name: 'Alice', friendPeerIDs: [bobID] }));
  assert.deepEqual(await nextMessage(alice), { type: 'presence-snapshot', onlinePeerIDs: [] });

  const stillOffline = nextMessageWithin(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [] }));
  assert.deepEqual(await nextMessage(bob), { type: 'presence-snapshot', onlinePeerIDs: [] });
  assert.deepEqual(await stillOffline, { type: 'friend-presence', peerID: bobID, online: false });

  const nowMutual = nextMessageWithin(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [aliceID] }));
  assert.deepEqual(await nextMessage(bob), { type: 'presence-snapshot', onlinePeerIDs: [aliceID] });
  assert.deepEqual(await nowMutual, { type: 'friend-presence', peerID: bobID, online: true });

  const removedByBob = nextMessageWithin(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [] }));
  assert.deepEqual(await nextMessage(bob), { type: 'presence-snapshot', onlinePeerIDs: [] });
  assert.deepEqual(await removedByBob, { type: 'friend-presence', peerID: bobID, online: false });
});

test('notifies mutual friends when a pet name changes', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);

  alice.send(JSON.stringify({ type: 'presence-register', peerID: aliceID, name: 'Alice', friendPeerIDs: [bobID] }));
  await nextMessage(alice);
  const bobOnline = nextMessageOfType(alice, 'friend-presence');
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [aliceID] }));
  await nextMessage(bob);
  await bobOnline;

  const renamed = nextMessageOfType(alice, 'friend-profile');
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bobby', friendPeerIDs: [aliceID] }));

  assert.deepEqual(await renamed, { type: 'friend-profile', peerID: bobID, name: 'Bobby' });
});

test('routes friend events by stable profile ID only for mutual online friends', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);

  alice.send(JSON.stringify({ type: 'presence-register', peerID: aliceID, name: 'Alice', friendPeerIDs: [bobID] }));
  await nextMessage(alice);
  const aliceSeesBob = nextMessage(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [aliceID] }));
  await nextMessage(bob);
  await aliceSeesBob;

  const received = nextMessageWithin(bob);
  alice.send(JSON.stringify({ type: 'friend-event', targetPeerID: bobID, kind: 'heart', frameName: 'ai_buddy_03' }));
  assert.deepEqual(await received, {
    type: 'friend-event',
    kind: 'heart',
    frameName: 'ai_buddy_03',
    senderName: 'Alice',
    senderPeerID: aliceID
  });

  const delivered = nextMessageWithin(alice);
  alice.send(JSON.stringify({
    type: 'friend-event',
    eventID: 'e'.repeat(32),
    targetPeerID: bobID,
    kind: 'poke',
    frameName: 'ai_buddy_07'
  }));
  assert.deepEqual(await nextMessageWithin(bob), {
    type: 'friend-event',
    kind: 'poke',
    frameName: 'ai_buddy_07',
    senderName: 'Alice',
    senderPeerID: aliceID
  });
  assert.deepEqual(await delivered, { type: 'friend-event-delivered', eventID: 'e'.repeat(32) });

  const aliceSeesRemoval = nextMessageWithin(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [] }));
  assert.deepEqual(await nextMessage(bob), { type: 'presence-snapshot', onlinePeerIDs: [] });
  assert.deepEqual(await aliceSeesRemoval, { type: 'friend-presence', peerID: bobID, online: false });

  const rejected = nextMessageWithin(alice);
  alice.send(JSON.stringify({
    type: 'friend-event',
    eventID: 'f'.repeat(32),
    targetPeerID: bobID,
    kind: 'poke',
    frameName: 'ai_buddy_00'
  }));
  assert.deepEqual(await rejected, {
    type: 'friend-event-rejected',
    targetPeerID: bobID,
    message: 'friend unavailable',
    eventID: 'f'.repeat(32)
  });
});

test('removes an unresponsive presence session from friend online state', async (context) => {
  const relay = createRelayServer({ heartbeatInterval: 15, presenceOfflineGrace: 0 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const alice = await connect(url);
  const bob = await connect(url, { autoPong: false });
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);

  alice.send(JSON.stringify({ type: 'presence-register', peerID: aliceID, name: 'Alice', friendPeerIDs: [bobID] }));
  await nextMessage(alice);
  const bobOnline = nextMessageWithin(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [aliceID] }));
  await nextMessage(bob);
  assert.deepEqual(await bobOnline, { type: 'friend-presence', peerID: bobID, online: true });

  assert.deepEqual(await nextMessageWithin(alice, 250), {
    type: 'friend-presence',
    peerID: bobID,
    online: false
  });
});

// Authenticated presence yields pet-code and presence-snapshot back to back, so
// tests collect every frame and poll by type instead of consuming one at a time.
function collect(socket) {
  const messages = [];
  socket.on('message', (data) => messages.push(JSON.parse(data.toString())));
  return messages;
}

async function waitForType(messages, type, timeout = 700) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const found = messages.find((message) => message.type === type);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`timed out waiting for ${type}`);
}

async function waitForAnyType(messages, types, timeout = 700) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const found = messages.find((message) => types.includes(message.type));
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`timed out waiting for one of: ${types.join(', ')}`);
}

async function waitForTypeCount(messages, type, count, timeout = 700) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const found = messages.filter((message) => message.type === type);
    if (found.length >= count) return found[count - 1];
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`timed out waiting for ${type} #${count}`);
}

async function registerMutualFriends(url, context) {
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceMessages = collect(alice);
  const bobMessages = collect(bob);
  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  bob.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  }));
  await waitForType(aliceMessages, 'presence-snapshot');
  await waitForType(bobMessages, 'presence-snapshot');
  return { alice, bob, aliceID, bobID, aliceMessages, bobMessages };
}

test('rejects an unauthenticated friend request ACK before calling the registry', async (context) => {
  const registry = new PetRegistry();
  let acknowledgementCalls = 0;
  registry.acknowledgeRequest = () => {
    acknowledgementCalls += 1;
    return false;
  };
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const socket = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => socket.close());
  const messages = collect(socket);
  socket.send(JSON.stringify({
    type: 'presence-register', peerID: 'a'.repeat(32), name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(messages, 'presence-snapshot');
  const closed = nextClose(socket);

  socket.send(JSON.stringify({ type: 'friend-request-ack', requestID: '1'.repeat(32) }));

  assert.deepEqual(await waitForType(messages, 'error'), {
    type: 'error', message: 'authentication required'
  });
  assert.deepEqual(await closed, { code: 1008, reason: 'authentication required' });
  assert.equal(acknowledgementCalls, 0);
});

test('rejects an unauthenticated friend message ACK before calling the registry', async (context) => {
  const registry = new PetRegistry();
  let acknowledgementCalls = 0;
  registry.acknowledgeMessage = () => {
    acknowledgementCalls += 1;
    return false;
  };
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const socket = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => socket.close());
  const messages = collect(socket);
  socket.send(JSON.stringify({
    type: 'presence-register', peerID: 'a'.repeat(32), name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(messages, 'presence-snapshot');
  const closed = nextClose(socket);

  socket.send(JSON.stringify({ type: 'friend-message-ack', messageID: '2'.repeat(32) }));

  assert.deepEqual(await waitForType(messages, 'error'), {
    type: 'error', message: 'authentication required'
  });
  assert.deepEqual(await closed, { code: 1008, reason: 'authentication required' });
  assert.equal(acknowledgementCalls, 0);
});

test('does not let an unauthenticated ACK poison the later authenticated peer limit', async (context) => {
  const registry = new PetRegistry();
  const peerID = 'a'.repeat(32);
  const authToken = '1'.repeat(64);
  let acknowledgementCalls = 0;
  let resolveAuthenticatedAcknowledgement;
  const authenticatedAcknowledgement = new Promise((resolve) => {
    resolveAuthenticatedAcknowledgement = resolve;
  });
  registry.acknowledgeRequest = () => {
    acknowledgementCalls += 1;
    resolveAuthenticatedAcknowledgement();
    return false;
  };
  const relay = createRelayServer({ registry, ackRateLimit: 1, ackAddressRateLimit: 100 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const unauthenticated = await connect(url);
  context.after(() => unauthenticated.close());
  const unauthenticatedMessages = collect(unauthenticated);
  unauthenticated.send(JSON.stringify({
    type: 'presence-register', peerID, name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(unauthenticatedMessages, 'presence-snapshot');
  unauthenticated.send(JSON.stringify({ type: 'friend-request-ack', requestID: '7'.repeat(32) }));
  await waitForType(unauthenticatedMessages, 'error');
  assert.equal(acknowledgementCalls, 0);

  const authenticated = await connect(url);
  context.after(() => authenticated.close());
  const authenticatedMessages = collect(authenticated);
  authenticated.send(JSON.stringify({
    type: 'presence-register', peerID, authToken, name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(authenticatedMessages, 'presence-snapshot');
  authenticated.send(JSON.stringify({ type: 'friend-request-ack', requestID: '8'.repeat(32) }));
  const outcome = await Promise.race([
    authenticatedAcknowledgement.then(() => 'registry-called'),
    nextMessageWithin(authenticated).then((message) => message.message)
  ]);

  assert.equal(outcome, 'registry-called');
  assert.equal(acknowledgementCalls, 1);
});

test('shares one ACK limit across message types and reconnects for a stable peer ID', async (context) => {
  const registry = new PetRegistry();
  const peerID = 'a'.repeat(32);
  const authToken = '1'.repeat(64);
  registry.registerIdentity({ peerID, authToken, name: 'Alice', friendPeerIDs: [] });
  const originalAcknowledgeRequest = registry.acknowledgeRequest.bind(registry);
  let requestAcknowledgements = 0;
  let messageAcknowledgements = 0;
  let resolveFirstAcknowledgement;
  const firstAcknowledgement = new Promise((resolve) => { resolveFirstAcknowledgement = resolve; });
  registry.acknowledgeRequest = (payload) => {
    requestAcknowledgements += 1;
    resolveFirstAcknowledgement();
    return originalAcknowledgeRequest(payload);
  };
  registry.acknowledgeMessage = () => {
    messageAcknowledgements += 1;
    return false;
  };
  const relay = createRelayServer({ registry, ackRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const first = await connect(url);
  context.after(() => first.close());
  const firstMessages = collect(first);
  const registration = { type: 'presence-register', peerID, authToken, name: 'Alice', friendPeerIDs: [] };
  first.send(JSON.stringify(registration));
  await waitForType(firstMessages, 'presence-snapshot');
  first.send(JSON.stringify({ type: 'friend-request-ack', requestID: '3'.repeat(32) }));
  await firstAcknowledgement;
  await new Promise((resolve) => {
    first.once('close', resolve);
    first.close();
  });

  const second = await connect(url);
  context.after(() => second.close());
  const secondMessages = collect(second);
  second.send(JSON.stringify(registration));
  await waitForType(secondMessages, 'presence-snapshot');
  const closed = nextClose(second);

  second.send(JSON.stringify({ type: 'friend-message-ack', messageID: '4'.repeat(32) }));

  assert.deepEqual(await waitForType(secondMessages, 'error'), { type: 'error', message: 'rate limit' });
  assert.deepEqual(await closed, { code: 1008, reason: 'rate limit' });
  assert.equal(requestAcknowledgements, 1);
  assert.equal(messageAcknowledgements, 0);
});

test('shares one ACK address limit across authenticated identities', async (context) => {
  const registry = new PetRegistry();
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  registry.registerIdentity({
    peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  });
  registry.registerIdentity({
    peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  });
  const originalAcknowledgeRequest = registry.acknowledgeRequest.bind(registry);
  let requestAcknowledgements = 0;
  let messageAcknowledgements = 0;
  let resolveFirstAcknowledgement;
  const firstAcknowledgement = new Promise((resolve) => { resolveFirstAcknowledgement = resolve; });
  registry.acknowledgeRequest = (payload) => {
    requestAcknowledgements += 1;
    resolveFirstAcknowledgement();
    return originalAcknowledgeRequest(payload);
  };
  registry.acknowledgeMessage = () => {
    messageAcknowledgements += 1;
    return false;
  };
  const relay = createRelayServer({ registry, ackAddressRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceMessages = collect(alice);
  const bobMessages = collect(bob);
  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  }));
  bob.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  }));
  await waitForType(aliceMessages, 'presence-snapshot');
  await waitForType(bobMessages, 'presence-snapshot');
  alice.send(JSON.stringify({ type: 'friend-request-ack', requestID: '5'.repeat(32) }));
  await firstAcknowledgement;
  const closed = nextClose(bob);

  bob.send(JSON.stringify({ type: 'friend-message-ack', messageID: '6'.repeat(32) }));

  assert.deepEqual(await waitForType(bobMessages, 'error'), { type: 'error', message: 'rate limit' });
  assert.deepEqual(await closed, { code: 1008, reason: 'rate limit' });
  assert.equal(requestAcknowledgements, 1);
  assert.equal(messageAcknowledgements, 0);
});

test('closes with a retryable error when a valid friend request ACK cannot be persisted', async (context) => {
  const registry = new PetRegistry();
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  registry.registerIdentity({
    peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  });
  const bob = registry.registerIdentity({
    peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  });
  const request = registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
  });
  registry.respondToFriendRequest({ requestID: request.id, responderPeerID: bobID, accept: true });
  const internalErrors = [];
  const relay = createRelayServer({ registry, onInternalError: (error) => internalErrors.push(error) });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const socket = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => socket.close());
  const messages = collect(socket);
  socket.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  await waitForType(messages, 'presence-snapshot');
  registry.acknowledgeRequest = () => {
    throw new RegistryError(
      'registry-write-failed',
      'cannot write registry: /srv/macpet/private/registry.json'
    );
  };
  const closed = nextClose(socket);

  socket.send(JSON.stringify({ type: 'friend-request-ack', requestID: request.id }));

  const clientError = await waitForType(messages, 'error');
  assert.deepEqual(clientError, { type: 'error', message: 'temporary server error' });
  assert.equal(JSON.stringify(clientError).includes('/srv/macpet/private/registry.json'), false);
  assert.deepEqual(await closed, { code: 1011, reason: 'temporary server error' });
  assert.equal(internalErrors[0]?.message, 'cannot write registry: /srv/macpet/private/registry.json');
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/health`)).status, 200);
});

test('closes with a retryable error when a valid friend message ACK throws synchronously', async (context) => {
  const registry = new PetRegistry();
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  registry.registerIdentity({
    peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  });
  registry.registerIdentity({
    peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  });
  const stored = registry.enqueueMessage({
    id: 'd'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'persist me'
  });
  const internalErrors = [];
  const relay = createRelayServer({ registry, onInternalError: (error) => internalErrors.push(error) });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const socket = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => socket.close());
  const messages = collect(socket);
  socket.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  }));
  await waitForType(messages, 'friend-message-incoming');
  registry.acknowledgeMessage = () => {
    throw new Error('synchronous registry failure at /srv/macpet/private/registry.json');
  };
  const closed = nextClose(socket);

  socket.send(JSON.stringify({ type: 'friend-message-ack', messageID: stored.id }));

  const clientError = await waitForType(messages, 'error');
  assert.deepEqual(clientError, { type: 'error', message: 'temporary server error' });
  assert.equal(JSON.stringify(clientError).includes('/srv/macpet/private/registry.json'), false);
  assert.deepEqual(await closed, { code: 1011, reason: 'temporary server error' });
  assert.equal(internalErrors[0]?.message, 'synchronous registry failure at /srv/macpet/private/registry.json');
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/health`)).status, 200);
});

test('does not expose registry paths when identity persistence fails inside an existing catch', async (context) => {
  const registry = new PetRegistry();
  registry.registerIdentity = () => {
    throw new RegistryError(
      'registry-write-failed',
      'cannot write registry: /srv/macpet/private/registry.json'
    );
  };
  const internalErrors = [];
  const relay = createRelayServer({ registry, onInternalError: (error) => internalErrors.push(error) });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const socket = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => socket.close());
  const messages = collect(socket);
  const closed = nextClose(socket);

  socket.send(JSON.stringify({
    type: 'presence-register',
    peerID: 'a'.repeat(32),
    authToken: '1'.repeat(64),
    name: 'Alice',
    friendPeerIDs: []
  }));

  const clientError = await waitForType(messages, 'error');
  assert.deepEqual(clientError, { type: 'error', message: 'temporary server error' });
  assert.equal(JSON.stringify(clientError).includes('/srv/macpet/private/registry.json'), false);
  assert.deepEqual(await closed, { code: 1011, reason: 'temporary server error' });
  assert.equal(internalErrors[0]?.message, 'cannot write registry: /srv/macpet/private/registry.json');
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/health`)).status, 200);
});

test('delivers a text message to an online friend and confirms it to the sender', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, aliceID, bobID, aliceMessages, bobMessages } = await registerMutualFriends(url, context);

  const messageID = 'e'.repeat(32);
  alice.send(JSON.stringify({ type: 'friend-message-send', messageID, targetPeerID: bobID, kind: 'text', body: '  你好  ' }));
  const received = await waitForType(bobMessages, 'friend-message-incoming');

  assert.equal(received.messageID, messageID);
  assert.equal(received.senderPeerID, aliceID);
  assert.equal(received.senderName, 'Alice');
  assert.equal(received.kind, 'text');
  assert.equal(received.body, '你好');
  assert.equal((await waitForType(aliceMessages, 'friend-message-sent')).messageID, messageID);
});

test('queues a message for an offline friend and delivers it on reconnect', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);

  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  const sockets = [alice, bob];
  context.after(() => sockets.forEach((socket) => socket.close()));
  const aliceMessages = collect(alice);
  const bobMessages = collect(bob);
  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  bob.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  }));
  await waitForType(aliceMessages, 'presence-snapshot');
  await waitForType(bobMessages, 'presence-snapshot');
  await new Promise((resolve) => {
    bob.once('close', resolve);
    bob.close();
  });

  const messageID = 'e'.repeat(32);
  alice.send(JSON.stringify({ type: 'friend-message-send', messageID, targetPeerID: bobID, kind: 'text', body: '留个言' }));
  assert.equal((await waitForType(aliceMessages, 'friend-message-sent')).messageID, messageID);
  assert.equal(registry.messagesFor(bobID).length, 1);

  const reconnectedBob = await connect(url);
  sockets.push(reconnectedBob);
  const reconnectedMessages = collect(reconnectedBob);
  reconnectedBob.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  }));
  const received = await waitForType(reconnectedMessages, 'friend-message-incoming');
  assert.equal(received.messageID, messageID);
  assert.equal(received.body, '留个言');
  assert.equal(received.senderPeerID, aliceID);
  assert.equal(registry.messagesFor(bobID).length, 1);

  await new Promise((resolve) => {
    reconnectedBob.once('close', resolve);
    reconnectedBob.close();
  });
  const secondReconnect = await connect(url);
  sockets.push(secondReconnect);
  const secondReconnectMessages = collect(secondReconnect);
  secondReconnect.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  }));
  const redelivered = await waitForType(secondReconnectMessages, 'friend-message-incoming');
  assert.equal(redelivered.messageID, messageID);
  assert.equal(redelivered.body, '留个言');
  assert.equal(registry.messagesFor(bobID).length, 1);

  secondReconnect.send(JSON.stringify({ type: 'friend-message-ack', messageID: redelivered.messageID }));
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(registry.messagesFor(bobID).length, 0);
});

test('delivers a preset sticker and rejects an unknown sticker id', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, bobID, aliceMessages, bobMessages } = await registerMutualFriends(url, context);

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: 'e'.repeat(32), targetPeerID: bobID, kind: 'sticker', body: 'sticker_love'
  }));
  assert.equal((await waitForType(bobMessages, 'friend-message-incoming')).body, 'sticker_love');

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: 'f'.repeat(32), targetPeerID: bobID, kind: 'sticker', body: 'sticker_unknown'
  }));
  assert.equal((await waitForType(aliceMessages, 'error')).message, 'invalid friend message');
});

test('refuses to send a message to someone who is not a friend', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const alice = await connect(url);
  context.after(() => alice.close());
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  const aliceMessages = collect(alice);

  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(aliceMessages, 'presence-snapshot');
  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: 'e'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'hi'
  }));

  assert.equal((await waitForType(aliceMessages, 'friend-message-failed')).message, 'not friends');
});

test('does not queue a message for a one-way friend', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [alice, bob] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [alice, bob].forEach((socket) => socket.close()));
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  const aliceMessages = collect(alice);
  const bobMessages = collect(bob);

  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  bob.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  }));
  await waitForType(aliceMessages, 'presence-snapshot');
  await waitForType(bobMessages, 'presence-snapshot');

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '1'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'hi'
  }));

  assert.deepEqual(await waitForAnyType(aliceMessages, ['friend-message-failed', 'friend-message-sent']), {
    type: 'friend-message-failed', messageID: '1'.repeat(32), message: 'not friends'
  });
  assert.equal(registry.messagesFor(bobID).length, 0);
});

test('does not queue a message after the recipient removed the sender', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, bob, aliceID, bobID, aliceMessages, bobMessages } = await registerMutualFriends(url, context);
  const staleBob = await connect(url);
  context.after(() => staleBob.close());
  const staleBobMessages = collect(staleBob);
  staleBob.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  }));
  await waitForType(staleBobMessages, 'presence-snapshot');

  bob.send(JSON.stringify({
    type: 'friend-remove', targetPeerID: aliceID
  }));
  assert.deepEqual(await waitForType(bobMessages, 'friend-removed'), {
    type: 'friend-removed', peerID: aliceID
  });
  staleBob.send(JSON.stringify({
    type: 'presence-register', peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  }));
  await waitForTypeCount(staleBobMessages, 'presence-snapshot', 2);
  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  await waitForTypeCount(aliceMessages, 'presence-snapshot', 2);
  alice.send(JSON.stringify({
    type: 'friend-event', eventID: 'f'.repeat(32), targetPeerID: bobID, kind: 'poke', frameName: 'ai_buddy_07'
  }));
  assert.deepEqual(await waitForType(aliceMessages, 'friend-event-rejected'), {
    type: 'friend-event-rejected',
    targetPeerID: bobID,
    message: 'friend unavailable',
    eventID: 'f'.repeat(32)
  });
  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '2'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'still there?'
  }));

  assert.deepEqual(await waitForAnyType(aliceMessages, ['friend-message-failed', 'friend-message-sent']), {
    type: 'friend-message-failed', messageID: '2'.repeat(32), message: 'not friends'
  });
  assert.equal(registry.messagesFor(bobID).length, 0);
});

test('reconciles a persisted removal when the offline friend reconnects with a stale list', async (context) => {
  const relay = createRelayServer({ presenceOfflineGrace: 0 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, bob, aliceID, bobID, bobMessages } = await registerMutualFriends(url, context);
  await new Promise((resolve) => {
    alice.once('close', resolve);
    alice.close();
  });

  bob.send(JSON.stringify({ type: 'friend-remove', targetPeerID: aliceID }));
  assert.deepEqual(await waitForType(bobMessages, 'friend-removed'), {
    type: 'friend-removed', peerID: aliceID
  });

  const reconnectedAlice = await connect(url);
  context.after(() => reconnectedAlice.close());
  const reconnectedMessages = collect(reconnectedAlice);
  reconnectedAlice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));

  assert.deepEqual(await waitForType(reconnectedMessages, 'presence-snapshot'), {
    type: 'presence-snapshot', onlinePeerIDs: []
  });
  assert.deepEqual(await waitForType(reconnectedMessages, 'friend-removed'), {
    type: 'friend-removed', peerID: bobID
  });
});

test('shares friend removal limits across reconnects for the same identity', async (context) => {
  const registry = new PetRegistry();
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  const caraID = 'c'.repeat(32);
  registry.registerIdentity({
    peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID, caraID]
  });
  registry.registerIdentity({
    peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: [aliceID]
  });
  registry.registerIdentity({
    peerID: caraID, authToken: '3'.repeat(64), name: 'Cara', friendPeerIDs: [aliceID]
  });
  const relay = createRelayServer({ registry, friendRemovalRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const alice = await connect(url);
  const aliceMessages = collect(alice);
  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID, caraID]
  }));
  await waitForType(aliceMessages, 'presence-snapshot');
  alice.send(JSON.stringify({ type: 'friend-remove', targetPeerID: bobID }));
  await waitForType(aliceMessages, 'friend-removed');
  await new Promise((resolve) => {
    alice.once('close', resolve);
    alice.close();
  });

  const replacement = await connect(url);
  context.after(() => replacement.close());
  const replacementMessages = collect(replacement);
  replacement.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [caraID]
  }));
  await waitForType(replacementMessages, 'presence-snapshot');
  replacement.send(JSON.stringify({ type: 'friend-remove', targetPeerID: caraID }));

  assert.deepEqual(await waitForType(replacementMessages, 'friend-remove-failed'), {
    type: 'friend-remove-failed', peerID: caraID, message: 'rate limit'
  });
  assert.equal(registry.areMutualFriends(aliceID, caraID), true);
});

test('rate limits idempotent friend removal replays across reconnects', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry, friendRemovalRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, aliceID, bobID, aliceMessages } = await registerMutualFriends(url, context);
  alice.send(JSON.stringify({ type: 'friend-remove', targetPeerID: bobID }));
  await waitForType(aliceMessages, 'friend-removed');
  await new Promise((resolve) => {
    alice.once('close', resolve);
    alice.close();
  });

  const replay = await connect(url);
  context.after(() => replay.close());
  const replayMessages = collect(replay);
  replay.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  await waitForType(replayMessages, 'presence-snapshot');
  replay.send(JSON.stringify({ type: 'friend-remove', targetPeerID: bobID }));

  assert.deepEqual(await waitForType(replayMessages, 'friend-remove-failed'), {
    type: 'friend-remove-failed', peerID: bobID, message: 'rate limit'
  });
  assert.equal(Object.keys(registry.state.removedFriendships).length, 1);
});

test('shares friend removal limits across identities from the same address', async (context) => {
  const registry = new PetRegistry();
  const pairs = [
    ['a'.repeat(32), 'b'.repeat(32), '1'.repeat(64), '2'.repeat(64)],
    ['c'.repeat(32), 'd'.repeat(32), '3'.repeat(64), '4'.repeat(64)]
  ];
  for (const [firstID, secondID, firstToken, secondToken] of pairs) {
    registry.registerIdentity({ peerID: firstID, authToken: firstToken, name: 'First', friendPeerIDs: [secondID] });
    registry.registerIdentity({ peerID: secondID, authToken: secondToken, name: 'Second', friendPeerIDs: [firstID] });
  }
  const relay = createRelayServer({ registry, friendRemovalAddressRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const [first, second] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [first, second].forEach((socket) => socket.close()));
  const firstMessages = collect(first);
  const secondMessages = collect(second);
  first.send(JSON.stringify({
    type: 'presence-register', peerID: pairs[0][0], authToken: pairs[0][2], name: 'First', friendPeerIDs: [pairs[0][1]]
  }));
  second.send(JSON.stringify({
    type: 'presence-register', peerID: pairs[1][0], authToken: pairs[1][2], name: 'First', friendPeerIDs: [pairs[1][1]]
  }));
  await waitForType(firstMessages, 'presence-snapshot');
  await waitForType(secondMessages, 'presence-snapshot');
  first.send(JSON.stringify({ type: 'friend-remove', targetPeerID: pairs[0][1] }));
  await waitForType(firstMessages, 'friend-removed');
  second.send(JSON.stringify({ type: 'friend-remove', targetPeerID: pairs[1][1] }));

  assert.deepEqual(await waitForType(secondMessages, 'friend-remove-failed'), {
    type: 'friend-remove-failed', peerID: pairs[1][1], message: 'rate limit'
  });
  assert.equal(registry.areMutualFriends(pairs[1][0], pairs[1][1]), true);
});

test('keeps an accepted relationship and queued message when the offline requester reconnects with a stale list', async (context) => {
  let nextCode = 567890;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++ });
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  const alice = registry.registerIdentity({
    peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  });
  registry.registerIdentity({
    peerID: bobID, authToken: '2'.repeat(64), name: 'Bob', friendPeerIDs: []
  });
  const request = registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: String(nextCode - 1), fromName: 'Alice'
  });
  registry.respondToFriendRequest({ requestID: request.id, responderPeerID: bobID, accept: true });
  registry.enqueueMessage({
    id: 'd'.repeat(32), fromPeerID: bobID, toPeerID: aliceID, fromName: 'Bob', kind: 'text', body: 'while offline'
  });
  assert.match(alice.petCode, /^\d{6}$/);
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const socket = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => socket.close());
  const messages = collect(socket);

  socket.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: []
  }));
  await waitForType(messages, 'presence-snapshot');

  assert.equal(registry.areMutualFriends(aliceID, bobID), true);
  assert.deepEqual(registry.messagesFor(aliceID).map((message) => message.body), ['while offline']);
});

test('returns a correlated failure when a message id is reused with a conflicting payload', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, bobID, aliceMessages } = await registerMutualFriends(url, context);
  const messageID = 'c'.repeat(32);

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID, targetPeerID: bobID, kind: 'text', body: 'original'
  }));
  assert.equal((await waitForType(aliceMessages, 'friend-message-sent')).messageID, messageID);
  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID, targetPeerID: bobID, kind: 'text', body: 'conflict'
  }));

  assert.deepEqual(await waitForType(aliceMessages, 'friend-message-failed'), {
    type: 'friend-message-failed', messageID, message: 'message id conflict'
  });
});

test('does not queue a message for an unregistered target identity', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const alice = await connect(url);
  context.after(() => alice.close());
  const aliceID = 'a'.repeat(32);
  const bobID = 'b'.repeat(32);
  const aliceMessages = collect(alice);

  alice.send(JSON.stringify({
    type: 'presence-register', peerID: aliceID, authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  await waitForType(aliceMessages, 'presence-snapshot');
  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '3'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'hi'
  }));

  assert.deepEqual(await waitForAnyType(aliceMessages, ['friend-message-failed', 'friend-message-sent']), {
    type: 'friend-message-failed', messageID: '3'.repeat(32), message: 'not friends'
  });
  assert.equal(registry.messagesFor(bobID).length, 0);
});

test('shares message rate limits across parallel sessions for the same peer id', async (context) => {
  const relay = createRelayServer({ messageRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, bobID, aliceMessages } = await registerMutualFriends(url, context);
  const parallelAlice = await connect(url);
  context.after(() => parallelAlice.close());
  const parallelMessages = collect(parallelAlice);
  parallelAlice.send(JSON.stringify({
    type: 'presence-register', peerID: 'a'.repeat(32), authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  await waitForType(parallelMessages, 'presence-snapshot');

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '4'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'one'
  }));
  assert.equal((await waitForType(aliceMessages, 'friend-message-sent')).messageID, '4'.repeat(32));
  parallelAlice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '5'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'two'
  }));

  assert.deepEqual(await waitForAnyType(parallelMessages, ['friend-message-failed', 'friend-message-sent']), {
    type: 'friend-message-failed', messageID: '5'.repeat(32), message: 'rate limit'
  });
});

test('shares message rate limits across reconnects for the same peer id', async (context) => {
  const relay = createRelayServer({ messageRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, bobID, aliceMessages } = await registerMutualFriends(url, context);

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '6'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'one'
  }));
  assert.equal((await waitForType(aliceMessages, 'friend-message-sent')).messageID, '6'.repeat(32));
  await new Promise((resolve) => {
    alice.once('close', resolve);
    alice.close();
  });

  const reconnectedAlice = await connect(url);
  context.after(() => reconnectedAlice.close());
  const reconnectedMessages = collect(reconnectedAlice);
  reconnectedAlice.send(JSON.stringify({
    type: 'presence-register', peerID: 'a'.repeat(32), authToken: '1'.repeat(64), name: 'Alice', friendPeerIDs: [bobID]
  }));
  await waitForType(reconnectedMessages, 'presence-snapshot');
  reconnectedAlice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '7'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'two'
  }));

  assert.deepEqual(await waitForAnyType(reconnectedMessages, ['friend-message-failed', 'friend-message-sent']), {
    type: 'friend-message-failed', messageID: '7'.repeat(32), message: 'rate limit'
  });
});

test('shares message rate limits across identities from the same address', async (context) => {
  const relay = createRelayServer({ messageAddressRateLimit: 1 });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, bobID, aliceMessages } = await registerMutualFriends(url, context);
  const caraID = 'c'.repeat(32);
  const daveID = 'd'.repeat(32);
  const [cara, dave] = await Promise.all([connect(url), connect(url)]);
  context.after(() => [cara, dave].forEach((socket) => socket.close()));
  const caraMessages = collect(cara);
  const daveMessages = collect(dave);
  cara.send(JSON.stringify({
    type: 'presence-register', peerID: caraID, authToken: '3'.repeat(64), name: 'Cara', friendPeerIDs: [daveID]
  }));
  dave.send(JSON.stringify({
    type: 'presence-register', peerID: daveID, authToken: '4'.repeat(64), name: 'Dave', friendPeerIDs: [caraID]
  }));
  await waitForType(caraMessages, 'presence-snapshot');
  await waitForType(daveMessages, 'presence-snapshot');

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: 'a'.repeat(32), targetPeerID: bobID, kind: 'text', body: 'one'
  }));
  assert.equal((await waitForType(aliceMessages, 'friend-message-sent')).messageID, 'a'.repeat(32));
  cara.send(JSON.stringify({
    type: 'friend-message-send', messageID: 'b'.repeat(32), targetPeerID: daveID, kind: 'text', body: 'two'
  }));

  assert.deepEqual(await waitForAnyType(caraMessages, ['friend-message-failed', 'friend-message-sent']), {
    type: 'friend-message-failed', messageID: 'b'.repeat(32), message: 'rate limit'
  });
});

test('counts the 300 character message boundary in Unicode code points', async (context) => {
  const registry = new PetRegistry();
  const relay = createRelayServer({ registry });
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const { alice, bobID, aliceMessages, bobMessages } = await registerMutualFriends(url, context);
  const acceptedBody = '😀'.repeat(300);
  const rejectedBody = '😀'.repeat(301);

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '8'.repeat(32), targetPeerID: bobID, kind: 'text', body: acceptedBody
  }));
  assert.deepEqual(await waitForAnyType(aliceMessages, ['friend-message-sent', 'error']), {
    type: 'friend-message-sent', messageID: '8'.repeat(32)
  });
  assert.equal((await waitForType(bobMessages, 'friend-message-incoming')).body, acceptedBody);

  alice.send(JSON.stringify({
    type: 'friend-message-send', messageID: '9'.repeat(32), targetPeerID: bobID, kind: 'text', body: rejectedBody
  }));
  assert.deepEqual(await waitForType(aliceMessages, 'error'), { type: 'error', message: 'invalid friend message' });
  assert.equal(registry.messagesFor(bobID).length, 1);
});

test('rejects invalid presence subscriptions', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  const alice = await connect(url);
  context.after(() => alice.close());

  alice.send(JSON.stringify({ type: 'presence-register', peerID: 'not-a-profile', name: 'Alice', friendPeerIDs: [] }));
  assert.deepEqual(await nextMessage(alice), { type: 'error', message: 'invalid presence' });
});

test('rate limits repeated presence updates', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());
  const alice = await connect(`ws://127.0.0.1:${address.port}/ws`);
  context.after(() => alice.close());
  const registration = {
    type: 'presence-register',
    peerID: 'a'.repeat(32),
    name: 'Alice',
    friendPeerIDs: []
  };

  alice.send(JSON.stringify(registration));
  assert.deepEqual(await nextMessage(alice), { type: 'presence-snapshot', onlinePeerIDs: [] });
  for (let index = 0; index < 20; index += 1) {
    alice.send(JSON.stringify(registration));
    assert.deepEqual(await nextMessage(alice), { type: 'presence-snapshot', onlinePeerIDs: [] });
  }

  alice.send(JSON.stringify(registration));
  assert.deepEqual(await nextMessage(alice), { type: 'error', message: 'rate limit' });
});
