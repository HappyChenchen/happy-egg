import test from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { createRelayServer } from '../server.mjs';

const room = 'a'.repeat(64);

function connect(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
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

test('serves a JSON health response', async (context) => {
  const relay = createRelayServer();
  const address = await relay.listen(0, '127.0.0.1');
  context.after(async () => relay.close());

  const response = await fetch(`http://127.0.0.1:${address.port}/health`);

  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'application/json');
  assert.deepEqual(await response.json(), { ok: true });
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

  const bobOnline = nextMessage(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [aliceID] }));
  assert.deepEqual(await nextMessage(bob), { type: 'presence-snapshot', onlinePeerIDs: [aliceID] });
  assert.deepEqual(await bobOnline, { type: 'friend-presence', peerID: bobID, online: true });

  const bobOffline = nextMessage(alice);
  bob.close();
  assert.deepEqual(await bobOffline, { type: 'friend-presence', peerID: bobID, online: false });
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

  const aliceSeesRemoval = nextMessageWithin(alice);
  bob.send(JSON.stringify({ type: 'presence-register', peerID: bobID, name: 'Bob', friendPeerIDs: [] }));
  assert.deepEqual(await nextMessage(bob), { type: 'presence-snapshot', onlinePeerIDs: [] });
  assert.deepEqual(await aliceSeesRemoval, { type: 'friend-presence', peerID: bobID, online: false });

  const rejected = nextMessageWithin(alice);
  alice.send(JSON.stringify({ type: 'friend-event', targetPeerID: bobID, kind: 'poke', frameName: 'ai_buddy_00' }));
  assert.deepEqual(await rejected, {
    type: 'friend-event-rejected',
    targetPeerID: bobID,
    message: 'friend unavailable'
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
