const RELAY_URL = new URLSearchParams(window.location.search).get('relay') || 'wss://happypuppy.io/ws';
const PET_CODE_PATTERN = /^\d{6}$/;
const FRAME_NAMES = new Set([
  'ai_buddy_00', 'ai_buddy_03', 'ai_buddy_04', 'ai_buddy_05', 'ai_buddy_06',
  'ai_buddy_07', 'ai_buddy_08', 'ai_buddy_09', 'ai_buddy_10', 'ai_buddy_11'
]);
const FRAME_BY_KIND = { poke: 'ai_buddy_07', heart: 'ai_buddy_10', celebrate: 'ai_buddy_11' };
const MAX_MESSAGE_LENGTH = 300;
const STICKERS = [
  ['sticker_wave', '👋'], ['sticker_love', '❤️'], ['sticker_laugh', '😂'], ['sticker_cry', '😭'], ['sticker_thumbsup', '👍'],
  ['sticker_party', '🎉'], ['sticker_gift', '🎁'], ['sticker_coffee', '☕'], ['sticker_moon', '🌙'], ['sticker_flower', '🌸']
];
const STICKER_GLYPHS = Object.fromEntries(STICKERS);
const STORAGE = {
  peerID: 'macpet-web-peer-id',
  authToken: 'macpet-web-auth-token',
  petCode: 'macpet-web-pet-code',
  name: 'macpet-web-name',
  friends: 'macpet-web-friends',
  selectedFriend: 'macpet-web-selected-friend',
  messages: 'macpet-web-messages'
};

const $ = (id) => document.getElementById(id);
const pairingCode = $('pairing-code');
const webName = $('web-name');
const connectButton = $('connect-button');
const disconnectButton = $('disconnect-button');
const removeFriendButton = $('remove-friend-button');
const copyCodeButton = $('copy-code-button');
const resetCodeButton = $('reset-code-button');
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
const requestBox = $('friend-request');
const requestName = $('request-name');
const acceptRequestButton = $('accept-request-button');
const rejectRequestButton = $('reject-request-button');
const scaleOptions = [...document.querySelectorAll('.scale-option')];
const actionButtons = [...document.querySelectorAll('.menu-action')];
const messageInput = $('message-input');
const sendMessageButton = $('send-message-button');
const stickerRow = $('sticker-row');
const messageHistory = $('message-history');
const stickerButtons = STICKERS.map(([id, glyph]) => {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'sticker-button';
  button.textContent = glyph;
  button.title = id;
  button.disabled = true;
  button.addEventListener('click', () => sendSticker(id));
  stickerRow.appendChild(button);
  return button;
});

const peerID = stableHex(STORAGE.peerID, 32);
const authToken = stableHex(STORAGE.authToken, 64);
let friends = loadFriends();
let messages = loadMessages();
let selectedFriendID = localStorage.getItem(STORAGE.selectedFriend) || friends[0]?.peerID || null;
let ownPetCode = localStorage.getItem(STORAGE.petCode) || null;
let socket = null;
let reconnectTimer = null;
let reconnectAttempt = 0;
let intentionallyOffline = false;
let onlinePeerIDs = new Set();
let pendingRequests = [];
let pendingRemovalPeerID = null;

webName.value = cleanName(localStorage.getItem(STORAGE.name) || webName.value);
connectButton.addEventListener('click', sendFriendRequest);
disconnectButton.addEventListener('click', toggleConnection);
removeFriendButton.addEventListener('click', removeSelectedFriend);
copyCodeButton.addEventListener('click', copyPetCode);
resetCodeButton.addEventListener('click', resetPetCode);
petCode.addEventListener('click', copyPetCode);
acceptRequestButton.addEventListener('click', () => respondToCurrentRequest(true));
rejectRequestButton.addEventListener('click', () => respondToCurrentRequest(false));
menuButton.addEventListener('click', (event) => { event.stopPropagation(); toggleMenu(); });
petCard.addEventListener('contextmenu', (event) => { event.preventDefault(); openMenu(); });
document.addEventListener('click', (event) => {
  if (!operationMenu.contains(event.target) && event.target !== menuButton) closeMenu();
});
pairingCode.addEventListener('keydown', (event) => { if (event.key === 'Enter') sendFriendRequest(); });
pairingCode.addEventListener('input', () => {
  pairingCode.value = pairingCode.value.replace(/\D/g, '').slice(0, 6);
});
webName.addEventListener('change', updateProfile);
hideButton.addEventListener('click', togglePetVisibility);
scaleOptions.forEach((option) => option.addEventListener('click', () => setPetScale(option.dataset.scale)));
actionButtons.forEach((button) => button.addEventListener('click', () => sendAction(button.dataset.kind)));
sendMessageButton.addEventListener('click', sendTextMessage);
messageInput.addEventListener('keydown', (event) => { if (event.key === 'Enter') sendTextMessage(); });

renderPetCode();
renderFriend();
renderMessageHistory();
connectRelay();

function stableHex(key, length) {
  const saved = localStorage.getItem(key);
  if (saved && new RegExp(`^[a-f0-9]{${length}}$`).test(saved)) return saved;
  let next = '';
  while (next.length < length) next += crypto.randomUUID().replaceAll('-', '').toLowerCase();
  next = next.slice(0, length);
  localStorage.setItem(key, next);
  return next;
}

function loadFriends() {
  try {
    const parsed = JSON.parse(localStorage.getItem(STORAGE.friends) || '[]');
    return Array.isArray(parsed)
      ? parsed.filter((friend) => /^[a-f0-9]{32}$/.test(friend?.peerID) && typeof friend?.name === 'string')
      : [];
  } catch { return []; }
}

function saveFriends() {
  localStorage.setItem(STORAGE.friends, JSON.stringify(friends));
  if (selectedFriendID) localStorage.setItem(STORAGE.selectedFriend, selectedFriendID);
  else localStorage.removeItem(STORAGE.selectedFriend);
}

function loadMessages() {
  try {
    const parsed = JSON.parse(localStorage.getItem(STORAGE.messages) || '[]');
    return normalizeMessages(parsed);
  } catch { return []; }
}

function normalizeMessageRecord(message) {
  const id = typeof message?.id === 'string' ? message.id.toLowerCase() : '';
  const senderPeerID = typeof message?.senderPeerID === 'string' ? message.senderPeerID.toLowerCase() : '';
  const kind = message?.kind;
  const body = typeof message?.body === 'string' ? message.body.trim() : '';
  const validBody = kind === 'text'
    ? body.length > 0 && Array.from(body).length <= MAX_MESSAGE_LENGTH
    : kind === 'sticker' && Object.hasOwn(STICKER_GLYPHS, body);
  if (!/^[a-f0-9]{32}$/.test(id) || !/^[a-f0-9]{32}$/.test(senderPeerID) || !validBody) return null;
  const rawSenderName = typeof message?.senderName === 'string' ? message.senderName : '';
  return {
    id,
    senderPeerID,
    senderName: rawSenderName.trim().slice(0, 20) || '好友',
    kind,
    body,
    createdAt: Number.isFinite(message?.createdAt) ? message.createdAt : Date.now()
  };
}

function normalizeMessages(value) {
  if (!Array.isArray(value)) return [];
  const byID = new Map();
  value.forEach((candidate) => {
    const record = normalizeMessageRecord(candidate);
    if (!record) return;
    byID.delete(record.id);
    byID.set(record.id, record);
  });
  return [...byID.values()].slice(-50);
}

function persistIncomingMessage(message, sender) {
  const record = normalizeMessageRecord({
    id: message.messageID,
    senderPeerID: message.senderPeerID,
    senderName: sender?.name || message.senderName || '好友',
    kind: message.kind,
    body: message.body,
    createdAt: message.createdAt
  });
  if (!record) return false;
  const stored = loadMessages();
  const next = normalizeMessages([...messages, ...stored, record]);
  try {
    localStorage.setItem(STORAGE.messages, JSON.stringify(next));
  } catch {
    return false;
  }
  messages = next;
  renderMessageHistory();
  return true;
}

function selectedFriend() {
  return friends.find((friend) => friend.peerID === selectedFriendID) || friends[0] || null;
}

function connectRelay() {
  clearTimeout(reconnectTimer);
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  intentionallyOffline = false;
  setConnection('connecting', '连接中');
  socket = new WebSocket(RELAY_URL);
  socket.addEventListener('open', () => {
    reconnectAttempt = 0;
    registerPresence();
  });
  socket.addEventListener('message', (event) => {
    try { handleMessage(JSON.parse(event.data)); }
    catch { setMessage('收到无法识别的消息', 'error'); }
  });
  socket.addEventListener('error', () => setMessage('连接不稳定，正在重试', 'error'));
  socket.addEventListener('close', () => {
    socket = null;
    onlinePeerIDs = new Set();
    pendingRemovalPeerID = null;
    setActionsEnabled(false);
    setMessagingEnabled(false);
    if (intentionallyOffline) {
      setConnection('idle', '已断开');
      setMessage('已断开连接');
      renderFriend();
      return;
    }
    setConnection('connecting', '重连中');
    setMessage('正在重新连接…');
    scheduleReconnect();
  });
  disconnectButton.textContent = '断开连接';
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  const delay = Math.min(8000, 500 * (2 ** reconnectAttempt));
  reconnectAttempt += 1;
  reconnectTimer = setTimeout(connectRelay, delay);
}

function registerPresence() {
  if (!send({
    type: 'presence-register',
    peerID,
    authToken,
    name: cleanName(webName.value),
    friendPeerIDs: friends.map((friend) => friend.peerID)
  })) return;
  localStorage.setItem(STORAGE.name, cleanName(webName.value));
  setConnection('connecting', '同步中');
}

function sendFriendRequest() {
  const code = pairingCode.value.trim();
  if (!PET_CODE_PATTERN.test(code)) return showMessage('请输入 6 位宠物号', 'error');
  if (code === ownPetCode) return showMessage('不能添加自己的宠物', 'error');
  if (!send({ type: 'friend-request-create', petCode: code })) {
    showMessage('尚未连接，正在重试', 'error');
    connectRelay();
    return;
  }
  showMessage('好友申请已发送');
  pairingCode.value = '';
}

function handleMessage(message) {
  if (message.type === 'pet-code' && PET_CODE_PATTERN.test(message.petCode)) {
    ownPetCode = message.petCode;
    localStorage.setItem(STORAGE.petCode, ownPetCode);
    renderPetCode();
    return;
  }
  if (message.type === 'presence-snapshot') {
    onlinePeerIDs = new Set(message.onlinePeerIDs || []);
    setConnection('idle', selectedFriend() ? '好友离线' : '已连接');
    renderFriend();
    return;
  }
  if (message.type === 'friend-presence') {
    if (message.online) onlinePeerIDs.add(message.peerID);
    else onlinePeerIDs.delete(message.peerID);
    renderFriend();
    return;
  }
  if (message.type === 'friend-profile') {
    const friend = friends.find((item) => item.peerID === message.peerID);
    if (!friend || !message.name || friend.name === message.name) return;
    const oldName = friend.name;
    friend.name = message.name;
    saveFriends();
    renderFriend();
    showMessage(`${oldName} 改名为 ${message.name}`);
    return;
  }
  if (message.type === 'friend-request-created') {
    showMessage(`已向${message.targetName ? ` ${message.targetName}` : '对方'}发送申请`);
    return;
  }
  if (message.type === 'friend-request-incoming') {
    if (!pendingRequests.some((request) => request.requestID === message.requestID)) pendingRequests.push(message);
    renderRequest();
    openMenu();
    showMessage(`${message.senderName || '新朋友'}想添加你`);
    return;
  }
  if (message.type === 'friend-request-accepted') {
    addFriend({ peerID: message.peerID, name: message.name || '好友' });
    pendingRequests = pendingRequests.filter((request) => request.requestID !== message.requestID);
    send({ type: 'friend-request-ack', requestID: message.requestID });
    registerPresence();
    renderRequest();
    showMessage(`已和 ${message.name || '新朋友'} 成为好友`);
    return;
  }
  if (message.type === 'friend-request-rejected') {
    pendingRequests = pendingRequests.filter((request) => request.requestID !== message.requestID);
    send({ type: 'friend-request-ack', requestID: message.requestID });
    renderRequest();
    showMessage('对方拒绝了好友申请');
    return;
  }
  if (message.type === 'friend-request-failed') {
    showMessage(friendRequestError(message.message), 'error');
    return;
  }
  if (message.type === 'friend-removed' && typeof message.peerID === 'string') {
    finishFriendRemoval(message.peerID.toLowerCase());
    return;
  }
  if (message.type === 'friend-remove-failed') {
    pendingRemovalPeerID = null;
    renderFriend();
    showMessage('删除好友失败，请联网后重试', 'error');
    return;
  }
  if (message.type === 'friend-event') {
    const sender = friends.find((friend) => friend.peerID === message.senderPeerID);
    if (sender) {
      selectedFriendID = sender.peerID;
      saveFriends();
    }
    const frame = FRAME_NAMES.has(message.frameName) ? message.frameName : 'ai_buddy_05';
    petImage.src = `../Sources/MacPet/Resources/${frame}.png`;
    petImage.animate([{ opacity: 0.72 }, { opacity: 1 }], { duration: 280, easing: 'ease-out' });
    renderFriend();
    setMessage(`${message.senderName || sender?.name || '宠物'}${incomingText(message.kind)}`);
    return;
  }
  if (message.type === 'friend-event-delivered') {
    setMessage('对方收到了');
    return;
  }
  if (message.type === 'friend-event-rejected') {
    onlinePeerIDs.delete(message.targetPeerID);
    renderFriend();
    setMessage('对方暂时收不到', 'error');
    return;
  }
  if (message.type === 'friend-message-incoming') {
    const sender = friends.find((friend) => friend.peerID === message.senderPeerID);
    if (sender) { selectedFriendID = sender.peerID; saveFriends(); }
    if (!persistIncomingMessage(message, sender)) {
      showMessage('留言保存失败，稍后会重试', 'error');
      return;
    }
    send({ type: 'friend-message-ack', messageID: message.messageID });
    renderFriend();
    setMessage(messagePreview(message, sender));
    return;
  }
  if (message.type === 'friend-message-sent') {
    setMessage('留言已发送');
    return;
  }
  if (message.type === 'friend-message-failed') {
    showMessage(messageError(message.message), 'error');
    return;
  }
  if (message.type === 'error') showMessage(message.message || '连接失败', 'error');
}

function addFriend(friend) {
  friends = friends.filter((item) => item.peerID !== friend.peerID);
  friends.push(friend);
  selectedFriendID = friend.peerID;
  saveFriends();
  renderFriend();
}

function respondToCurrentRequest(accept) {
  const request = pendingRequests[0];
  if (!request || !send({ type: 'friend-request-respond', requestID: request.requestID, accept })) return;
  pendingRequests.shift();
  renderRequest();
  showMessage(accept ? '已接受好友申请' : '已拒绝好友申请');
}

function removeSelectedFriend() {
  const friend = selectedFriend();
  if (!friend || !window.confirm(`删除好友 ${friend.name}？`)) return;
  if (!send({ type: 'friend-remove', targetPeerID: friend.peerID })) {
    showMessage('删除好友失败，请联网后重试', 'error');
    connectRelay();
    return;
  }
  pendingRemovalPeerID = friend.peerID;
  renderFriend();
  showMessage('正在删除好友…');
}

function finishFriendRemoval(peerID) {
  const removed = friends.find((friend) => friend.peerID === peerID);
  friends = friends.filter((item) => item.peerID !== peerID);
  onlinePeerIDs.delete(peerID);
  selectedFriendID = friends[0]?.peerID || null;
  if (pendingRemovalPeerID === peerID) pendingRemovalPeerID = null;
  saveFriends();
  renderFriend();
  closeMenu();
  showMessage(removed ? `已删除好友 ${removed.name}` : '好友关系已解除');
}

function resetPetCode() {
  if (!window.confirm('更换宠物号？旧号码会立即失效，已有好友不会受影响。')) return;
  if (send({ type: 'pet-code-reset' })) showMessage('正在更换宠物号');
}

async function copyPetCode() {
  if (!ownPetCode) return;
  await navigator.clipboard.writeText(ownPetCode);
  showMessage('宠物号已复制');
}

function updateProfile() {
  webName.value = cleanName(webName.value);
  localStorage.setItem(STORAGE.name, webName.value);
  registerPresence();
}

function sendAction(kind) {
  const friend = selectedFriend();
  if (!friend || !onlinePeerIDs.has(friend.peerID)) return;
  const frameName = FRAME_BY_KIND[kind] || FRAME_BY_KIND.poke;
  const sent = send({
    type: 'friend-event',
    targetPeerID: friend.peerID,
    eventID: crypto.randomUUID().replaceAll('-', '').toLowerCase(),
    kind,
    frameName
  });
  if (!sent) return;
  petImage.src = `../Sources/MacPet/Resources/${frameName}.png`;
  setMessage(outgoingText(kind));
  closeMenu();
}

function sendTextMessage() {
  const friend = selectedFriend();
  if (!friend) return;
  const body = Array.from(messageInput.value.trim()).slice(0, MAX_MESSAGE_LENGTH).join('');
  if (!body) return showMessage('留言不能为空', 'error');
  if (!sendFriendMessage(friend.peerID, 'text', body)) {
    showMessage('尚未连接，正在重试', 'error');
    connectRelay();
    return;
  }
  messageInput.value = '';
  setMessage(`已给 ${friend.name} 留言`);
}

function sendSticker(id) {
  const friend = selectedFriend();
  if (!friend) return;
  if (!sendFriendMessage(friend.peerID, 'sticker', id)) {
    showMessage('尚未连接，正在重试', 'error');
    connectRelay();
    return;
  }
  setMessage(`已发送 ${STICKER_GLYPHS[id] || '贴纸'}`);
  closeMenu();
}

function sendFriendMessage(peerID, kind, body) {
  return send({
    type: 'friend-message-send',
    messageID: crypto.randomUUID().replaceAll('-', '').toLowerCase(),
    targetPeerID: peerID,
    kind,
    body
  });
}

function send(payload) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return false;
  socket.send(JSON.stringify(payload));
  return true;
}

function toggleConnection() {
  if (socket || reconnectTimer) {
    intentionallyOffline = true;
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    socket?.close();
    socket = null;
    onlinePeerIDs = new Set();
    disconnectButton.textContent = '重新连接';
    renderFriend();
  } else {
    connectRelay();
  }
}

function renderPetCode() {
  const text = ownPetCode || '获取中…';
  petCode.textContent = ownPetCode ? `我的宠物号 ${text}` : '宠物号获取中…';
  copyCodeButton.textContent = text;
  copyCodeButton.disabled = !ownPetCode;
  resetCodeButton.disabled = !ownPetCode;
}

function renderFriend() {
  const friend = selectedFriend();
  const online = Boolean(friend && onlinePeerIDs.has(friend.peerID) && socket?.readyState === WebSocket.OPEN);
  petName.textContent = friend?.name || '还没有好友';
  menuPetName.textContent = friend?.name || '还没有好友';
  removeFriendButton.disabled = !friend || pendingRemovalPeerID === friend.peerID;
  setActionsEnabled(online);
  setMessagingEnabled(Boolean(friend) && socket?.readyState === WebSocket.OPEN);
  if (online) {
    setConnection('online', '在线');
    if (!petMessage.textContent || petMessage.textContent.includes('连接') || petMessage.textContent === '好友暂时不在线') {
      setMessage('可以互动了');
    }
  } else if (socket?.readyState === WebSocket.OPEN) {
    setConnection('idle', friend ? '好友离线' : '已连接');
    if (!friend) setMessage('输入朋友的宠物号');
    else if (!petMessage.textContent.includes('申请')) setMessage('好友暂时不在线');
  }
}

function renderRequest() {
  const request = pendingRequests[0];
  requestBox.hidden = !request;
  requestName.textContent = request ? `${request.senderName || '新朋友'} 想添加你` : '';
}

function renderMessageHistory() {
  messageHistory.replaceChildren();
  if (messages.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'message-history-empty';
    empty.textContent = '还没有收到留言';
    messageHistory.appendChild(empty);
    return;
  }
  [...messages].reverse().slice(0, 10).forEach((message) => {
    const item = document.createElement('div');
    item.className = 'message-history-item';
    const sender = document.createElement('strong');
    sender.textContent = message.senderName;
    const body = document.createElement('span');
    body.textContent = message.kind === 'sticker'
      ? `${STICKER_GLYPHS[message.body] || '🎁'} 贴纸`
      : message.body;
    item.append(sender, body);
    messageHistory.appendChild(item);
  });
}

function cleanName(value) { return (value || '网页宠物').trim().slice(0, 20) || '网页宠物'; }
function friendRequestError(message) {
  return ({ 'pet code not found': '没有找到这个宠物号', 'cannot add yourself': '不能添加自己的宠物' }[message] || '好友申请失败，请重试');
}
function incomingText(kind) { return ({ poke: '拍了拍你', heart: '送来一颗爱心', celebrate: '邀请你一起庆祝' }[kind] || '和你互动了'); }
function outgoingText(kind) { return ({ poke: '拍了一拍', heart: '送出一颗爱心', celebrate: '发起庆祝' }[kind] || '发送了互动'); }
function messagePreview(message, sender) {
  const name = message.senderName || sender?.name || '好友';
  if (message.kind === 'sticker') return `${name} 发来 ${STICKER_GLYPHS[message.body] || '🎁'}`;
  return `${name}：${message.body || ''}`;
}
function messageError(message) {
  return ({ 'not friends': '对方不是你的好友', 'rate limit': '留言太频繁，请稍后再试', 'authentication required': '身份未就绪，请稍后重试' }[message] || '留言发送失败，请重试');
}
function showMessage(text, type = '') { petMessage.textContent = text; petMessage.dataset.type = type; }
function setMessage(text, type = '') { showMessage(text, type); }
function setConnection(state, label) {
  connectionPill.dataset.state = state;
  connectionLabel.textContent = label;
  menuState.textContent = label;
  petStatusDot.classList.toggle('online', state === 'online');
}
function setActionsEnabled(enabled) { actionButtons.forEach((button) => { button.disabled = !enabled; }); }
function setMessagingEnabled(enabled) {
  messageInput.disabled = !enabled;
  sendMessageButton.disabled = !enabled;
  stickerButtons.forEach((button) => { button.disabled = !enabled; });
}
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
