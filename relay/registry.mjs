import { createHash, randomInt, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

const PEER_ID_PATTERN = /^[a-f0-9]{32}$/i;
const AUTH_TOKEN_PATTERN = /^[a-f0-9]{64}$/i;
const PET_CODE_PATTERN = /^\d{6}$/;
const MESSAGE_QUEUE_LIMIT = 50;
const MESSAGE_TOTAL_LIMIT = 5_000;
const MESSAGE_TTL = 7 * 24 * 60 * 60_000;
const IDENTITY_LIMIT = 100_000;
const FRIEND_LIMIT = 100;
const REQUEST_TOTAL_LIMIT = 10_000;
const REQUEST_PENDING_TTL = 30 * 24 * 60 * 60_000;
const REQUEST_RESULT_TTL = 7 * 24 * 60 * 60_000;

export class RegistryError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export class PetRegistry {
  constructor({
    filePath = null,
    randomIntFn = randomInt,
    now = () => Date.now(),
    messageQueueLimit = MESSAGE_QUEUE_LIMIT,
    messageTotalLimit = MESSAGE_TOTAL_LIMIT,
    messageTTL = MESSAGE_TTL,
    identityLimit = IDENTITY_LIMIT,
    requestTotalLimit = REQUEST_TOTAL_LIMIT,
    requestPendingTTL = REQUEST_PENDING_TTL,
    requestResultTTL = REQUEST_RESULT_TTL
  } = {}) {
    this.filePath = filePath;
    this.randomIntFn = randomIntFn;
    this.now = now;
    this.messageQueueLimit = messageQueueLimit;
    this.messageTotalLimit = messageTotalLimit;
    this.messageTTL = messageTTL;
    this.identityLimit = identityLimit;
    this.requestTotalLimit = requestTotalLimit;
    this.requestPendingTTL = requestPendingTTL;
    this.requestResultTTL = requestResultTTL;
    this.state = this.#load();
    this.purgeExpiredMessages();
    this.purgeExpiredRequests();
  }

  registerIdentity({ peerID, authToken, name, friendPeerIDs }) {
    const normalizedPeerID = this.#validPeerID(peerID);
    const normalizedToken = this.#validToken(authToken);
    const tokenHash = this.#hash(normalizedToken);
    const normalizedFriends = friendPeerIDs === undefined
      ? null
      : this.#validFriendPeerIDs(friendPeerIDs, normalizedPeerID);
    return this.#mutate(() => {
      const existing = this.state.identities[normalizedPeerID];
      if (existing && existing.tokenHash !== tokenHash) {
        throw new RegistryError('authentication-failed', 'device authentication failed');
      }
      if (existing) {
        existing.name = String(name).trim();
        if (normalizedFriends) {
          const authoritativeFriends = (existing.friendPeerIDs ?? []).filter((friendPeerID) =>
            this.#areMutualFriends(normalizedPeerID, friendPeerID)
          );
          const permittedAdditions = normalizedFriends.filter((friendPeerID) =>
            !this.#isRemovedFriendship(normalizedPeerID, friendPeerID)
          );
          existing.friendPeerIDs = [...new Set([
            ...authoritativeFriends,
            ...permittedAdditions
          ])].slice(0, FRIEND_LIMIT);
        }
        existing.updatedAt = this.now();
        this.#removeUnauthorizedMessagesFor(normalizedPeerID);
        return { changed: true, result: this.identity(normalizedPeerID) };
      }
      if (Object.keys(this.state.identities).length >= this.identityLimit) {
        throw new RegistryError('identity-capacity', 'identity capacity reached');
      }
      const petCode = this.#allocateCode();
      this.state.identities[normalizedPeerID] = {
        peerID: normalizedPeerID,
        tokenHash,
        petCode,
        name: String(name).trim(),
        friendPeerIDs: (normalizedFriends ?? []).filter((friendPeerID) =>
          !this.#isRemovedFriendship(normalizedPeerID, friendPeerID)
        ),
        createdAt: this.now(),
        updatedAt: this.now()
      };
      this.state.codes[petCode] = normalizedPeerID;
      this.#removeUnauthorizedMessagesFor(normalizedPeerID);
      return { changed: true, result: this.identity(normalizedPeerID) };
    });
  }

  authenticateIdentity({ peerID, authToken }) {
    const normalizedPeerID = this.#validPeerID(peerID);
    const normalizedToken = this.#validToken(authToken);
    const existing = this.state.identities[normalizedPeerID];
    if (!existing) return false;
    if (existing.tokenHash !== this.#hash(normalizedToken)) {
      throw new RegistryError('authentication-failed', 'device authentication failed');
    }
    return true;
  }

  identity(peerID) {
    const value = this.state.identities[String(peerID).toLowerCase()];
    if (!value) return null;
    return { peerID: value.peerID, petCode: value.petCode, name: value.name };
  }

  findByCode(petCode) {
    if (!PET_CODE_PATTERN.test(String(petCode))) return null;
    const peerID = this.state.codes[String(petCode)];
    return peerID ? this.identity(peerID) : null;
  }

  resetCode(peerID) {
    const normalizedPeerID = this.#validPeerID(peerID);
    return this.#mutate(() => {
      const identity = this.state.identities[normalizedPeerID];
      if (!identity) throw new RegistryError('identity-not-found', 'identity not found');
      delete this.state.codes[identity.petCode];
      identity.petCode = this.#allocateCode();
      identity.updatedAt = this.now();
      this.state.codes[identity.petCode] = normalizedPeerID;
      return { changed: true, result: this.identity(normalizedPeerID) };
    });
  }

  createFriendRequest({ fromPeerID, targetCode, fromName }) {
    const normalizedFromID = this.#validPeerID(fromPeerID);
    if (!this.#hasExpiredRequests()) {
      const target = this.findByCode(targetCode);
      if (!target) throw new RegistryError('pet-code-not-found', 'pet code not found');
      if (target.peerID === normalizedFromID) throw new RegistryError('self-request', 'cannot add yourself');
      const existing = Object.values(this.state.requests).find((request) =>
        request.status === 'pending' && request.fromPeerID === normalizedFromID && request.toPeerID === target.peerID
      );
      if (existing) return structuredClone(existing);
    }
    return this.#mutate(() => {
      const expired = this.#removeExpiredRequests();
      const target = this.findByCode(targetCode);
      if (!target) throw new RegistryError('pet-code-not-found', 'pet code not found');
      if (target.peerID === normalizedFromID) throw new RegistryError('self-request', 'cannot add yourself');
      const existing = Object.values(this.state.requests).find((request) =>
        request.status === 'pending' && request.fromPeerID === normalizedFromID && request.toPeerID === target.peerID
      );
      if (existing) return { changed: expired, result: structuredClone(existing) };
      if (Object.keys(this.state.requests).length >= this.requestTotalLimit) {
        throw new RegistryError('request-capacity', 'request capacity reached');
      }
      const inboundCount = Object.values(this.state.requests).filter((request) =>
        request.status === 'pending' && request.toPeerID === target.peerID
      ).length;
      if (inboundCount >= 100) throw new RegistryError('too-many-requests', 'too many pending requests');
      const request = {
        id: randomUUID().replaceAll('-', '').toLowerCase(),
        fromPeerID: normalizedFromID,
        toPeerID: target.peerID,
        fromName: String(fromName).trim(),
        toName: target.name,
        status: 'pending',
        createdAt: this.now(),
        deliveredTo: []
      };
      this.state.requests[request.id] = request;
      return { changed: true, result: structuredClone(request) };
    });
  }

  respondToFriendRequest({ requestID, responderPeerID, accept }) {
    const normalizedResponder = this.#validPeerID(responderPeerID);
    return this.#mutate(() => {
      this.#removeExpiredRequests();
      const request = this.state.requests[String(requestID).toLowerCase()];
      if (!request || request.status !== 'pending' || request.toPeerID !== normalizedResponder) {
        throw new RegistryError('request-not-found', 'friend request not found');
      }
      if (accept) {
        this.#assertCanAddFriend(request.fromPeerID, request.toPeerID);
        this.#assertCanAddFriend(request.toPeerID, request.fromPeerID);
      }
      request.fromName = this.state.identities[request.fromPeerID]?.name ?? request.fromName;
      request.toName = this.state.identities[request.toPeerID]?.name ?? request.toName;
      request.status = accept ? 'accepted' : 'rejected';
      request.respondedAt = this.now();
      request.deliveredTo = [];
      if (accept) {
        delete this.state.removedFriendships[this.#friendshipKey(request.fromPeerID, request.toPeerID)];
        this.#addFriend(request.fromPeerID, request.toPeerID);
        this.#addFriend(request.toPeerID, request.fromPeerID);
      }
      return { changed: true, result: structuredClone(request) };
    });
  }

  notificationsFor(peerID) {
    this.#safeCleanup(this.#hasExpiredRequests(), () => this.#removeExpiredRequests());
    const normalizedPeerID = this.#validPeerID(peerID);
    return Object.values(this.state.requests).filter((request) => {
      if (request.status === 'pending') return request.toPeerID === normalizedPeerID;
      if (request.status === 'accepted') {
        return (request.fromPeerID === normalizedPeerID || request.toPeerID === normalizedPeerID)
          && !request.deliveredTo.includes(normalizedPeerID);
      }
      return request.status === 'rejected'
        && request.fromPeerID === normalizedPeerID
        && !request.deliveredTo.includes(normalizedPeerID);
    }).map((request) => structuredClone(request));
  }

  acknowledgeRequest({ requestID, peerID }) {
    const normalizedPeerID = this.#validPeerID(peerID);
    const normalizedRequestID = String(requestID).toLowerCase();
    if (!this.#hasExpiredRequests()) {
      const request = this.state.requests[normalizedRequestID];
      if (!request || request.status === 'pending') return false;
      const expected = request.status === 'accepted'
        ? [request.fromPeerID, request.toPeerID]
        : [request.fromPeerID];
      if (!expected.includes(normalizedPeerID)) return false;
      const alreadyDelivered = request.deliveredTo.includes(normalizedPeerID);
      const needsDeletion = expected.every((participant) => request.deliveredTo.includes(participant));
      if (alreadyDelivered && !needsDeletion) return true;
    }
    return this.#mutate(() => {
      const expired = this.#removeExpiredRequests();
      const request = this.state.requests[normalizedRequestID];
      if (!request || request.status === 'pending') return { changed: expired, result: false };
      const expected = request.status === 'accepted'
        ? [request.fromPeerID, request.toPeerID]
        : [request.fromPeerID];
      if (!expected.includes(normalizedPeerID)) return { changed: expired, result: false };
      if (!request.deliveredTo.includes(normalizedPeerID)) request.deliveredTo.push(normalizedPeerID);
      if (expected.every((participant) => request.deliveredTo.includes(participant))) {
        delete this.state.requests[request.id];
      }
      return { changed: true, result: true };
    });
  }

  areMutualFriends(firstPeerID, secondPeerID) {
    return this.#areMutualFriends(this.#validPeerID(firstPeerID), this.#validPeerID(secondPeerID));
  }

  removeFriendship({ peerID, friendPeerID }) {
    const normalizedPeerID = this.#validPeerID(peerID);
    const normalizedFriendPeerID = this.#validPeerID(friendPeerID);
    if (normalizedPeerID === normalizedFriendPeerID) {
      throw new RegistryError('self-friend', 'cannot remove yourself');
    }
    const identity = this.state.identities[normalizedPeerID];
    if (!identity) throw new RegistryError('identity-not-found', 'identity not found');
    const key = this.#friendshipKey(normalizedPeerID, normalizedFriendPeerID);
    if (this.state.removedFriendships[key]) return true;
    if (!this.#areMutualFriends(normalizedPeerID, normalizedFriendPeerID)
        && !(identity.friendPeerIDs ?? []).includes(normalizedFriendPeerID)) {
      throw new RegistryError('not-friends', 'not friends');
    }
    return this.#mutate(() => {
      const identity = this.state.identities[normalizedPeerID];
      if (!identity) {
        throw new RegistryError('identity-not-found', 'identity not found');
      }
      const key = this.#friendshipKey(normalizedPeerID, normalizedFriendPeerID);
      if (this.state.removedFriendships[key]) return { changed: false, result: true };
      if (!this.#areMutualFriends(normalizedPeerID, normalizedFriendPeerID)) {
        if (!(identity.friendPeerIDs ?? []).includes(normalizedFriendPeerID)) {
          throw new RegistryError('not-friends', 'not friends');
        }
        identity.friendPeerIDs = identity.friendPeerIDs.filter((candidate) => candidate !== normalizedFriendPeerID);
        identity.updatedAt = this.now();
        this.#removeMessagesBetween(normalizedPeerID, normalizedFriendPeerID);
        return { changed: true, result: true };
      }
      const [firstPeerID, secondPeerID] = [normalizedPeerID, normalizedFriendPeerID].sort();
      this.state.removedFriendships[key] = {
        firstPeerID,
        secondPeerID,
        removedAt: this.now()
      };
      for (const [ownerPeerID, removedPeerID] of [
        [normalizedPeerID, normalizedFriendPeerID],
        [normalizedFriendPeerID, normalizedPeerID]
      ]) {
        const identity = this.state.identities[ownerPeerID];
        if (!identity) continue;
        identity.friendPeerIDs = (identity.friendPeerIDs ?? []).filter((candidate) => candidate !== removedPeerID);
        identity.updatedAt = this.now();
      }
      for (const request of Object.values(this.state.requests)) {
        if (this.#friendshipKey(request.fromPeerID, request.toPeerID) === key) {
          delete this.state.requests[request.id];
        }
      }
      this.#removeMessagesBetween(normalizedPeerID, normalizedFriendPeerID);
      return { changed: true, result: true };
    });
  }

  removedFriendsFor(peerID) {
    const normalizedPeerID = this.#validPeerID(peerID);
    const removed = [];
    for (const relationship of Object.values(this.state.removedFriendships)) {
      if (relationship.firstPeerID === normalizedPeerID) removed.push(relationship.secondPeerID);
      else if (relationship.secondPeerID === normalizedPeerID) removed.push(relationship.firstPeerID);
    }
    return [...new Set(removed)].sort();
  }

  enqueueMessage({ id, fromPeerID, toPeerID, fromName, kind, body }) {
    const normalizedFromID = this.#validPeerID(fromPeerID);
    const normalizedToID = this.#validPeerID(toPeerID);
    if (normalizedFromID === normalizedToID) throw new RegistryError('self-message', 'cannot message yourself');
    if (!this.#areMutualFriends(normalizedFromID, normalizedToID)) {
      throw new RegistryError('not-friends', 'not friends');
    }
    const messageID = typeof id === 'string' && /^[a-f0-9]{32}$/i.test(id)
      ? id.toLowerCase()
      : randomUUID().replaceAll('-', '').toLowerCase();
    if (!this.#hasExpiredMessages()) {
      const existing = this.state.messages[messageID];
      if (existing) {
        const sameMessage = existing.fromPeerID === normalizedFromID
          && existing.toPeerID === normalizedToID
          && existing.kind === kind
          && existing.body === body;
        if (!sameMessage) throw new RegistryError('message-id-conflict', 'message id conflict');
        return structuredClone(existing);
      }
    }
    return this.#mutate(() => {
      if (!this.#areMutualFriends(normalizedFromID, normalizedToID)) {
        throw new RegistryError('not-friends', 'not friends');
      }
      const expired = this.#removeExpiredMessages();
      const existing = this.state.messages[messageID];
      if (existing) {
        const sameMessage = existing.fromPeerID === normalizedFromID
          && existing.toPeerID === normalizedToID
          && existing.kind === kind
          && existing.body === body;
        if (!sameMessage) throw new RegistryError('message-id-conflict', 'message id conflict');
        return { changed: expired, result: structuredClone(existing) };
      }
      const pending = Object.values(this.state.messages)
        .filter((message) => message.toPeerID === normalizedToID)
        .sort((a, b) => a.createdAt - b.createdAt);
      while (pending.length >= this.messageQueueLimit) {
        const oldest = pending.shift();
        delete this.state.messages[oldest.id];
      }
      if (Object.keys(this.state.messages).length >= this.messageTotalLimit) {
        throw new RegistryError('message-capacity', 'message capacity reached');
      }
      const message = {
        id: messageID,
        fromPeerID: normalizedFromID,
        toPeerID: normalizedToID,
        fromName: String(fromName).trim(),
        kind,
        body,
        createdAt: this.now()
      };
      this.state.messages[message.id] = message;
      return { changed: true, result: structuredClone(message) };
    });
  }

  messagesFor(peerID) {
    const normalizedPeerID = this.#validPeerID(peerID);
    const cleanupNeeded = this.#hasExpiredMessages() || this.#hasUnauthorizedMessagesFor(normalizedPeerID);
    this.#safeCleanup(cleanupNeeded, () => {
      const expired = this.#removeExpiredMessages();
      return this.#removeUnauthorizedMessagesFor(normalizedPeerID) || expired;
    });
    return Object.values(this.state.messages)
      .filter((message) => message.toPeerID === normalizedPeerID)
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((message) => structuredClone(message));
  }

  acknowledgeMessage({ messageID, peerID }) {
    const normalizedPeerID = this.#validPeerID(peerID);
    const normalizedMessageID = String(messageID).toLowerCase();
    if (!this.#hasExpiredMessages()) {
      const message = this.state.messages[normalizedMessageID];
      if (!message || message.toPeerID !== normalizedPeerID) return false;
    }
    return this.#mutate(() => {
      const expired = this.#removeExpiredMessages();
      const message = this.state.messages[normalizedMessageID];
      if (!message || message.toPeerID !== normalizedPeerID) return { changed: expired, result: false };
      delete this.state.messages[message.id];
      return { changed: true, result: true };
    });
  }

  purgeExpiredMessages() {
    return this.#safeCleanup(this.#hasExpiredMessages(), () => this.#removeExpiredMessages());
  }

  purgeExpiredRequests() {
    return this.#safeCleanup(this.#hasExpiredRequests(), () => this.#removeExpiredRequests());
  }

  #allocateCode() {
    for (let attempt = 0; attempt < 10_000; attempt += 1) {
      const code = String(this.randomIntFn(100_000, 1_000_000));
      if (!this.state.codes[code]) return code;
    }
    for (let value = 100_000; value <= 999_999; value += 1) {
      const code = String(value);
      if (!this.state.codes[code]) return code;
    }
    throw new RegistryError('codes-exhausted', 'no pet codes available');
  }

  #hash(token) {
    return createHash('sha256').update(token).digest('hex');
  }

  #validPeerID(peerID) {
    if (typeof peerID !== 'string' || !PEER_ID_PATTERN.test(peerID)) {
      throw new RegistryError('invalid-peer-id', 'invalid peer id');
    }
    return peerID.toLowerCase();
  }

  #validToken(authToken) {
    if (typeof authToken !== 'string' || !AUTH_TOKEN_PATTERN.test(authToken)) {
      throw new RegistryError('invalid-auth-token', 'invalid auth token');
    }
    return authToken.toLowerCase();
  }

  #validFriendPeerIDs(friendPeerIDs, ownPeerID) {
    if (!Array.isArray(friendPeerIDs) || friendPeerIDs.length > FRIEND_LIMIT) {
      throw new RegistryError('invalid-friend-list', 'invalid friend list');
    }
    const normalized = friendPeerIDs.map((peerID) => this.#validPeerID(peerID));
    return [...new Set(normalized.filter((peerID) => peerID !== ownPeerID))];
  }

  #addFriend(peerID, friendPeerID) {
    const identity = this.state.identities[peerID];
    if (!identity) return;
    this.#assertCanAddFriend(peerID, friendPeerID);
    identity.friendPeerIDs = [...new Set([...(identity.friendPeerIDs ?? []), friendPeerID])];
    identity.updatedAt = this.now();
  }

  #assertCanAddFriend(peerID, friendPeerID) {
    const identity = this.state.identities[peerID];
    if (!identity) throw new RegistryError('identity-not-found', 'identity not found');
    const friends = identity.friendPeerIDs ?? [];
    if (!friends.includes(friendPeerID) && friends.length >= FRIEND_LIMIT) {
      throw new RegistryError('too-many-friends', 'too many friends');
    }
  }

  #areMutualFriends(firstPeerID, secondPeerID) {
    const first = this.state.identities[firstPeerID];
    const second = this.state.identities[secondPeerID];
    return Boolean(
      first
      && second
      && !this.#isRemovedFriendship(firstPeerID, secondPeerID)
      && (first.friendPeerIDs ?? []).includes(secondPeerID)
      && (second.friendPeerIDs ?? []).includes(firstPeerID)
    );
  }

  #friendshipKey(firstPeerID, secondPeerID) {
    return [firstPeerID, secondPeerID].sort().join(':');
  }

  #isRemovedFriendship(firstPeerID, secondPeerID) {
    return Boolean(this.state.removedFriendships[this.#friendshipKey(firstPeerID, secondPeerID)]);
  }

  #removeMessagesBetween(firstPeerID, secondPeerID) {
    let changed = false;
    for (const message of Object.values(this.state.messages)) {
      const connectsPeers = (message.fromPeerID === firstPeerID && message.toPeerID === secondPeerID)
        || (message.fromPeerID === secondPeerID && message.toPeerID === firstPeerID);
      if (!connectsPeers) continue;
      delete this.state.messages[message.id];
      changed = true;
    }
    return changed;
  }

  #removeUnauthorizedMessagesFor(peerID) {
    let changed = false;
    for (const message of Object.values(this.state.messages)) {
      if (message.fromPeerID !== peerID && message.toPeerID !== peerID) continue;
      if (this.#areMutualFriends(message.fromPeerID, message.toPeerID)) continue;
      delete this.state.messages[message.id];
      changed = true;
    }
    return changed;
  }

  #hasUnauthorizedMessagesFor(peerID) {
    return Object.values(this.state.messages).some((message) =>
      (message.fromPeerID === peerID || message.toPeerID === peerID)
      && !this.#areMutualFriends(message.fromPeerID, message.toPeerID)
    );
  }

  #hasExpiredMessages() {
    if (!(this.messageTTL > 0)) return false;
    const cutoff = this.now() - this.messageTTL;
    return Object.values(this.state.messages).some((message) => message.createdAt <= cutoff);
  }

  #removeExpiredMessages() {
    if (!(this.messageTTL > 0)) return false;
    const cutoff = this.now() - this.messageTTL;
    let changed = false;
    for (const message of Object.values(this.state.messages)) {
      if (message.createdAt > cutoff) continue;
      delete this.state.messages[message.id];
      changed = true;
    }
    return changed;
  }

  #removeExpiredRequests() {
    const now = this.now();
    let changed = false;
    for (const request of Object.values(this.state.requests)) {
      if (!this.#requestIsExpired(request, now)) continue;
      delete this.state.requests[request.id];
      changed = true;
    }
    return changed;
  }

  #hasExpiredRequests() {
    const now = this.now();
    return Object.values(this.state.requests).some((request) => this.#requestIsExpired(request, now));
  }

  #requestIsExpired(request, now) {
    const pendingExpired = request.status === 'pending'
      && this.requestPendingTTL > 0
      && request.createdAt <= now - this.requestPendingTTL;
    const resultTimestamp = Number.isFinite(request.respondedAt) ? request.respondedAt : request.createdAt;
    const resultExpired = request.status !== 'pending'
      && this.requestResultTTL > 0
      && resultTimestamp <= now - this.requestResultTTL;
    return pendingExpired || resultExpired;
  }

  #mutate(callback) {
    const previousState = this.state;
    this.state = structuredClone(previousState);
    try {
      const { changed, result } = callback();
      if (changed) this.#persist();
      return result;
    } catch (error) {
      this.state = previousState;
      throw error;
    }
  }

  #safeCleanup(cleanupNeeded, callback) {
    if (!cleanupNeeded) return false;
    try {
      return this.#mutate(() => {
        const changed = callback();
        return { changed, result: changed };
      });
    } catch (error) {
      if (error instanceof RegistryError && error.code === 'registry-write-failed') return false;
      throw error;
    }
  }

  #load() {
    if (!this.filePath || !existsSync(this.filePath)) {
      return { version: 3, identities: {}, codes: {}, requests: {}, messages: {}, removedFriendships: {} };
    }
    try {
      const parsed = JSON.parse(readFileSync(this.filePath, 'utf8'));
      const identities = parsed.identities ?? {};
      for (const identity of Object.values(identities)) {
        identity.friendPeerIDs = Array.isArray(identity.friendPeerIDs)
          ? [...new Set(identity.friendPeerIDs
            .filter((peerID) => typeof peerID === 'string' && PEER_ID_PATTERN.test(peerID))
            .map((peerID) => peerID.toLowerCase())
            .filter((peerID) => peerID !== identity.peerID))].slice(0, FRIEND_LIMIT)
          : [];
      }
      const removedFriendships = {};
      for (const relationship of Object.values(parsed.removedFriendships ?? {})) {
        if (!relationship || typeof relationship !== 'object') continue;
        const firstPeerID = typeof relationship.firstPeerID === 'string'
          ? relationship.firstPeerID.toLowerCase()
          : '';
        const secondPeerID = typeof relationship.secondPeerID === 'string'
          ? relationship.secondPeerID.toLowerCase()
          : '';
        if (!PEER_ID_PATTERN.test(firstPeerID)
            || !PEER_ID_PATTERN.test(secondPeerID)
            || firstPeerID === secondPeerID) continue;
        const [first, second] = [firstPeerID, secondPeerID].sort();
        removedFriendships[this.#friendshipKey(first, second)] = {
          firstPeerID: first,
          secondPeerID: second,
          removedAt: Number.isFinite(relationship.removedAt) ? relationship.removedAt : 0
        };
      }
      return {
        version: 3,
        identities,
        codes: parsed.codes ?? {},
        requests: parsed.requests ?? {},
        messages: parsed.messages ?? {},
        removedFriendships
      };
    } catch (error) {
      throw new RegistryError('registry-corrupt', `cannot read registry: ${error.message}`);
    }
  }

  #persist() {
    if (!this.filePath) return;
    const temporaryPath = `${this.filePath}.${process.pid}.tmp`;
    try {
      mkdirSync(dirname(this.filePath), { recursive: true });
      writeFileSync(temporaryPath, `${JSON.stringify(this.state)}\n`, { mode: 0o600 });
      renameSync(temporaryPath, this.filePath);
    } catch (error) {
      try {
        rmSync(temporaryPath, { force: true });
      } catch {
        // Preserve the original persistence error.
      }
      const message = error instanceof Error ? error.message : String(error);
      throw new RegistryError('registry-write-failed', `cannot write registry: ${message}`);
    }
  }
}
