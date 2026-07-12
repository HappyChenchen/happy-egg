import http from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';

const ROOM_PATTERN = /^[a-f0-9]{64}$/;
const EVENT_KINDS = new Set(['poke', 'heart', 'celebrate']);
const FRAME_NAMES = new Set([
  'ai_buddy_00', 'ai_buddy_03', 'ai_buddy_04', 'ai_buddy_05', 'ai_buddy_06',
  'ai_buddy_07', 'ai_buddy_08', 'ai_buddy_09', 'ai_buddy_10', 'ai_buddy_11', 'ai_buddy_12'
]);

function send(socket, payload) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload));
}

function validName(name) {
  return typeof name === 'string' && name.trim().length > 0 && name.length <= 32;
}

export function createRelayServer() {
  const rooms = new Map();
  const metadata = new WeakMap();
  const server = http.createServer((request, response) => {
    if (request.url === '/health') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: true }));
      return;
    }
    response.writeHead(404).end();
  });
  const wss = new WebSocketServer({ noServer: true });

  function leave(socket) {
    const meta = metadata.get(socket);
    if (!meta) return;
    const room = rooms.get(meta.room);
    room?.delete(socket);
    if (room?.size === 0) rooms.delete(meta.room);
    metadata.delete(socket);
    for (const peer of room ?? []) send(peer, { type: 'presence', connected: room.size });
  }

  function reject(socket, message) {
    send(socket, { type: 'error', message });
    socket.close(1008, message);
  }

  wss.on('connection', (socket) => {
    socket.on('message', (raw) => {
      let message;
      try { message = JSON.parse(raw.toString()); } catch { return reject(socket, 'invalid JSON'); }

      if (message.type === 'join') {
        if (!ROOM_PATTERN.test(message.room) || !validName(message.name)) return reject(socket, 'invalid join');
        leave(socket);
        const room = rooms.get(message.room) ?? new Set();
        if (room.size >= 2) return reject(socket, 'room is full');
        room.add(socket);
        rooms.set(message.room, room);
        metadata.set(socket, { room: message.room, name: message.name.trim(), sentAt: [] });
        send(socket, { type: 'joined', connected: room.size });
        for (const peer of room) if (peer !== socket) send(peer, { type: 'presence', connected: room.size });
        return;
      }

      const meta = metadata.get(socket);
      if (!meta || message.type !== 'event') return reject(socket, 'join required');
      if (!EVENT_KINDS.has(message.kind) || !FRAME_NAMES.has(message.frameName)) return reject(socket, 'invalid event');
      const now = Date.now();
      meta.sentAt = meta.sentAt.filter((timestamp) => now - timestamp < 60_000);
      if (meta.sentAt.length >= 20) return reject(socket, 'rate limit');
      meta.sentAt.push(now);
      for (const peer of rooms.get(meta.room) ?? []) {
        if (peer !== socket) send(peer, { type: 'event', kind: message.kind, frameName: message.frameName, senderName: meta.name });
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
      for (const room of rooms.values()) for (const socket of room) socket.terminate();
      await new Promise((resolve) => server.close(resolve));
    }
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const relay = createRelayServer();
  await relay.listen(Number(process.env.PORT ?? 8080));
  console.log('MacPet relay listening on port 8080');
}
