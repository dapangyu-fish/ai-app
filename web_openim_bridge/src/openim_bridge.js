import { CbEvents, getSDK } from '@openim/wasm-client-sdk';

let sdk;
let currentUserID = '';
let initialized = false;
const listeners = new Map();
let gzipWasmFallbackInstalled = false;

function operationID(prefix) {
  return `${prefix}_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}

function dataOf(response) {
  if (response && typeof response === 'object' && 'data' in response) {
    return response.data;
  }
  return response;
}

function parseMaybeJson(value) {
  if (typeof value !== 'string') return value;
  if (!value) return null;
  try {
    return JSON.parse(value);
  } catch (_) {
    return value;
  }
}

function normalizeEventPayload(payload) {
  const data = dataOf(payload);
  return parseMaybeJson(data);
}

function emit(name, payload) {
  const callbacks = listeners.get(name);
  if (!callbacks) return;
  const normalized = normalizeEventPayload(payload);
  for (const cb of callbacks) {
    try {
      cb(normalized);
    } catch (error) {
      console.error('[MyAppOpenIM] listener error', name, error);
    }
  }
}

function ensureSDK() {
  if (!sdk) {
    throw new Error('OpenIM bridge is not initialized');
  }
  return sdk;
}

function installGzipWasmFallback() {
  if (gzipWasmFallbackInstalled) return;
  gzipWasmFallbackInstalled = true;
  if (typeof WebAssembly === 'undefined' || typeof WebAssembly.instantiateStreaming !== 'function') {
    return;
  }

  const originalInstantiateStreaming = WebAssembly.instantiateStreaming.bind(WebAssembly);
  WebAssembly.instantiateStreaming = async (source, importObject) => {
    const response = await Promise.resolve(source);
    if (!(response instanceof Response)) {
      return originalInstantiateStreaming(source, importObject);
    }

    const bytes = new Uint8Array(await response.arrayBuffer());
    const isGzip = bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b;
    const wasmBytes = isGzip
      ? await new Response(
          new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip')),
        ).arrayBuffer()
      : bytes.buffer;
    return WebAssembly.instantiate(wasmBytes, importObject);
  };
}

async function waitForWindowFunction(name, timeoutMs = 8000) {
  const startedAt = Date.now();
  while (typeof window[name] !== 'function') {
    if (Date.now() - startedAt > timeoutMs) {
      throw new Error(`OpenIM WASM did not expose window.${name}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

function bindSDKEvents() {
  const im = ensureSDK();

  im.on(CbEvents.OnConnecting, () => emit('connecting', null));
  im.on(CbEvents.OnConnectSuccess, () => emit('connectSuccess', null));
  im.on(CbEvents.OnConnectFailed, (event) => emit('connectFailed', event));
  im.on(CbEvents.OnUserTokenExpired, () => emit('tokenExpired', null));
  im.on(CbEvents.OnUserTokenInvalid, () => emit('tokenInvalid', null));
  im.on(CbEvents.OnKickedOffline, () => emit('kickedOffline', null));

  im.on(CbEvents.OnRecvNewMessages, (event) => emit('newMessages', event));
  im.on(CbEvents.OnRecvNewMessage, (event) => emit('newMessages', [normalizeEventPayload(event)]));
  im.on(CbEvents.OnConversationChanged, (event) => emit('conversationChanged', event));
  im.on(CbEvents.OnNewConversation, (event) => emit('conversationChanged', event));
  im.on(CbEvents.OnTotalUnreadMessageCountChanged, (event) => emit('unreadChanged', event));

  im.on(CbEvents.OnFriendApplicationAdded, (event) => emit('friendshipChanged', event));
  im.on(CbEvents.OnFriendApplicationAccepted, (event) => emit('friendshipChanged', event));
  im.on(CbEvents.OnFriendApplicationRejected, (event) => emit('friendshipChanged', event));
  im.on(CbEvents.OnFriendAdded, (event) => emit('friendshipChanged', event));
  im.on(CbEvents.OnFriendDeleted, (event) => emit('friendshipChanged', event));
  im.on(CbEvents.OnFriendInfoChanged, (event) => emit('friendshipChanged', event));
}

async function refreshUnread() {
  try {
    const total = dataOf(await ensureSDK().getTotalUnreadMsgCount(operationID('unread')));
    emit('unreadChanged', Number(total || 0));
    return Number(total || 0);
  } catch (error) {
    console.warn('[MyAppOpenIM] refreshUnread failed', error);
    return 0;
  }
}

function receiverFromConversation(params) {
  const conversationType = Number(params.conversationType || 1);
  if (conversationType === 3) {
    return { recvID: '', groupID: params.groupID || params.userID || '' };
  }
  return { recvID: params.userID || params.recvID || '', groupID: '' };
}

window.MyAppOpenIM = {
  init(config = {}) {
    if (initialized) return true;
    installGzipWasmFallback();
    sdk = getSDK({
      coreWasmPath: config.coreWasmPath || '/openIM.wasm',
      sqlWasmPath: config.sqlWasmPath || '/sql-wasm.wasm',
      debug: Boolean(config.debug),
    });
    bindSDKEvents();
    initialized = true;
    return true;
  },

  on(name, callback) {
    if (!listeners.has(name)) listeners.set(name, new Set());
    listeners.get(name).add(callback);
    return true;
  },

  off(name, callback) {
    listeners.get(name)?.delete(callback);
    return true;
  },

  async login(params) {
    const im = ensureSDK();
    currentUserID = params.userID || '';
    await im.wasmInitializedPromise;
    await waitForWindowFunction('commonEventFunc');
    const result = await im.login({
      userID: params.userID,
      token: params.token,
      platformID: Number(params.platformID || 5),
      apiAddr: params.apiAddr,
      wsAddr: params.wsAddr,
      isLogStandardOutput: Boolean(params.debug),
      tryParse: true,
    }, operationID('login'));
    await refreshUnread();
    return dataOf(result) ?? true;
  },

  async logout() {
    const result = await ensureSDK().logout(operationID('logout'));
    currentUserID = '';
    emit('unreadChanged', 0);
    return dataOf(result) ?? true;
  },

  async getLoginStatus() {
    return dataOf(await ensureSDK().getLoginStatus(operationID('status')));
  },

  getLoginUserID() {
    return currentUserID;
  },

  async getAllConversationList() {
    return dataOf(await ensureSDK().getAllConversationList(operationID('conversations'))) || [];
  },

  async getTotalUnreadMsgCount() {
    return refreshUnread();
  },

  async markConversationMessageAsRead(conversationID) {
    const result = await ensureSDK().markConversationMessageAsRead(conversationID, operationID('read'));
    await refreshUnread();
    return dataOf(result) ?? true;
  },

  async getAdvancedHistoryMessageList(params) {
    const result = dataOf(await ensureSDK().getAdvancedHistoryMessageList({
      conversationID: params.conversationID,
      startClientMsgID: params.startClientMsgID || '',
      count: Number(params.count || 30),
      viewType: Number(params.viewType || 0),
    }, operationID('history')));
    return result?.messageList || [];
  },

  async sendTextMessage(params) {
    const im = ensureSDK();
    const message = dataOf(await im.createTextMessage(params.text || '', operationID('createText')));
    const receiver = receiverFromConversation(params);
    const sent = dataOf(await im.sendMessage({
      message,
      recvID: receiver.recvID,
      groupID: receiver.groupID,
      offlinePushInfo: params.offlinePushInfo || {
        title: params.title || '',
        desc: params.text || '',
        ex: '',
        iOSPushSound: '+1',
        iOSBadgeCount: true,
      },
    }, operationID('sendText')));
    await refreshUnread();
    return sent;
  },

  async getFriendList() {
    return dataOf(await ensureSDK().getFriendList(false, operationID('friends'))) || [];
  },

  async getFriendApplicationListAsRecipient() {
    return dataOf(await ensureSDK().getFriendApplicationListAsRecipient({
      handleResults: [0],
      offset: 0,
      count: 100,
    }, operationID('friendApps'))) || [];
  },

  async addFriend(params) {
    return dataOf(await ensureSDK().addFriend({
      toUserID: params.toUserID,
      reqMsg: params.reqMsg || '',
    }, operationID('addFriend'))) ?? true;
  },

  async acceptFriendApplication(params) {
    return dataOf(await ensureSDK().acceptFriendApplication({
      toUserID: params.toUserID,
      handleMsg: params.handleMsg || '',
    }, operationID('acceptFriend'))) ?? true;
  },

  async refuseFriendApplication(params) {
    return dataOf(await ensureSDK().refuseFriendApplication({
      toUserID: params.toUserID,
      handleMsg: params.handleMsg || '',
    }, operationID('refuseFriend'))) ?? true;
  },

  async searchFriends(keyword) {
    return dataOf(await ensureSDK().searchFriends({
      keywordList: [keyword],
      isSearchUserID: true,
      isSearchNickname: true,
      isSearchRemark: true,
    }, operationID('searchFriends'))) || [];
  },
};
