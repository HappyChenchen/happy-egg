const RELAY_URL = new URLSearchParams(window.location.search).get('relay') || 'wss://happypuppy.io/ws';
const ROOM_PATTERN = /^(?:\d{4}|[a-hj-km-np-z2-9]{8}|[a-f0-9]{64})$/i;
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
const menuButton = $('menu-button');
const operationMenu = $('operation-menu');
const petCard = $('pet-card');
const menuPetName = $('menu-pet-name');
const menuState = $('menu-state');
const hideButton = $('hide-button');
const scaleOptions = [...document.querySelectorAll('.scale-option')];
const actionButtons = [...document.querySelectorAll('.menu-action')];

let socket = null;
let connected = false;
let remoteName = '';
const peerID = getPeerID();

connectButton.addEventListener('click', connect);
disconnectButton.addEventListener('click', disconnect);
menuButton.addEventListener('click', (event) => { event.stopPropagation(); toggleMenu(); });
petCard.addEventListener('contextmenu', (event) => { event.preventDefault(); openMenu(); });
document.addEventListener('click', (event) => {
  if (!operationMenu.contains(event.target) && event.target !== menuButton) closeMenu();
});
pairingCode.addEventListener('keydown', (event) => { if (event.key === 'Enter') connect(); });
pairingCode.addEventListener('input', () => { petCode.textContent = pairingCode.value.trim().toLowerCase() || '等待配对'; });
hideButton.addEventListener('click', togglePetVisibility);
scaleOptions.forEach((option) => option.addEventListener('click', () => setPetScale(option.dataset.scale)));
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
  if (!ROOM_PATTERN.test(code)) return showMessage('请输入 4 位数字配对码', 'error');
  if (socket) socket.close();
  setConnection('connecting', '连接中');
  setMessage('正在寻找宠物…');
  petCode.textContent = code;
  socket = new WebSocket(RELAY_URL);
  socket.addEventListener('open', () => {
    socket.send(JSON.stringify({ type: 'join', room: code, name: cleanName(webName.value), peerID }));
    showMessage('等待宠物回应…');
  });
  socket.addEventListener('message', (event) => handleMessage(JSON.parse(event.data)));
  socket.addEventListener('error', () => showMessage('连接失败，请重试', 'error'));
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
  petName.textContent = '未连接';
  menuPetName.textContent = '未连接';
  petCode.textContent = '等待配对';
  setMessage('打开“操作”输入配对码');
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
    else showMessage('等待宠物上线…');
    return;
  }
  if (message.type === 'presence') {
    if (Number(message.connected) >= 2 && message.peerName) becomeOnline(message.peerName);
    else {
      connected = false;
      setConnection('connecting', '等待宠物');
      setActionsEnabled(false);
      setMessage('等待宠物上线…');
    }
    return;
  }
  if (message.type === 'profile' && message.peerName) {
    remoteName = message.peerName;
    petName.textContent = remoteName;
    setMessage('名字已更新');
    return;
  }
  if (message.type === 'event') {
    const name = message.senderName || remoteName || '宠物';
    const frame = FRAME_NAMES.has(message.frameName) ? message.frameName : 'ai_buddy_05';
    petImage.src = `../Sources/MacPet/Resources/${frame}.png`;
    petImage.animate([{ opacity: 0.72 }, { opacity: 1 }], { duration: 280, easing: 'ease-out' });
    setMessage(`${name}${incomingText(message.kind)}`);
  }
}

function becomeOnline(name) {
  connected = true;
  remoteName = name;
  petName.textContent = name;
  menuPetName.textContent = name;
  setConnection('online', '在线');
  setActionsEnabled(true);
  setMessage('可以互动了');
}

function sendAction(kind) {
  if (!socket || socket.readyState !== WebSocket.OPEN || !connected) return;
  const frameName = FRAME_BY_KIND[kind] || FRAME_BY_KIND.poke;
  socket.send(JSON.stringify({ type: 'event', kind, frameName }));
  petImage.src = `../Sources/MacPet/Resources/${frameName}.png`;
  setMessage(outgoingText(kind));
  closeMenu();
}

function cleanName(value) { return (value || '网页宠物').trim().slice(0, 20) || '网页宠物'; }
function incomingText(kind) { return ({ poke: '拍了拍你', heart: '送来一颗爱心', celebrate: '邀请你一起庆祝' }[kind] || '和你互动了'); }
function outgoingText(kind) { return ({ poke: '网页端拍了一拍', heart: '网页端送出一颗爱心', celebrate: '网页端发起庆祝' }[kind] || '网页端发送了互动'); }
function showMessage(text, type = '') { petMessage.textContent = text; petMessage.dataset.type = type; }
function setMessage(text, type = '') { showMessage(text, type); }
function setConnection(state, label) {
  connectionPill.dataset.state = state;
  connectionLabel.textContent = label;
  menuState.textContent = label;
  const online = state === 'online';
  petStatusDot.classList.toggle('online', online);
}
function setActionsEnabled(enabled) { actionButtons.forEach((button) => { button.disabled = !enabled; }); disconnectButton.disabled = !socket; }

function toggleMenu() { operationMenu.hidden ? openMenu() : closeMenu(); }
function openMenu() { operationMenu.hidden = false; menuButton.setAttribute('aria-expanded', 'true'); }
function closeMenu() { operationMenu.hidden = true; menuButton.setAttribute('aria-expanded', 'false'); }
function togglePetVisibility() {
  const hidden = petCard.classList.toggle('is-hidden');
  hideButton.textContent = hidden ? '显示宠物' : '隐藏宠物';
  closeMenu();
}
function setPetScale(scale) {
  petCard.dataset.scale = scale;
  scaleOptions.forEach((option) => option.classList.toggle('is-selected', option.dataset.scale === scale));
  closeMenu();
}
