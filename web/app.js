const RELAY_URL = new URLSearchParams(window.location.search).get('relay') || 'wss://happypuppy.io/ws';
const ROOM_PATTERN = /^(?:[a-hj-km-np-z2-9]{8}|[a-f0-9]{64})$/i;
const FRAME_NAMES = new Set([
  'ai_buddy_00', 'ai_buddy_03', 'ai_buddy_04', 'ai_buddy_05', 'ai_buddy_06',
  'ai_buddy_07', 'ai_buddy_08', 'ai_buddy_09', 'ai_buddy_10', 'ai_buddy_11'
]);
const FRAME_BY_KIND = { poke: 'ai_buddy_07', heart: 'ai_buddy_10', celebrate: 'ai_buddy_11' };

const $ = (id) => document.getElementById(id);
const pairingCode = $('pairing-code');
const webName = $('web-name');
const connectButton = $('connect-button');
const disconnectButton = $('disconnect-button');
const connectionPill = $('connection-pill');
const connectionLabel = $('connection-label');
const petImage = $('pet-image');
const petName = $('pet-name');
const petMessage = $('pet-message');
const petStatusDot = $('pet-status-dot');
const petCode = $('pet-code');
const actionHint = $('action-hint');
const eventLog = $('event-log');
const actionButtons = [...document.querySelectorAll('.action-button')];

let socket = null;
let connected = false;
let remoteName = '';
const peerID = getPeerID();

$('relay-label').textContent = RELAY_URL;
connectButton.addEventListener('click', connect);
disconnectButton.addEventListener('click', disconnect);
pairingCode.addEventListener('keydown', (event) => { if (event.key === 'Enter') connect(); });
actionButtons.forEach((button) => button.addEventListener('click', () => sendAction(button.dataset.kind)));

function getPeerID() {
  const key = 'macpet-web-peer-id';
  const saved = localStorage.getItem(key);
  if (saved && /^[a-f0-9]{32}$/.test(saved)) return saved;
  const next = crypto.randomUUID().replaceAll('-', '').toLowerCase();
  localStorage.setItem(key, next);
  return next;
}

function connect() {
  const code = pairingCode.value.trim().toLowerCase();
  if (!ROOM_PATTERN.test(code)) return showMessage('配对码需要是 8 位短码，请检查输入。', 'error');
  if (socket) socket.close();
  setConnection('connecting', '连接中');
  setMessage('正在寻找 MacPet…');
  petCode.textContent = code;
  socket = new WebSocket(RELAY_URL);
  socket.addEventListener('open', () => {
    socket.send(JSON.stringify({ type: 'join', room: code, name: cleanName(webName.value), peerID }));
    showMessage('配对码已发送，等待宠物回应。');
  });
  socket.addEventListener('message', (event) => handleMessage(JSON.parse(event.data)));
  socket.addEventListener('error', () => showMessage('连接失败，请确认 relay 地址和配对码。', 'error'));
  socket.addEventListener('close', () => {
    socket = null;
    setConnection('idle', '未连接');
    setActionsEnabled(false);
  });
}

function disconnect() {
  socket?.close();
  socket = null;
  connected = false;
  remoteName = '';
  setConnection('idle', '未连接');
  setActionsEnabled(false);
  petName.textContent = '还没有连接';
  petCode.textContent = '等待配对';
  setMessage('输入配对码，让网页和 MacPet 打个招呼。');
}

function handleMessage(message) {
  if (message.type === 'error') {
    setConnection('idle', '连接失败');
    setActionsEnabled(false);
    showMessage(message.message || '配对失败。', 'error');
    return;
  }
  if (message.type === 'joined') {
    if (message.peerName) becomeOnline(message.peerName);
    else showMessage('已进入房间，等待 MacPet 加入。');
    return;
  }
  if (message.type === 'presence') {
    if (Number(message.connected) >= 2 && message.peerName) becomeOnline(message.peerName);
    else {
      connected = false;
      setConnection('connecting', '等待宠物');
      setActionsEnabled(false);
      setMessage('网页已连接，等待 MacPet 上线。');
    }
    return;
  }
  if (message.type === 'profile' && message.peerName) {
    remoteName = message.peerName;
    petName.textContent = remoteName;
    setMessage('宠物名字已更新。');
    return;
  }
  if (message.type === 'event') {
    const name = message.senderName || remoteName || '宠物';
    const frame = FRAME_NAMES.has(message.frameName) ? message.frameName : 'ai_buddy_05';
    petImage.src = `../Sources/MacPet/Resources/${frame}.png`;
    petImage.animate([{ transform: 'translateY(0) scale(1)' }, { transform: 'translateY(-8px) scale(1.04)' }, { transform: 'translateY(0) scale(1)' }], { duration: 480, easing: 'cubic-bezier(.2,.8,.2,1)' });
    setMessage(`${name}${incomingText(message.kind)}`);
    eventLog.textContent = `${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })} · 收到 ${message.kind}`;
  }
}

function becomeOnline(name) {
  connected = true;
  remoteName = name;
  petName.textContent = name;
  setConnection('online', '在线');
  setActionsEnabled(true);
  setMessage('连接成功，可以从网页和宠物互动。');
  actionHint.textContent = `正在连接 ${name}`;
}

function sendAction(kind) {
  if (!socket || socket.readyState !== WebSocket.OPEN || !connected) return;
  const frameName = FRAME_BY_KIND[kind] || FRAME_BY_KIND.poke;
  socket.send(JSON.stringify({ type: 'event', kind, frameName }));
  petImage.src = `../Sources/MacPet/Resources/${frameName}.png`;
  setMessage(outgoingText(kind));
  eventLog.textContent = `${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })} · 已发送 ${kind}`;
}

function cleanName(value) { return (value || '网页宠物').trim().slice(0, 20) || '网页宠物'; }
function incomingText(kind) { return ({ poke: '拍了拍你', heart: '送来一颗爱心', celebrate: '邀请你一起庆祝' }[kind] || '和你互动了'); }
function outgoingText(kind) { return ({ poke: '网页端拍了一拍', heart: '网页端送出一颗爱心', celebrate: '网页端发起庆祝' }[kind] || '网页端发送了互动'); }
function showMessage(text, type = '') { petMessage.textContent = text; petMessage.dataset.type = type; }
function setMessage(text, type = '') { showMessage(text, type); }
function setConnection(state, label) { connectionPill.dataset.state = state; connectionLabel.textContent = label; }
function setActionsEnabled(enabled) { actionButtons.forEach((button) => { button.disabled = !enabled; }); disconnectButton.disabled = !socket; }
