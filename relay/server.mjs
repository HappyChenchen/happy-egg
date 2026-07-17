import http from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import { PetRegistry, RegistryError } from './registry.mjs';

const ROOM_PATTERN = /^(?:\d{4}|[a-hj-km-np-z2-9]{8}|[a-f0-9]{64})$/i;
const PROFILE_ID_PATTERN = /^[a-f0-9]{32}$/i;
const AUTH_TOKEN_PATTERN = /^[a-f0-9]{64}$/i;
const EVENT_ID_PATTERN = PROFILE_ID_PATTERN;
const EVENT_KINDS = new Set(['poke', 'heart', 'celebrate']);
const FRAME_NAMES = new Set([
  'ai_buddy_00', 'ai_buddy_03', 'ai_buddy_04', 'ai_buddy_05', 'ai_buddy_06',
  'ai_buddy_07', 'ai_buddy_08', 'ai_buddy_09', 'ai_buddy_10', 'ai_buddy_11'
]);
const MESSAGE_KINDS = new Set(['text', 'sticker']);
const STICKER_IDS = new Set([
  'sticker_wave', 'sticker_love', 'sticker_laugh', 'sticker_cry', 'sticker_thumbsup',
  'sticker_party', 'sticker_gift', 'sticker_coffee', 'sticker_moon', 'sticker_flower'
]);
const MAX_MESSAGE_LENGTH = 300;
const MAX_WEBSOCKET_PAYLOAD = 16 * 1024;
const TEMPORARY_SERVER_ERROR = 'temporary server error';

function validMessageBody(kind, body) {
  if (typeof body !== 'string') return null;
  if (kind === 'sticker') return STICKER_IDS.has(body) ? body : null;
  const trimmed = body.trim();
  if (trimmed.length === 0 || Array.from(trimmed).length > MAX_MESSAGE_LENGTH) return null;
  return trimmed;
}

function send(socket, payload) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload));
}

function sendAndConfirm(socket, payload) {
  return new Promise((resolve) => {
    if (socket.readyState !== WebSocket.OPEN) return resolve(false);
    socket.send(JSON.stringify(payload), (error) => resolve(error == null));
  });
}

function validName(name) {
  return typeof name === 'string' && name.trim().length > 0 && name.length <= 32;
}

function validPeerID(peerID) {
  return peerID === undefined || peerID === null || (typeof peerID === 'string' && PROFILE_ID_PATTERN.test(peerID));
}

function rateLimited(meta, { key = 'sentAt', limit = 20, windowMs = 60_000 } = {}) {
  const now = Date.now();
  meta[key] = (meta[key] ?? []).filter((timestamp) => now - timestamp < windowMs);
  if (meta[key].length >= limit) return true;
  meta[key].push(now);
  return false;
}

function keyedRateLimited(buckets, key, { limit, windowMs }) {
  const now = Date.now();
  const recent = (buckets.get(key) ?? []).filter((timestamp) => now - timestamp < windowMs);
  buckets.set(key, recent);
  if (recent.length >= limit) return true;
  recent.push(now);
  return false;
}

function pruneRateBuckets(buckets, windowMs) {
  const cutoff = Date.now() - windowMs;
  for (const [key, timestamps] of buckets) {
    if (timestamps.length === 0 || timestamps.at(-1) <= cutoff) buckets.delete(key);
  }
}

function clientAddress(request, trustProxy) {
  const remoteAddress = request.socket.remoteAddress || 'unknown';
  if (!trustProxy) return remoteAddress;
  const forwarded = request.headers['x-forwarded-for'];
  const forwardedValue = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  return forwardedValue?.split(',')[0].trim() || remoteAddress;
}

function isRegistryWriteFailure(error) {
  return error instanceof RegistryError && error.code === 'registry-write-failed';
}

export function createRelayServer({
  pairingTTL = 10 * 60_000,
  heartbeatInterval = 30_000,
  presenceOfflineGrace = 5_000,
  messageRateLimit = 30,
  messageAddressRateLimit = 300,
  messageRateWindow = 60_000,
  ackRateLimit = 300,
  ackAddressRateLimit = 3_000,
  ackRateWindow = 60_000,
  friendRemovalRateLimit = 10,
  friendRemovalAddressRateLimit = 100,
  presenceRegistrationRateLimit = 21,
  presenceRegistrationAddressRateLimit = 600,
  newIdentityAddressRateLimit = 20,
  presenceRegistrationRateWindow = 60_000,
  newIdentityRateWindow = 60 * 60_000,
  messageCleanupInterval = 60_000,
  maxPayload = MAX_WEBSOCKET_PAYLOAD,
  trustProxy = false,
  onBackgroundError = (error) => console.error('MacPet relay background task failed', error),
  onInternalError = (error) => console.error('MacPet relay request failed', error),
  registry = new PetRegistry({ filePath: process.env.MACPET_REGISTRY_PATH ?? null })
} = {}) {
  const rooms = new Map();
  const metadata = new WeakMap();
  const roomExpiryTimers = new Map();
  const onlineProfiles = new Map();
  const presenceWatchers = new Map();
  const presenceOfflineTimers = new Map();
  const clientAddresses = new WeakMap();
  const messageRatesByPeerID = new Map();
  const messageRatesByAddress = new Map();
  const ackRatesByPeerID = new Map();
  const ackRatesByAddress = new Map();
  const friendRemovalRatesByPeerID = new Map();
  const friendRemovalRatesByAddress = new Map();
  const presenceRegistrationRatesByPeerID = new Map();
  const presenceRegistrationRatesByAddress = new Map();
  const newIdentityRatesByAddress = new Map();
  const server = http.createServer((request, response) => {
    if (request.url === '/health') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: true }));
      return;
    }
    response.writeHead(404).end();
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload });
  const heartbeatTimer = heartbeatInterval > 0 ? setInterval(() => {
    for (const socket of wss.clients) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      if (socket.isAlive === false) {
        socket.terminate();
        continue;
      }
      socket.isAlive = false;
      socket.ping();
    }
  }, heartbeatInterval) : null;
  const rateLimitCleanupTimer = setInterval(() => {
    pruneRateBuckets(messageRatesByPeerID, messageRateWindow);
    pruneRateBuckets(messageRatesByAddress, messageRateWindow);
    pruneRateBuckets(ackRatesByPeerID, ackRateWindow);
    pruneRateBuckets(ackRatesByAddress, ackRateWindow);
    pruneRateBuckets(friendRemovalRatesByPeerID, messageRateWindow);
    pruneRateBuckets(friendRemovalRatesByAddress, messageRateWindow);
    pruneRateBuckets(presenceRegistrationRatesByPeerID, presenceRegistrationRateWindow);
    pruneRateBuckets(presenceRegistrationRatesByAddress, presenceRegistrationRateWindow);
    pruneRateBuckets(newIdentityRatesByAddress, newIdentityRateWindow);
  }, Math.max(1_000, Math.min(messageRateWindow, ackRateWindow, presenceRegistrationRateWindow)));
  rateLimitCleanupTimer.unref?.();
  function runBackgroundTask(task) {
    try {
      task();
    } catch (error) {
      try {
        onBackgroundError(error);
      } catch (reportingError) {
        console.error('MacPet relay background error handler failed', reportingError);
      }
    }
  }

  const messageCleanupTimer = messageCleanupInterval > 0 ? setInterval(() => {
    runBackgroundTask(() => registry.purgeExpiredMessages());
    runBackgroundTask(() => registry.purgeExpiredRequests());
  }, messageCleanupInterval) : null;
  messageCleanupTimer?.unref?.();

  function clearRoomExpiry(roomID) {
    const timer = roomExpiryTimers.get(roomID);
    if (timer) clearTimeout(timer);
    roomExpiryTimers.delete(roomID);
  }

  function expireRoom(roomID) {
    const room = rooms.get(roomID);
    if (!room || room.size !== 1) return clearRoomExpiry(roomID);
    rooms.delete(roomID);
    clearRoomExpiry(roomID);
    for (const socket of room) {
      send(socket, { type: 'error', message: '配对码已过期' });
      metadata.delete(socket);
      socket.close(4001, 'pairing expired');
    }
  }

  function removeWatcherSubscriptions(socket, watchedPeerIDs) {
    for (const peerID of watchedPeerIDs ?? []) {
      const watchers = presenceWatchers.get(peerID);
      watchers?.delete(socket);
      if (watchers?.size === 0) presenceWatchers.delete(peerID);
    }
  }

  function profileWatches(peerID, otherPeerID) {
    return [...(onlineProfiles.get(peerID) ?? [])].some((session) => {
      const sessionMeta = metadata.get(session);
      return sessionMeta?.mode === 'presence' && sessionMeta.watchedPeerIDs.has(otherPeerID);
    });
  }

  function relationshipAuthorized(meta, otherPeerID) {
    if (!meta?.authenticated) return true;
    try {
      return registry.areMutualFriends(meta.peerID, otherPeerID);
    } catch {
      return false;
    }
  }

  function notifyProfilePresence(peerID) {
    for (const watcher of presenceWatchers.get(peerID) ?? []) {
      const watcherMeta = metadata.get(watcher);
      if (watcherMeta?.mode !== 'presence') continue;
      const online = onlineProfiles.has(peerID)
        && profileWatches(peerID, watcherMeta.peerID)
        && relationshipAuthorized(watcherMeta, peerID);
      send(watcher, { type: 'friend-presence', peerID, online });
    }
  }

  function notifyProfileName(peerID, name) {
    for (const watcher of presenceWatchers.get(peerID) ?? []) {
      const watcherMeta = metadata.get(watcher);
      if (watcherMeta?.mode !== 'presence'
          || !profileWatches(peerID, watcherMeta.peerID)
          || !relationshipAuthorized(watcherMeta, peerID)) continue;
      send(watcher, { type: 'friend-profile', peerID, name });
    }
  }

  function cancelPresenceOffline(peerID) {
    const timer = presenceOfflineTimers.get(peerID);
    if (timer) clearTimeout(timer);
    presenceOfflineTimers.delete(peerID);
  }

  function schedulePresenceOffline(peerID) {
    cancelPresenceOffline(peerID);
    if (presenceOfflineGrace <= 0) return notifyProfilePresence(peerID);
    presenceOfflineTimers.set(peerID, setTimeout(() => {
      presenceOfflineTimers.delete(peerID);
      if (!onlineProfiles.has(peerID)) notifyProfilePresence(peerID);
    }, presenceOfflineGrace));
  }

  function leavePresence(socket, meta) {
    removeWatcherSubscriptions(socket, meta.watchedPeerIDs);
    const sessions = onlineProfiles.get(meta.peerID);
    sessions?.delete(socket);
    if (sessions?.size === 0) {
      onlineProfiles.delete(meta.peerID);
      schedulePresenceOffline(meta.peerID);
    }
    metadata.delete(socket);
  }

  function leave(socket) {
    const meta = metadata.get(socket);
    if (!meta) return;
    if (meta.mode === 'presence') return leavePresence(socket, meta);
    const room = rooms.get(meta.room);
    room?.delete(socket);
    if (room?.size === 0) {
      rooms.delete(meta.room);
      clearRoomExpiry(meta.room);
    }
    metadata.delete(socket);
    for (const peer of room ?? []) send(peer, { type: 'presence', connected: room.size });
  }

  function validFriendPeerIDs(friendPeerIDs) {
    return Array.isArray(friendPeerIDs)
      && friendPeerIDs.length <= 100
      && friendPeerIDs.every((peerID) => typeof peerID === 'string' && PROFILE_ID_PATTERN.test(peerID));
  }

  function requestFailure(socket, error) {
    if (isRegistryWriteFailure(error)) throw error;
    const code = error instanceof RegistryError ? error.code : 'request-failed';
    const message = error instanceof RegistryError ? error.message : 'friend request failed';
    send(socket, { type: 'friend-request-failed', code, message });
  }

  function notificationPayload(request, peerID) {
    if (request.status === 'pending') {
      return {
        type: 'friend-request-incoming',
        requestID: request.id,
        senderPeerID: request.fromPeerID,
        senderName: request.fromName
      };
    }
    if (request.status === 'rejected') {
      return { type: 'friend-request-rejected', requestID: request.id };
    }
    const requester = peerID === request.fromPeerID;
    return {
      type: 'friend-request-accepted',
      requestID: request.id,
      peerID: requester ? request.toPeerID : request.fromPeerID,
      name: requester ? request.toName : request.fromName
    };
  }

  function deliverNotificationsToSocket(socket, peerID) {
    for (const request of registry.notificationsFor(peerID)) {
      send(socket, notificationPayload(request, peerID));
    }
  }

  function deliverNotificationsToOnlinePeer(peerID) {
    for (const socket of onlineProfiles.get(peerID) ?? []) {
      const meta = metadata.get(socket);
      if (meta?.mode === 'presence' && meta.authenticated) {
        deliverNotificationsToSocket(socket, peerID);
      }
    }
  }

  function deliverMessagesToSocket(socket, meta) {
    for (const message of registry.messagesFor(meta.peerID)) {
      if (!meta.watchedPeerIDs.has(message.fromPeerID)) continue;
      send(socket, {
        type: 'friend-message-incoming',
        messageID: message.id,
        senderPeerID: message.fromPeerID,
        senderName: message.fromName,
        kind: message.kind,
        body: message.body,
        createdAt: message.createdAt
      });
    }
  }

  function deliverMessagesToOnlinePeer(peerID) {
    for (const socket of onlineProfiles.get(peerID) ?? []) {
      const meta = metadata.get(socket);
      if (meta?.mode === 'presence' && meta.authenticated) {
        deliverMessagesToSocket(socket, meta);
      }
    }
  }

  function registerPresence(socket, message) {
    if (!validPeerID(message.peerID) || !message.peerID || !validName(message.name) || !validFriendPeerIDs(message.friendPeerIDs)) {
      return reject(socket, 'invalid presence');
    }
    const peerID = message.peerID.toLowerCase();
    const previousIdentityName = registry.identity(peerID)?.name ?? null;
    let identity = null;
    if (message.authToken !== undefined) {
      if (typeof message.authToken !== 'string' || !AUTH_TOKEN_PATTERN.test(message.authToken)) {
        return reject(socket, 'invalid presence');
      }
      if (previousIdentityName != null) {
        try {
          registry.authenticateIdentity({ peerID, authToken: message.authToken });
        } catch (error) {
          if (isRegistryWriteFailure(error)) throw error;
          return reject(socket, error instanceof RegistryError ? error.message : 'identity authentication failed');
        }
      }
    } else if (previousIdentityName != null) {
      return reject(socket, 'authentication required');
    }
    const address = clientAddresses.get(socket) ?? 'unknown';
    const addressLimited = keyedRateLimited(presenceRegistrationRatesByAddress, address, {
      limit: presenceRegistrationAddressRateLimit,
      windowMs: presenceRegistrationRateWindow
    });
    const peerLimited = keyedRateLimited(presenceRegistrationRatesByPeerID, peerID, {
      limit: presenceRegistrationRateLimit,
      windowMs: presenceRegistrationRateWindow
    });
    const newIdentityLimited = message.authToken !== undefined
      && previousIdentityName == null
      && keyedRateLimited(newIdentityRatesByAddress, address, {
        limit: newIdentityAddressRateLimit,
        windowMs: newIdentityRateWindow
      });
    if (addressLimited || peerLimited || newIdentityLimited) return reject(socket, 'rate limit');
    if (message.authToken !== undefined) {
      try {
        identity = registry.registerIdentity({
          peerID,
          authToken: message.authToken,
          name: message.name,
          friendPeerIDs: message.friendPeerIDs
        });
      } catch (error) {
        if (isRegistryWriteFailure(error)) throw error;
        return reject(socket, error instanceof RegistryError ? error.message : 'identity registration failed');
      }
    }
    const reportedPeerIDs = new Set(message.friendPeerIDs
      .map((friendID) => friendID.toLowerCase())
      .filter((friendID) => friendID !== peerID));
    const removedPeerIDs = identity
      ? new Set(registry.removedFriendsFor(peerID).filter((friendID) => reportedPeerIDs.has(friendID)))
      : new Set();
    const watchedPeerIDs = new Set([...reportedPeerIDs].filter((friendID) => !removedPeerIDs.has(friendID)));
    const existing = metadata.get(socket);
    const updatesExistingSession = existing?.mode === 'presence' && existing.peerID === peerID;
    const relationshipChanged = !updatesExistingSession
      || existing.watchedPeerIDs.size !== watchedPeerIDs.size
      || [...existing.watchedPeerIDs].some((friendID) => !watchedPeerIDs.has(friendID));
    const previousName = existing?.mode === 'presence' && existing.peerID === peerID
      ? existing.name
      : previousIdentityName;

    if (updatesExistingSession) {
      removeWatcherSubscriptions(socket, existing.watchedPeerIDs);
      existing.name = message.name.trim();
      existing.watchedPeerIDs = watchedPeerIDs;
      existing.authenticated = identity != null;
    } else {
      leave(socket);
      cancelPresenceOffline(peerID);
      const sessions = onlineProfiles.get(peerID) ?? new Set();
      sessions.add(socket);
      onlineProfiles.set(peerID, sessions);
      metadata.set(socket, {
        mode: 'presence', peerID, name: message.name.trim(), watchedPeerIDs, authenticated: identity != null, sentAt: []
      });
    }

    for (const friendID of watchedPeerIDs) {
      const watchers = presenceWatchers.get(friendID) ?? new Set();
      watchers.add(socket);
      presenceWatchers.set(friendID, watchers);
    }
    if (relationshipChanged) notifyProfilePresence(peerID);
    if (previousName && previousName !== message.name.trim()) notifyProfileName(peerID, message.name.trim());
    const onlinePeerIDs = [...watchedPeerIDs].filter((friendID) =>
      onlineProfiles.has(friendID)
        && profileWatches(friendID, peerID)
        && relationshipAuthorized(metadata.get(socket), friendID)
    );
    if (identity) {
      send(socket, { type: 'pet-code', petCode: identity.petCode });
    }
    send(socket, { type: 'presence-snapshot', onlinePeerIDs });
    for (const removedPeerID of removedPeerIDs) {
      send(socket, { type: 'friend-removed', peerID: removedPeerID });
    }
    if (identity) {
      deliverNotificationsToSocket(socket, peerID);
      deliverMessagesToSocket(socket, metadata.get(socket));
    }
  }

  function createFriendRequest(socket, meta, message) {
    if (!meta.authenticated) return requestFailure(socket, new RegistryError('authentication-required', 'authentication required'));
    if (rateLimited(meta)) return requestFailure(socket, new RegistryError('rate-limit', 'rate limit'));
    try {
      const request = registry.createFriendRequest({
        fromPeerID: meta.peerID,
        targetCode: message.petCode,
        fromName: meta.name
      });
      send(socket, {
        type: 'friend-request-created', requestID: request.id, petCode: String(message.petCode), targetName: request.toName
      });
      deliverNotificationsToOnlinePeer(request.toPeerID);
    } catch (error) {
      requestFailure(socket, error);
    }
  }

  function respondToFriendRequest(socket, meta, message) {
    if (!meta.authenticated || typeof message.accept !== 'boolean') {
      return requestFailure(socket, new RegistryError('invalid-request', 'invalid friend request response'));
    }
    if (rateLimited(meta)) return requestFailure(socket, new RegistryError('rate-limit', 'rate limit'));
    try {
      const request = registry.respondToFriendRequest({
        requestID: message.requestID,
        responderPeerID: meta.peerID,
        accept: message.accept
      });
      deliverNotificationsToOnlinePeer(request.fromPeerID);
      if (request.status === 'accepted') deliverNotificationsToOnlinePeer(request.toPeerID);
      else send(socket, { type: 'friend-request-responded', requestID: request.id, accepted: false });
    } catch (error) {
      requestFailure(socket, error);
    }
  }

  function resetPetCode(socket, meta) {
    if (!meta.authenticated) return requestFailure(socket, new RegistryError('authentication-required', 'authentication required'));
    if (rateLimited(meta)) return requestFailure(socket, new RegistryError('rate-limit', 'rate limit'));
    try {
      const identity = registry.resetCode(meta.peerID);
      send(socket, { type: 'pet-code', petCode: identity.petCode, reset: true });
    } catch (error) {
      requestFailure(socket, error);
    }
  }

  function removeFriendFromOnlineSessions(peerID, friendPeerID) {
    for (const session of onlineProfiles.get(peerID) ?? []) {
      const sessionMeta = metadata.get(session);
      if (sessionMeta?.mode !== 'presence') continue;
      sessionMeta.watchedPeerIDs.delete(friendPeerID);
      const watchers = presenceWatchers.get(friendPeerID);
      watchers?.delete(session);
      if (watchers?.size === 0) presenceWatchers.delete(friendPeerID);
      send(session, { type: 'friend-removed', peerID: friendPeerID });
    }
  }

  function removeFriend(socket, meta, message) {
    const rawTargetPeerID = message.targetPeerID;
    if (!meta.authenticated || typeof rawTargetPeerID !== 'string' || !PROFILE_ID_PATTERN.test(rawTargetPeerID)) {
      return send(socket, { type: 'friend-remove-failed', message: 'invalid friend removal' });
    }
    const targetPeerID = rawTargetPeerID.toLowerCase();
    const address = clientAddresses.get(socket) ?? 'unknown';
    const addressLimited = keyedRateLimited(friendRemovalRatesByAddress, address, {
      limit: friendRemovalAddressRateLimit,
      windowMs: messageRateWindow
    });
    const peerLimited = keyedRateLimited(friendRemovalRatesByPeerID, meta.peerID, {
      limit: friendRemovalRateLimit,
      windowMs: messageRateWindow
    });
    if (addressLimited || peerLimited) {
      return send(socket, { type: 'friend-remove-failed', peerID: targetPeerID, message: 'rate limit' });
    }
    try {
      registry.removeFriendship({ peerID: meta.peerID, friendPeerID: targetPeerID });
    } catch (error) {
      if (isRegistryWriteFailure(error)) throw error;
      return send(socket, {
        type: 'friend-remove-failed',
        peerID: targetPeerID,
        message: error instanceof RegistryError ? error.message : 'friend removal failed'
      });
    }
    removeFriendFromOnlineSessions(meta.peerID, targetPeerID);
    removeFriendFromOnlineSessions(targetPeerID, meta.peerID);
    notifyProfilePresence(meta.peerID);
    notifyProfilePresence(targetPeerID);
  }

  async function routeFriendEvent(socket, meta, message) {
    if (typeof message.targetPeerID !== 'string' || !PROFILE_ID_PATTERN.test(message.targetPeerID)) {
      return reject(socket, 'invalid friend event');
    }
    if (message.eventID !== undefined && (typeof message.eventID !== 'string' || !EVENT_ID_PATTERN.test(message.eventID))) {
      return reject(socket, 'invalid friend event');
    }
    if (!EVENT_KINDS.has(message.kind) || !FRAME_NAMES.has(message.frameName)) {
      return reject(socket, 'invalid friend event');
    }
    if (rateLimited(meta)) return reject(socket, 'rate limit');
    const targetPeerID = message.targetPeerID.toLowerCase();
    const eventID = typeof message.eventID === 'string' ? message.eventID.toLowerCase() : null;
    if (!relationshipAuthorized(meta, targetPeerID)) {
      send(socket, { type: 'friend-event-rejected', targetPeerID, message: 'friend unavailable', ...(eventID ? { eventID } : {}) });
      return;
    }
    const targetSessions = [...(onlineProfiles.get(targetPeerID) ?? [])].filter((targetSocket) => {
      const targetMeta = metadata.get(targetSocket);
      return targetMeta?.mode === 'presence' && targetMeta.watchedPeerIDs.has(meta.peerID);
    });
    if (!meta.watchedPeerIDs.has(targetPeerID) || targetSessions.length === 0) {
      send(socket, { type: 'friend-event-rejected', targetPeerID, message: 'friend unavailable', ...(eventID ? { eventID } : {}) });
      return;
    }
    const deliveryResults = await Promise.all(targetSessions.map((targetSocket) =>
      sendAndConfirm(targetSocket, {
        type: 'friend-event',
        kind: message.kind,
        frameName: message.frameName,
        senderName: meta.name,
        senderPeerID: meta.peerID
      })
    ));
    if (!deliveryResults.some(Boolean)) {
      for (const targetSocket of targetSessions) targetSocket.terminate();
      send(socket, { type: 'friend-event-rejected', targetPeerID, message: 'friend unavailable', ...(eventID ? { eventID } : {}) });
      return;
    }
    if (eventID) send(socket, { type: 'friend-event-delivered', eventID });
  }

  function routeFriendMessage(socket, meta, message) {
    if (typeof message.messageID !== 'string' || !EVENT_ID_PATTERN.test(message.messageID)) {
      return reject(socket, 'invalid friend message');
    }
    if (typeof message.targetPeerID !== 'string' || !PROFILE_ID_PATTERN.test(message.targetPeerID)) {
      return reject(socket, 'invalid friend message');
    }
    if (!MESSAGE_KINDS.has(message.kind)) return reject(socket, 'invalid friend message');
    const body = validMessageBody(message.kind, message.body);
    if (body === null) return reject(socket, 'invalid friend message');
    const messageID = message.messageID.toLowerCase();
    const targetPeerID = message.targetPeerID.toLowerCase();
    if (!meta.authenticated) {
      return send(socket, { type: 'friend-message-failed', messageID, message: 'authentication required' });
    }
    if (!meta.watchedPeerIDs.has(targetPeerID)) {
      return send(socket, { type: 'friend-message-failed', messageID, message: 'not friends' });
    }
    if (!registry.areMutualFriends(meta.peerID, targetPeerID)) {
      return send(socket, { type: 'friend-message-failed', messageID, message: 'not friends' });
    }
    const address = clientAddresses.get(socket) ?? 'unknown';
    const addressLimited = keyedRateLimited(messageRatesByAddress, address, {
      limit: messageAddressRateLimit,
      windowMs: messageRateWindow
    });
    const peerLimited = keyedRateLimited(messageRatesByPeerID, meta.peerID, {
      limit: messageRateLimit,
      windowMs: messageRateWindow
    });
    if (addressLimited || peerLimited) {
      return send(socket, { type: 'friend-message-failed', messageID, message: 'rate limit' });
    }
    let stored;
    try {
      stored = registry.enqueueMessage({
        id: messageID,
        fromPeerID: meta.peerID,
        toPeerID: targetPeerID,
        fromName: meta.name,
        kind: message.kind,
        body
      });
    } catch (error) {
      if (isRegistryWriteFailure(error)) throw error;
      const failureMessage = error instanceof RegistryError ? error.message : 'friend message failed';
      return send(socket, { type: 'friend-message-failed', messageID, message: failureMessage });
    }
    deliverMessagesToOnlinePeer(targetPeerID);
    send(socket, { type: 'friend-message-sent', messageID: stored.id });
  }

  function reject(socket, message) {
    send(socket, { type: 'error', message });
    socket.close(1008, message);
  }

  function closeForInternalError(socket, error) {
    try {
      onInternalError(error);
    } catch (reportingError) {
      console.error('MacPet relay internal error handler failed', reportingError);
    }
    send(socket, { type: 'error', message: TEMPORARY_SERVER_ERROR });
    socket.close(1011, TEMPORARY_SERVER_ERROR);
  }

  function acknowledgeFriendPayload(socket, meta, message) {
    const address = clientAddresses.get(socket) ?? 'unknown';
    const addressLimited = keyedRateLimited(ackRatesByAddress, address, {
      limit: ackAddressRateLimit,
      windowMs: ackRateWindow
    });
    if (!meta.authenticated) return reject(socket, 'authentication required');
    const peerLimited = keyedRateLimited(ackRatesByPeerID, meta.peerID, {
      limit: ackRateLimit,
      windowMs: ackRateWindow
    });
    if (addressLimited || peerLimited) return reject(socket, 'rate limit');
    if (message.type === 'friend-request-ack') {
      registry.acknowledgeRequest({ requestID: message.requestID, peerID: meta.peerID });
      return;
    }
    registry.acknowledgeMessage({ messageID: message.messageID, peerID: meta.peerID });
  }

  function handleIncomingMessage(socket, raw) {
    socket.isAlive = true;
    let message;
    try { message = JSON.parse(raw.toString()); } catch { return reject(socket, 'invalid JSON'); }
    if (message === null || typeof message !== 'object' || Array.isArray(message)) {
      return reject(socket, 'invalid message');
    }

    if (message.type === 'presence-register') {
      registerPresence(socket, message);
      return;
    }

    if (message.type === 'join') {
      if (!ROOM_PATTERN.test(message.room) || !validName(message.name) || !validPeerID(message.peerID)) return reject(socket, 'invalid join');
      const roomID = message.room.toLowerCase();
      leave(socket);
      const room = rooms.get(roomID) ?? new Set();
      if (room.size >= 2) return reject(socket, 'room is full');
      room.add(socket);
      rooms.set(roomID, room);
      const peerID = typeof message.peerID === 'string' ? message.peerID.toLowerCase() : null;
      metadata.set(socket, { mode: 'room', room: roomID, name: message.name.trim(), peerID, sentAt: [] });
      if (room.size === 1 && pairingTTL > 0) {
        roomExpiryTimers.set(roomID, setTimeout(() => expireRoom(roomID), pairingTTL));
      } else if (room.size >= 2) {
        clearRoomExpiry(roomID);
      }
      const existingPeer = [...room].find((peer) => peer !== socket);
      const joined = { type: 'joined', connected: room.size, peerName: existingPeer ? metadata.get(existingPeer).name : null };
      if (existingPeer && metadata.get(existingPeer).peerID) joined.peerID = metadata.get(existingPeer).peerID;
      send(socket, joined);
      for (const peer of room) if (peer !== socket) {
        const presence = { type: 'presence', connected: room.size, peerName: message.name.trim() };
        if (peerID) presence.peerID = peerID;
        send(peer, presence);
      }
      return;
    }

    const meta = metadata.get(socket);
    if (!meta) return reject(socket, 'join required');
    if (meta.mode === 'presence') {
      if (message.type === 'friend-event') {
        void routeFriendEvent(socket, meta, message);
        return;
      }
      if (message.type === 'friend-request-create') return createFriendRequest(socket, meta, message);
      if (message.type === 'friend-request-respond') return respondToFriendRequest(socket, meta, message);
      if (message.type === 'friend-request-ack') return acknowledgeFriendPayload(socket, meta, message);
      if (message.type === 'friend-remove') return removeFriend(socket, meta, message);
      if (message.type === 'friend-message-send') return routeFriendMessage(socket, meta, message);
      if (message.type === 'friend-message-ack') return acknowledgeFriendPayload(socket, meta, message);
      if (message.type === 'pet-code-reset') return resetPetCode(socket, meta);
      return reject(socket, 'invalid presence message');
    }

    if (message.type === 'profile') {
      if (!validName(message.name)) return reject(socket, 'invalid profile');
      if (rateLimited(meta)) return reject(socket, 'rate limit');
      meta.name = message.name.trim();
      for (const peer of rooms.get(meta.room) ?? []) {
        if (peer !== socket) {
          const profile = { type: 'profile', peerName: meta.name };
          if (meta.peerID) profile.peerID = meta.peerID;
          send(peer, profile);
        }
      }
      return;
    }

    if (message.type !== 'event') return reject(socket, 'join required');
    if (!EVENT_KINDS.has(message.kind) || !FRAME_NAMES.has(message.frameName)) return reject(socket, 'invalid event');
    if (rateLimited(meta)) return reject(socket, 'rate limit');
    for (const peer of rooms.get(meta.room) ?? []) {
      if (peer !== socket) send(peer, { type: 'event', kind: message.kind, frameName: message.frameName, senderName: meta.name });
    }
  }

  wss.on('connection', (socket, request) => {
    clientAddresses.set(socket, clientAddress(request, trustProxy));
    socket.isAlive = true;
    socket.on('pong', () => { socket.isAlive = true; });
    socket.on('message', (raw) => {
      try {
        handleIncomingMessage(socket, raw);
      } catch (error) {
        closeForInternalError(socket, error);
      }
    });
    socket.on('close', () => leave(socket));
    socket.on('error', () => leave(socket));
  });

  server.on('upgrade', (request, socket, head) => {
    if (new URL(request.url, 'http://localhost').pathname !== '/ws') return socket.destroy();
    wss.handleUpgrade(request, socket, head, (websocket) => wss.emit('connection', websocket, request));
  });

  return {
    server,
    async listen(port = 8080, host = '0.0.0.0') {
      await new Promise((resolve) => server.listen(port, host, resolve));
      return server.address();
    },
    async close() {
      if (heartbeatTimer) clearInterval(heartbeatTimer);
      clearInterval(rateLimitCleanupTimer);
      if (messageCleanupTimer) clearInterval(messageCleanupTimer);
      for (const timer of roomExpiryTimers.values()) clearTimeout(timer);
      roomExpiryTimers.clear();
      for (const timer of presenceOfflineTimers.values()) clearTimeout(timer);
      presenceOfflineTimers.clear();
      for (const socket of wss.clients) socket.terminate();
      await new Promise((resolve) => server.close(resolve));
    }
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const relay = createRelayServer({
    trustProxy: ['1', 'true'].includes((process.env.MACPET_TRUST_PROXY ?? '').toLowerCase())
  });
  const port = Number(process.env.PORT ?? 8080);
  await relay.listen(port);
  console.log(`MacPet relay listening on port ${port}`);

  let shuttingDown = false;
  const shutdown = async (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`Received ${signal}; shutting down`);
    await relay.close();
  };

  process.once('SIGINT', () => void shutdown('SIGINT'));
  process.once('SIGTERM', () => void shutdown('SIGTERM'));
}
