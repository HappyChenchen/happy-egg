import { createHash, randomInt, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

const PEER_ID_PATTERN = /^[a-f0-9]{32}$/i;
const AUTH_TOKEN_PATTERN = /^[a-f0-9]{64}$/i;
const PET_CODE_PATTERN = /^\d{6}$/;

export class RegistryError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export class PetRegistry {
  constructor({ filePath = null, randomIntFn = randomInt, now = () => Date.now() } = {}) {
    this.filePath = filePath;
    this.randomIntFn = randomIntFn;
    this.now = now;
    this.state = this.#load();
  }

  registerIdentity({ peerID, authToken, name }) {
    const normalizedPeerID = this.#validPeerID(peerID);
    const normalizedToken = this.#validToken(authToken);
    const tokenHash = this.#hash(normalizedToken);
    const existing = this.state.identities[normalizedPeerID];
    if (existing && existing.tokenHash !== tokenHash) {
      throw new RegistryError('authentication-failed', 'device authentication failed');
    }
    if (existing) {
      existing.name = String(name).trim();
      existing.updatedAt = this.now();
      this.#persist();
      return this.identity(normalizedPeerID);
    }
    const petCode = this.#allocateCode();
    this.state.identities[normalizedPeerID] = {
      peerID: normalizedPeerID,
      tokenHash,
      petCode,
      name: String(name).trim(),
      createdAt: this.now(),
      updatedAt: this.now()
    };
    this.state.codes[petCode] = normalizedPeerID;
    this.#persist();
    return this.identity(normalizedPeerID);
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
    const identity = this.state.identities[normalizedPeerID];
    if (!identity) throw new RegistryError('identity-not-found', 'identity not found');
    delete this.state.codes[identity.petCode];
    identity.petCode = this.#allocateCode();
    identity.updatedAt = this.now();
    this.state.codes[identity.petCode] = normalizedPeerID;
    this.#persist();
    return this.identity(normalizedPeerID);
  }

  createFriendRequest({ fromPeerID, targetCode, fromName }) {
    const normalizedFromID = this.#validPeerID(fromPeerID);
    const target = this.findByCode(targetCode);
    if (!target) throw new RegistryError('pet-code-not-found', 'pet code not found');
    if (target.peerID === normalizedFromID) throw new RegistryError('self-request', 'cannot add yourself');
    const existing = Object.values(this.state.requests).find((request) =>
      request.status === 'pending' && request.fromPeerID === normalizedFromID && request.toPeerID === target.peerID
    );
    if (existing) return structuredClone(existing);
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
    this.#persist();
    return structuredClone(request);
  }

  respondToFriendRequest({ requestID, responderPeerID, accept }) {
    const request = this.state.requests[String(requestID).toLowerCase()];
    const normalizedResponder = this.#validPeerID(responderPeerID);
    if (!request || request.status !== 'pending' || request.toPeerID !== normalizedResponder) {
      throw new RegistryError('request-not-found', 'friend request not found');
    }
    request.fromName = this.state.identities[request.fromPeerID]?.name ?? request.fromName;
    request.toName = this.state.identities[request.toPeerID]?.name ?? request.toName;
    request.status = accept ? 'accepted' : 'rejected';
    request.respondedAt = this.now();
    request.deliveredTo = [];
    this.#persist();
    return structuredClone(request);
  }

  notificationsFor(peerID) {
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
    const request = this.state.requests[String(requestID).toLowerCase()];
    const normalizedPeerID = this.#validPeerID(peerID);
    if (!request || request.status === 'pending') return false;
    const expected = request.status === 'accepted'
      ? [request.fromPeerID, request.toPeerID]
      : [request.fromPeerID];
    if (!expected.includes(normalizedPeerID)) return false;
    if (!request.deliveredTo.includes(normalizedPeerID)) request.deliveredTo.push(normalizedPeerID);
    if (expected.every((participant) => request.deliveredTo.includes(participant))) {
      delete this.state.requests[request.id];
    }
    this.#persist();
    return true;
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

  #load() {
    if (!this.filePath || !existsSync(this.filePath)) {
      return { version: 1, identities: {}, codes: {}, requests: {} };
    }
    try {
      const parsed = JSON.parse(readFileSync(this.filePath, 'utf8'));
      return {
        version: 1,
        identities: parsed.identities ?? {},
        codes: parsed.codes ?? {},
        requests: parsed.requests ?? {}
      };
    } catch (error) {
      throw new RegistryError('registry-corrupt', `cannot read registry: ${error.message}`);
    }
  }

  #persist() {
    if (!this.filePath) return;
    mkdirSync(dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.${process.pid}.tmp`;
    writeFileSync(temporaryPath, `${JSON.stringify(this.state)}\n`, { mode: 0o600 });
    renameSync(temporaryPath, this.filePath);
  }
}
