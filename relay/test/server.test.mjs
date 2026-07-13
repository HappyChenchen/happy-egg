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
