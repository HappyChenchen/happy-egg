import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PetRegistry } from '../registry.mjs';

const aliceID = 'a'.repeat(32);
const aliceToken = '1'.repeat(64);

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
