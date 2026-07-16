import test from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { createRelayServer } from '../server.mjs';
import { PetRegistry } from '../registry.mjs';

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
