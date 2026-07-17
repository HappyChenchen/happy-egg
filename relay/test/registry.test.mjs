import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PetRegistry } from '../registry.mjs';

const aliceID = 'a'.repeat(32);
const aliceToken = '1'.repeat(64);
const bobID = 'b'.repeat(32);
const bobToken = '2'.repeat(64);

function registerMutualFriends(registry) {
  registry.registerIdentity({
    peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: [bobID]
  });
  registry.registerIdentity({
    peerID: bobID, authToken: bobToken, name: 'Bob', friendPeerIDs: [aliceID]
  });
}

test('keeps a stable six digit pet code across registry restarts', (context) => {
  const directory = mkdtempSync(join(tmpdir(), 'macpet-registry-'));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  const filePath = join(directory, 'registry.json');

  const first = new PetRegistry({ filePath }).registerIdentity({
    peerID: aliceID,
    authToken: aliceToken,
    name: 'Alice'
  });
  const restored = new PetRegistry({ filePath }).registerIdentity({
    peerID: aliceID,
    authToken: aliceToken,
    name: 'Alice'
  });

  assert.match(first.petCode, /^\d{6}$/);
  assert.equal(restored.petCode, first.petCode);
});

test('rejects a different device token for an existing peer id', () => {
  const registry = new PetRegistry();
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });

  assert.throws(
    () => registry.registerIdentity({ peerID: aliceID, authToken: '2'.repeat(64), name: 'Mallory' }),
    (error) => error.code === 'authentication-failed'
  );
});

test('rejects new identities once the registry identity capacity is reached', () => {
  const registry = new PetRegistry({ identityLimit: 2 });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });

  assert.throws(
    () => registry.registerIdentity({
      peerID: 'c'.repeat(32), authToken: '3'.repeat(64), name: 'Cara'
    }),
    (error) => error.code === 'identity-capacity'
  );
  assert.equal(Object.keys(registry.state.identities).length, 2);
});

test('resetting a pet code invalidates the old code', () => {
  let nextCode = 123456;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++ });
  const identity = registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });

  const reset = registry.resetCode(aliceID);

  assert.notEqual(reset.petCode, identity.petCode);
  assert.equal(registry.findByCode(identity.petCode), null);
  assert.equal(registry.findByCode(reset.petCode)?.peerID, aliceID);
});

test('persists an accepted friend request until both participants acknowledge it', () => {
  let nextCode = 234567;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++ });
  const bobID = 'b'.repeat(32);
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: '2'.repeat(64), name: 'Bob' });
  const request = registry.createFriendRequest({ fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice' });
  registry.respondToFriendRequest({ requestID: request.id, responderPeerID: bobID, accept: true });

  assert.equal(registry.notificationsFor(aliceID)[0].status, 'accepted');
  assert.equal(registry.notificationsFor(bobID)[0].status, 'accepted');
  assert.equal(registry.acknowledgeRequest({ requestID: request.id, peerID: aliceID }), true);
  assert.equal(registry.notificationsFor(aliceID).length, 0);
  assert.equal(registry.notificationsFor(bobID).length, 1);
  assert.equal(registry.acknowledgeRequest({ requestID: request.id, peerID: bobID }), true);
  assert.equal(registry.notificationsFor(bobID).length, 0);
});

test('bounds persisted friend requests while preserving idempotent pending creation', () => {
  let nextCode = 234570;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++, requestTotalLimit: 2 });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });
  const first = registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
  });
  const stateBeforeRetry = registry.state;
  assert.equal(registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
  }).id, first.id);
  assert.strictEqual(registry.state, stateBeforeRetry);
  registry.respondToFriendRequest({ requestID: first.id, responderPeerID: bobID, accept: false });
  const second = registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
  });
  registry.respondToFriendRequest({ requestID: second.id, responderPeerID: bobID, accept: false });

  assert.throws(
    () => registry.createFriendRequest({
      fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
    }),
    (error) => error.code === 'request-capacity'
  );
  assert.equal(Object.keys(registry.state.requests).length, 2);
});

test('keeps the state reference for an unknown request acknowledgement', () => {
  const registry = new PetRegistry({ now: () => 1_000, requestPendingTTL: 100 });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const stateBeforeAck = registry.state;

  assert.equal(registry.acknowledgeRequest({ requestID: 'f'.repeat(32), peerID: aliceID }), false);
  assert.strictEqual(registry.state, stateBeforeAck);
});

test('keeps the state reference for an unauthorized request acknowledgement', () => {
  let nextCode = 234575;
  const caraID = 'c'.repeat(32);
  const registry = new PetRegistry({ now: () => 1_000, randomIntFn: () => nextCode++, requestResultTTL: 100 });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });
  registry.registerIdentity({ peerID: caraID, authToken: '3'.repeat(64), name: 'Cara' });
  const request = registry.createFriendRequest({ fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice' });
  registry.respondToFriendRequest({ requestID: request.id, responderPeerID: bobID, accept: true });
  const stateBeforeAck = registry.state;

  assert.equal(registry.acknowledgeRequest({ requestID: request.id, peerID: caraID }), false);
  assert.strictEqual(registry.state, stateBeforeAck);
});

test('keeps the state reference for a repeated request acknowledgement that needs no deletion', () => {
  let nextCode = 234578;
  const registry = new PetRegistry({ now: () => 1_000, randomIntFn: () => nextCode++, requestResultTTL: 100 });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });
  const request = registry.createFriendRequest({ fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice' });
  registry.respondToFriendRequest({ requestID: request.id, responderPeerID: bobID, accept: true });
  assert.equal(registry.acknowledgeRequest({ requestID: request.id, peerID: aliceID }), true);
  const stateBeforeRetry = registry.state;

  assert.equal(registry.acknowledgeRequest({ requestID: request.id, peerID: aliceID }), true);
  assert.strictEqual(registry.state, stateBeforeRetry);
});

test('actively expires pending and completed friend requests by their configured TTLs', () => {
  let clock = 1_000;
  let nextCode = 234580;
  const registry = new PetRegistry({
    now: () => clock,
    randomIntFn: () => nextCode++,
    requestPendingTTL: 100,
    requestResultTTL: 50
  });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });
  const completed = registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
  });
  registry.respondToFriendRequest({ requestID: completed.id, responderPeerID: bobID, accept: false });
  clock += 51;
  assert.equal(registry.purgeExpiredRequests(), true);
  const pending = registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
  });
  clock += 101;

  assert.equal(registry.purgeExpiredRequests(), true);
  assert.equal(registry.state.requests[pending.id], undefined);
  assert.equal(Object.keys(registry.state.requests).length, 0);
});

test('keeps the state reference for notification reads when no request is expired', () => {
  let nextCode = 234590;
  const registry = new PetRegistry({ now: () => 1_000, randomIntFn: () => nextCode++, requestPendingTTL: 100 });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });
  registry.createFriendRequest({ fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice' });
  const stateBeforeRead = registry.state;

  assert.equal(registry.notificationsFor(bobID).length, 1);
  assert.strictEqual(registry.state, stateBeforeRead);
});

test('records an accepted friend request as a mutual messaging relationship', () => {
  let nextCode = 345670;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++ });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });
  const request = registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
  });
  registry.respondToFriendRequest({ requestID: request.id, responderPeerID: bobID, accept: true });

  const stored = registry.enqueueMessage({
    id: 'a'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'hello'
  });

  assert.equal(stored.toPeerID, bobID);
});

test('rejects a friend request acceptance that would exceed either identity friend limit', () => {
  let nextCode = 345680;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++ });
  const existingFriendIDs = Array.from(
    { length: 100 },
    (_, index) => (index + 1).toString(16).padStart(32, '0')
  );
  registry.registerIdentity({
    peerID: aliceID,
    authToken: aliceToken,
    name: 'Alice',
    friendPeerIDs: existingFriendIDs
  });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });
  const request = registry.createFriendRequest({
    fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice'
  });

  assert.throws(
    () => registry.respondToFriendRequest({ requestID: request.id, responderPeerID: bobID, accept: true }),
    (error) => error.code === 'too-many-friends'
  );
  assert.equal(registry.state.identities[aliceID].friendPeerIDs.length, 100);
  assert.equal(registry.state.identities[bobID].friendPeerIDs.length, 0);
  assert.equal(registry.state.requests[request.id].status, 'pending');
});

test('reconciles away unilateral legacy friends so they cannot permanently consume capacity', () => {
  let nextCode = 345690;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++ });
  const legacyFriendIDs = Array.from(
    { length: 100 },
    (_, index) => (index + 1).toString(16).padStart(32, '0')
  );
  registry.registerIdentity({
    peerID: aliceID,
    authToken: aliceToken,
    name: 'Alice',
    friendPeerIDs: legacyFriendIDs
  });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });

  registry.registerIdentity({
    peerID: aliceID,
    authToken: aliceToken,
    name: 'Alice',
    friendPeerIDs: []
  });
  const request = registry.createFriendRequest({
    fromPeerID: bobID, targetCode: registry.identity(aliceID).petCode, fromName: 'Bob'
  });
  registry.respondToFriendRequest({ requestID: request.id, responderPeerID: aliceID, accept: true });

  assert.equal(bob.peerID, bobID);
  assert.deepEqual(registry.state.identities[aliceID].friendPeerIDs, [bobID]);
  assert.equal(registry.areMutualFriends(aliceID, bobID), true);
  assert.equal(Object.keys(registry.state.removedFriendships).length, 0);
});

test('uses current pet names when a pending request is accepted', () => {
  let nextCode = 456789;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++ });
  const bobID = 'b'.repeat(32);
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: '2'.repeat(64), name: 'Bob' });
  const request = registry.createFriendRequest({ fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice' });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alicia' });
  registry.registerIdentity({ peerID: bobID, authToken: '2'.repeat(64), name: 'Bobby' });

  const accepted = registry.respondToFriendRequest({ requestID: request.id, responderPeerID: bobID, accept: true });

  assert.equal(accepted.fromName, 'Alicia');
  assert.equal(accepted.toName, 'Bobby');
});

test('queues a message for the recipient until it is acknowledged', () => {
  const registry = new PetRegistry();
  registerMutualFriends(registry);
  const stored = registry.enqueueMessage({
    id: 'e'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'hi'
  });

  assert.equal(stored.id, 'e'.repeat(32));
  assert.deepEqual(registry.messagesFor(bobID).map((message) => message.body), ['hi']);
  assert.equal(registry.messagesFor(aliceID).length, 0);
  assert.equal(registry.acknowledgeMessage({ messageID: stored.id, peerID: aliceID }), false);
  assert.equal(registry.acknowledgeMessage({ messageID: stored.id, peerID: bobID }), true);
  assert.equal(registry.messagesFor(bobID).length, 0);
});

test('keeps the state reference for an unknown message acknowledgement', () => {
  const registry = new PetRegistry({ now: () => 1_000, messageTTL: 100 });
  registerMutualFriends(registry);
  const stateBeforeAck = registry.state;

  assert.equal(registry.acknowledgeMessage({ messageID: 'f'.repeat(32), peerID: bobID }), false);
  assert.strictEqual(registry.state, stateBeforeAck);
});

test('keeps the state reference for an unauthorized message acknowledgement', () => {
  const registry = new PetRegistry({ now: () => 1_000, messageTTL: 100 });
  registerMutualFriends(registry);
  const message = registry.enqueueMessage({
    id: 'a'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'private'
  });
  const stateBeforeAck = registry.state;

  assert.equal(registry.acknowledgeMessage({ messageID: message.id, peerID: aliceID }), false);
  assert.strictEqual(registry.state, stateBeforeAck);
});

test('keeps the state reference for an idempotent message enqueue retry', () => {
  const registry = new PetRegistry({ now: () => 1_000, messageTTL: 100 });
  registerMutualFriends(registry);
  const payload = {
    id: 'c'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'retry'
  };
  registry.enqueueMessage(payload);
  const stateBeforeRetry = registry.state;

  assert.equal(registry.enqueueMessage(payload).id, payload.id);
  assert.strictEqual(registry.state, stateBeforeRetry);
});

test('keeps the state reference for message reads when no cleanup is needed', () => {
  const registry = new PetRegistry({ now: () => 1_000, messageTTL: 100 });
  registerMutualFriends(registry);
  registry.enqueueMessage({
    id: '0'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'current'
  });
  const stateBeforeRead = registry.state;

  assert.deepEqual(registry.messagesFor(bobID).map((message) => message.body), ['current']);
  assert.strictEqual(registry.state, stateBeforeRead);
});

test('drops the oldest message once the per-recipient queue is full', () => {
  let clock = 0;
  const registry = new PetRegistry({ now: () => (clock += 1) });
  registerMutualFriends(registry);
  for (let index = 0; index < 55; index += 1) {
    registry.enqueueMessage({ fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: `m${index}` });
  }
  const pending = registry.messagesFor(bobID);

  assert.equal(pending.length, 50);
  assert.equal(pending[0].body, 'm5');
  assert.equal(pending[49].body, 'm54');
});

test('persists queued messages across registry restarts', (context) => {
  const directory = mkdtempSync(join(tmpdir(), 'macpet-registry-'));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  const filePath = join(directory, 'registry.json');
  const registry = new PetRegistry({ filePath });
  registerMutualFriends(registry);

  registry.enqueueMessage({
    id: 'f'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'sticker', body: 'sticker_wave'
  });
  const restored = new PetRegistry({ filePath }).messagesFor(bobID);

  assert.equal(restored.length, 1);
  assert.equal(restored[0].kind, 'sticker');
  assert.equal(restored[0].body, 'sticker_wave');
});

test('requires both registered identities to be mutual friends before queuing a message', () => {
  const registry = new PetRegistry();
  registry.registerIdentity({
    peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: [bobID]
  });
  registry.registerIdentity({
    peerID: bobID, authToken: bobToken, name: 'Bob', friendPeerIDs: []
  });

  assert.throws(
    () => registry.enqueueMessage({
      id: 'c'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'hi'
    }),
    (error) => error.code === 'not-friends'
  );
  assert.equal(registry.messagesFor(bobID).length, 0);
});

test('deleting a mutual friend removes their queued messages before a later re-add', () => {
  const registry = new PetRegistry();
  registerMutualFriends(registry);
  registry.enqueueMessage({
    id: 'b'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'stale'
  });
  assert.equal(registry.messagesFor(bobID).length, 1);

  registry.removeFriendship({ peerID: bobID, friendPeerID: aliceID });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: [bobID] });
  registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob', friendPeerIDs: [aliceID] });

  assert.equal(registry.messagesFor(bobID).length, 0);
  assert.equal(registry.areMutualFriends(aliceID, bobID), false);
});

test('only creates a removal tombstone for a real mutual relationship and keeps retries idempotent', () => {
  const registry = new PetRegistry();
  registry.registerIdentity({
    peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: []
  });
  registry.registerIdentity({
    peerID: bobID, authToken: bobToken, name: 'Bob', friendPeerIDs: []
  });

  assert.throws(
    () => registry.removeFriendship({ peerID: aliceID, friendPeerID: bobID }),
    (error) => error.code === 'not-friends'
  );
  assert.equal(Object.keys(registry.state.removedFriendships).length, 0);

  const mutualRegistry = new PetRegistry();
  registerMutualFriends(mutualRegistry);
  assert.equal(mutualRegistry.removeFriendship({ peerID: aliceID, friendPeerID: bobID }), true);
  const firstRemovedAt = Object.values(mutualRegistry.state.removedFriendships)[0].removedAt;
  const stateBeforeRetry = mutualRegistry.state;
  assert.equal(mutualRegistry.removeFriendship({ peerID: aliceID, friendPeerID: bobID }), true);
  assert.strictEqual(mutualRegistry.state, stateBeforeRetry);
  assert.equal(Object.keys(mutualRegistry.state.removedFriendships).length, 1);
  assert.equal(Object.values(mutualRegistry.state.removedFriendships)[0].removedAt, firstRemovedAt);
});

test('lets an upgraded client delete its unilateral legacy friend without creating a tombstone', () => {
  const registry = new PetRegistry();
  registry.registerIdentity({
    peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: [bobID]
  });

  assert.equal(registry.removeFriendship({ peerID: aliceID, friendPeerID: bobID }), true);
  assert.deepEqual(registry.state.identities[aliceID].friendPeerIDs, []);
  assert.equal(Object.keys(registry.state.removedFriendships).length, 0);
});

test('rolls back an in-memory friend removal when the persistent write fails', (context) => {
  const directory = mkdtempSync(join(tmpdir(), 'macpet-registry-'));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  const filePath = join(directory, 'registry.json');
  const registry = new PetRegistry({ filePath });
  registerMutualFriends(registry);
  registry.enqueueMessage({
    id: '6'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'keep me'
  });
  const before = structuredClone(registry.state);
  rmSync(filePath);
  mkdirSync(filePath);

  assert.throws(
    () => registry.removeFriendship({ peerID: aliceID, friendPeerID: bobID }),
    (error) => error.code === 'registry-write-failed'
  );

  assert.deepEqual(registry.state, before);
  assert.equal(registry.areMutualFriends(aliceID, bobID), true);
  assert.equal(registry.state.messages['6'.repeat(32)]?.body, 'keep me');
  assert.equal(Object.keys(registry.state.removedFriendships).length, 0);
});

test('contains retention write failures and leaves in-memory records untouched', (context) => {
  const directory = mkdtempSync(join(tmpdir(), 'macpet-registry-'));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  const filePath = join(directory, 'registry.json');
  let clock = 1_000;
  let nextCode = 456700;
  const registry = new PetRegistry({
    filePath,
    now: () => clock,
    randomIntFn: () => nextCode++,
    messageTTL: 100,
    requestPendingTTL: 100
  });
  registerMutualFriends(registry);
  registry.enqueueMessage({
    id: '5'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'expired'
  });
  const request = registry.createFriendRequest({
    fromPeerID: aliceID,
    targetCode: registry.identity(bobID).petCode,
    fromName: 'Alice'
  });
  const before = structuredClone(registry.state);
  clock += 101;
  rmSync(filePath);
  mkdirSync(filePath);

  assert.equal(registry.purgeExpiredMessages(), false);
  assert.equal(registry.purgeExpiredRequests(), false);
  assert.deepEqual(registry.state, before);
  assert.equal(registry.state.messages['5'.repeat(32)]?.body, 'expired');
  assert.equal(registry.state.requests[request.id]?.status, 'pending');
});

test('does not let an old empty friend list erase an accepted relationship or its queued message', () => {
  let nextCode = 456780;
  const registry = new PetRegistry({ randomIntFn: () => nextCode++ });
  const alice = registry.registerIdentity({
    peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: []
  });
  registry.registerIdentity({
    peerID: bobID, authToken: bobToken, name: 'Bob', friendPeerIDs: []
  });
  const request = registry.createFriendRequest({
    fromPeerID: bobID, targetCode: alice.petCode, fromName: 'Bob'
  });
  registry.respondToFriendRequest({ requestID: request.id, responderPeerID: aliceID, accept: true });
  registry.enqueueMessage({
    id: '7'.repeat(32), fromPeerID: bobID, toPeerID: aliceID, fromName: 'Bob', kind: 'text', body: 'queued'
  });

  registry.registerIdentity({
    peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: []
  });

  assert.equal(registry.areMutualFriends(aliceID, bobID), true);
  assert.deepEqual(registry.messagesFor(aliceID).map((message) => message.body), ['queued']);
});

test('rejects conflicting payloads that reuse an existing message id', () => {
  const registry = new PetRegistry();
  registerMutualFriends(registry);
  registry.enqueueMessage({
    id: '8'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'original'
  });

  assert.throws(
    () => registry.enqueueMessage({
      id: '8'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'conflict'
    }),
    (error) => error.code === 'message-id-conflict'
  );
  assert.deepEqual(registry.messagesFor(bobID).map((message) => message.body), ['original']);
});

test('does not queue a message for an unregistered target identity', () => {
  const registry = new PetRegistry();
  registry.registerIdentity({
    peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: [bobID]
  });

  assert.throws(
    () => registry.enqueueMessage({
      id: 'd'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'hi'
    }),
    (error) => error.code === 'not-friends'
  );
  assert.equal(registry.messagesFor(bobID).length, 0);
});

test('rejects a new unique message once the total message limit is full', () => {
  const registry = new PetRegistry({ messageTotalLimit: 2 });
  const caraID = 'c'.repeat(32);
  registry.registerIdentity({
    peerID: aliceID, authToken: aliceToken, name: 'Alice', friendPeerIDs: [bobID, caraID]
  });
  registry.registerIdentity({
    peerID: bobID, authToken: bobToken, name: 'Bob', friendPeerIDs: [aliceID]
  });
  registry.registerIdentity({
    peerID: caraID, authToken: '3'.repeat(64), name: 'Cara', friendPeerIDs: [aliceID]
  });
  registry.enqueueMessage({
    id: '1'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'one'
  });
  registry.enqueueMessage({
    id: '2'.repeat(32), fromPeerID: aliceID, toPeerID: caraID, fromName: 'Alice', kind: 'text', body: 'two'
  });
  registry.enqueueMessage({
    id: '1'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'one'
  });

  assert.throws(
    () => registry.enqueueMessage({
      id: '3'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'three'
    }),
    (error) => error.code === 'message-capacity'
  );
  assert.equal(registry.messagesFor(bobID).length, 1);
  assert.equal(registry.messagesFor(caraID).length, 1);
});

test('removes an expired message after the configured message TTL', () => {
  let clock = 1_000;
  const registry = new PetRegistry({ now: () => clock, messageTTL: 100 });
  registerMutualFriends(registry);
  registry.enqueueMessage({
    id: '4'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'old'
  });

  clock += 101;

  assert.equal(registry.messagesFor(bobID).length, 0);
});

test('exposes eager expiry cleanup for the relay retention timer', () => {
  let clock = 1_000;
  const registry = new PetRegistry({ now: () => clock, messageTTL: 100 });
  registerMutualFriends(registry);
  registry.enqueueMessage({
    id: '9'.repeat(32), fromPeerID: aliceID, toPeerID: bobID, fromName: 'Alice', kind: 'text', body: 'old'
  });
  clock += 101;

  assert.equal(registry.purgeExpiredMessages(), true);
  assert.equal(Object.keys(registry.state.messages).length, 0);
});

test('keeps the state reference for no-op retention purges', () => {
  let nextCode = 567800;
  const registry = new PetRegistry({
    now: () => 1_000,
    randomIntFn: () => nextCode++,
    messageTTL: 100,
    requestPendingTTL: 100
  });
  registry.registerIdentity({ peerID: aliceID, authToken: aliceToken, name: 'Alice' });
  const bob = registry.registerIdentity({ peerID: bobID, authToken: bobToken, name: 'Bob' });
  registry.createFriendRequest({ fromPeerID: aliceID, targetCode: bob.petCode, fromName: 'Alice' });
  const stateBeforePurges = registry.state;

  assert.equal(registry.purgeExpiredMessages(), false);
  assert.strictEqual(registry.state, stateBeforePurges);
  assert.equal(registry.purgeExpiredRequests(), false);
  assert.strictEqual(registry.state, stateBeforePurges);
});
