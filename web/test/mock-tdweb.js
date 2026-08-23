/* Mock tdweb for flow tests — served in place of /vendor/tdweb/tdweb.js by
 * test/flows.mjs (Playwright route interception). Classic script: defines
 * window.tdweb.default with the same surface the app uses (send → Promise,
 * onUpdate, close). Scenario via ?mock=<fresh|node>&mockflood=1.
 *
 * Never loaded in production; nothing in index.html references it.
 */
(function () {
  const params = new URLSearchParams(location.search);
  const scenario = params.get('mock') || 'node';
  const flood = params.get('mockflood') === '1';
  const slow = params.get('mockslow') === '1' ? 1500 : 10;

  const err = (code, message) => ({ '@type': 'error', code, message });
  const NOW = Math.floor(Date.now() / 1000);
  const CARD = 'tgsocial v1';

  // ── world ────────────────────────────────────────────────────────────────
  const users = { 1: { '@type': 'user', id: 1, first_name: 'Elijah', last_name: 'Lucian', phone_number: '16045550199', usernames: { editable_username: 'elijah', active_usernames: ['elijah'] }, profile_photo: { big: { id: 9001, remote: { unique_id: 'u9001' }, local: {} } } } };
  const chats = {};
  const supergroups = {};
  const fulls = {};
  const pinned = {};
  const history = {};
  let nextMsgId = 500 << 20;
  let chatSeq = 2000;

  function channel({ id, sg, title, username, description, creator = false, admin = false, photo = true }) {
    chats[id] = {
      '@type': 'chat',
      id,
      type: { '@type': 'chatTypeSupergroup', supergroup_id: sg, is_channel: true },
      title,
      photo: photo ? { small: { id: 7000 + sg, remote: { unique_id: `p${sg}` }, local: { is_downloading_completed: false } } } : null,
    };
    supergroups[sg] = {
      '@type': 'supergroup',
      id: sg,
      usernames: username ? { editable_username: username, active_usernames: [username] } : null,
      status: creator ? { '@type': 'chatMemberStatusCreator' } : admin ? { '@type': 'chatMemberStatusAdministrator', rights: { can_post_messages: true } } : { '@type': 'chatMemberStatusLeft' },
      is_channel: true,
      member_count: 120,
    };
    fulls[sg] = { '@type': 'supergroupFullInfo', description: description || '' };
    history[id] = history[id] || [];
  }

  function text(id, chatId, body, date, extra = {}) {
    return {
      '@type': 'message',
      id,
      chat_id: chatId,
      date,
      content: { '@type': 'messageText', text: { '@type': 'formattedText', text: body, entities: extra.entities || [] } },
      interaction_info: extra.ii || null,
      forward_info: extra.fwd || null,
    };
  }

  function pin(chatId, body) {
    const id = nextMsgId;
    nextMsgId += 1 << 20;
    const m = text(id, chatId, body, NOW - 86400 * 30);
    pinned[chatId] = m;
    return m;
  }

  // nodes
  const hasNode = scenario === 'node';
  channel({ id: -1001, sg: 1001, title: 'Elijah Lucian', username: 'tgs_elijah', description: 'tgsocial v1 · Staff product architect.', creator: true });
  if (hasNode) pin(-1001, `${CARD}\nname: Elijah Lucian\nbio: Staff product architect. Software, music, voice.\nlink: https://elijahlucian.ca\npublic: yes\nfeeds: @waveloop_devlog @tresbuchet\nfollows: @tgs_ana @tgs_bob`);
  else {
    // fresh: the channel exists but is not a node (plain pinned message)
    pinned[-1001] = text(nextMsgId, -1001, 'Welcome to my channel', NOW - 1000);
    nextMsgId += 1 << 20;
  }
  channel({ id: -1002, sg: 1002, title: 'WaveLoop devlog', username: 'waveloop_devlog', description: 'Build notes from the bench.\ntgsocial: @tgs_elijah', creator: true });
  channel({ id: -1003, sg: 1003, title: 'Très Buchet', username: 'tresbuchet', description: 'A restaurant, eventually.', admin: true });
  channel({ id: -1004, sg: 1004, title: 'Notes to self', username: null, description: '', creator: true, photo: false });
  channel({ id: -1010, sg: 1010, title: 'Ana Iliovic', username: 'tgs_ana', description: 'tgsocial v1 · Voice, product, Vancouver.' });
  pin(-1010, `${CARD}\nname: Ana Iliovic\nbio: Voice, product, Vancouver.\nlink: anailiovic.com\npublic: yes\nfeeds: @ana_notes @thevii_dev\nfollows: @tgs_bob @tgs_carol @tgs_elijah\nreplies: @tgs_ana_r`);
  channel({ id: -1011, sg: 1011, title: "Ana's notes", username: 'ana_notes', description: 'tgsocial: @tgs_ana' });
  channel({ id: -1012, sg: 1012, title: 'VII devlog', username: 'thevii_dev', description: '' });
  channel({ id: -1013, sg: 1013, title: 'Ana Iliovic replies', username: 'tgs_ana_r', description: 'tgsocial v1 replies · @tgs_ana' });
  channel({ id: -1020, sg: 1020, title: 'Bob', username: 'tgs_bob', description: 'tgsocial v1' });
  pin(-1020, `${CARD}\nname: Bob\npublic: yes\nfeeds: @bob_feed\nfollows: @tgs_carol @tgs_dave\nreplies: @tgs_bob_r`);
  channel({ id: -1021, sg: 1021, title: "Bob's feed", username: 'bob_feed', description: '' });
  channel({ id: -1022, sg: 1022, title: 'Bob replies', username: 'tgs_bob_r', description: 'tgsocial v1 replies · @tgs_bob' });
  channel({ id: -1030, sg: 1030, title: 'Carol', username: 'tgs_carol', description: 'tgsocial v1' });
  pin(-1030, `${CARD}\nname: Carol\npublic: yes\nfollows: @tgs_ana`);
  channel({ id: -1040, sg: 1040, title: 'Dave', username: 'tgs_dave', description: 'tgsocial v1' });
  pin(-1040, `${CARD}\nname: Dave\npublic: no`);
  channel({ id: -1050, sg: 1050, title: 'Zed', username: 'tgs_zed', description: 'tgsocial v1 · prefix search only' });
  pin(-1050, `${CARD}\nname: Zed\npublic: yes\nfeeds: @bob_feed`);
  channel({ id: -1070, sg: 1070, title: 'Future', username: 'tgs_future', description: 'tgsocial v2' });
  pin(-1070, 'tgsocial v2\nname: Future');
  // index group
  chats[-1060] = { '@type': 'chat', id: -1060, type: { '@type': 'chatTypeSupergroup', supergroup_id: 1060, is_channel: false }, title: 'tgsocial index', photo: null };
  supergroups[1060] = { '@type': 'supergroup', id: 1060, usernames: { editable_username: 'tgsocial_index', active_usernames: ['tgsocial_index'] }, status: { '@type': 'chatMemberStatusLeft' }, is_channel: false };
  fulls[1060] = { '@type': 'supergroupFullInfo', description: 'Members post one message: node: @tgs_x' };
  history[-1060] = [
    text(3 << 20, -1060, 'node: @tgs_carol', NOW - 5000),
    text(2 << 20, -1060, 'node: @tgs_dave', NOW - 6000),
    text(1 << 20, -1060, 'node: @tgs_zed', NOW - 7000),
  ];

  // posts
  const feedsToFill = [-1002, -1003, -1011, -1012, -1021];
  let t = NOW - 120;
  let serverId = 400;
  const photo = (seed) => ({
    '@type': 'messagePhoto',
    photo: { sizes: [
      { '@type': 'photoSize', type: 'm', width: 320, height: 240, photo: { id: 8000 + seed, remote: { unique_id: `ph${seed}m` }, local: {} } },
      { '@type': 'photoSize', type: 'x', width: 800, height: 600, photo: { id: 8100 + seed, remote: { unique_id: `ph${seed}x` }, local: {} } },
    ] },
    caption: { '@type': 'formattedText', text: `Photo ${seed} with a link https://lucianlabs.ca`, entities: [{ offset: 19 + String(seed).length, length: 21, type: { '@type': 'textEntityTypeUrl' } }] },
  });
  for (let i = 0; i < 56; i += 1) {
    const chatId = feedsToFill[i % feedsToFill.length];
    const id = serverId << 20;
    serverId -= 1;
    t -= 3600 * (1 + (i % 5));
    const kind = i % 14;
    let m;
    if (kind === 1) m = { ...text(id, chatId, '', t), content: photo(i) };
    else if (kind === 3) m = { ...text(id, chatId, '', t), content: { '@type': 'messageVideo', video: { duration: 94, width: 640, height: 360, supports_streaming: true, mime_type: 'video/mp4', video: { id: 8550 + i, remote: { unique_id: `vf${i}` }, local: {} }, thumbnail: { width: 320, height: 180, file: { id: 8500 + i, remote: { unique_id: `v${i}` }, local: {} } } }, caption: { '@type': 'formattedText', text: 'A short clip', entities: [] } } };
    else if (kind === 5) m = { ...text(id, chatId, '', t), content: { '@type': 'messageDocument', document: { file_name: `release-notes-${i}.pdf`, mime_type: 'application/pdf', document: { id: 8600 + i, remote: { unique_id: `d${i}` }, local: {}, size: 2500000 } }, caption: { '@type': 'formattedText', text: '', entities: [] } } };
    else if (kind === 7) m = { ...text(id, chatId, '', t), content: { '@type': 'messageAudio', audio: { duration: 212, title: 'Bench loop', performer: 'WaveLoop', mime_type: 'audio/mpeg', audio: { id: 8700 + i, remote: { unique_id: `a${i}` }, local: {} } }, caption: { '@type': 'formattedText', text: '', entities: [] } } };
    else if (kind === 8) m = { ...text(id, chatId, 'Pinned a message', t), content: { '@type': 'messagePinMessage', message_id: 1 } };
    else if (kind === 9) m = { ...text(id, chatId, '', t), content: { '@type': 'messageAnimation', animation: { duration: 4, width: 480, height: 270, mime_type: 'video/mp4', file_name: 'loop.mp4', animation: { id: 8800 + i, remote: { unique_id: `an${i}` }, local: {} }, thumbnail: { width: 320, height: 180, file: { id: 8850 + i, remote: { unique_id: `ant${i}` }, local: {} } } }, caption: { '@type': 'formattedText', text: '', entities: [] } } };
    else if (kind === 10) m = { ...text(id, chatId, '', t), content: { '@type': 'messageVoiceNote', voice_note: { duration: 9, waveform: 'kqUqVaqlKlWqpSpVqqUqVQ==', mime_type: 'audio/ogg', voice: { id: 8900 + i, remote: { unique_id: `vo${i}` }, local: {} } } } };
    else if (kind === 11) m = { ...text(id, chatId, '', t), content: { '@type': 'messageVideoNote', video_note: { duration: 12, length: 240, video: { id: 8950 + i, remote: { unique_id: `vn${i}` }, local: {} }, thumbnail: { width: 240, height: 240, file: { id: 8960 + i, remote: { unique_id: `vnt${i}` }, local: {} } } } } };
    else if (kind === 12) m = { ...text(id, chatId, '', t), content: { '@type': 'messageSticker', sticker: { width: 512, height: 512, format: { '@type': 'stickerFormatWebp' }, sticker: { id: 8970 + i, remote: { unique_id: `st${i}` }, local: {} } } } };
    else if (kind === 13) m = { ...text(id, chatId, '', t), content: { '@type': 'messagePoll', poll: { question: { text: 'Which bank?' }, options: [{}, {}, {}] } } };
    else {
      m = text(id, chatId, `Post ${i}: bold words and a mention @tgs_ana and code here. Lorem ipsum dolor sit amet, consectetur adipiscing elit.`, t, {
        entities: [
          { offset: 7 + String(i).length, length: 4, type: { '@type': 'textEntityTypeBold' } },
          { offset: 32 + String(i).length, length: 8, type: { '@type': 'textEntityTypeMention' } },
          { offset: 45 + String(i).length, length: 4, type: { '@type': 'textEntityTypeCode' } },
        ],
        ii: { '@type': 'messageInteractionInfo', view_count: 1200 + i * 37, reactions: { '@type': 'messageReactions', reactions: [{ '@type': 'messageReaction', type: { '@type': 'reactionTypeEmoji', emoji: '❤' }, total_count: 14 }] } },
        fwd: i % 6 === 0 ? { '@type': 'messageForwardInfo', origin: { '@type': 'messageOriginChannel', chat_id: -1011, message_id: 1 } } : null,
      });
    }
    history[chatId].push(m);
  }
  // a two-photo album (media_album_id) and a link-preview post for the viewer
  // paths — newest ids AND newest dates so the channel keeps TDLib's id/date order
  {
    for (const n of [0, 1]) {
      history[-1002].push({ ...text((402 + n) << 20, -1002, '', NOW - 90), content: photo(90 + n), media_album_id: '77' });
    }
    const preview = text(401 << 20, -1002, 'Read the writeup at https://lucianlabs.ca', NOW - 100, { entities: [{ offset: 22, length: 21, type: { '@type': 'textEntityTypeUrl' } }] });
    preview.content.link_preview = {
      url: 'https://lucianlabs.ca',
      site_name: 'Lucian Labs',
      title: 'Lucian Labs',
      description: { text: 'Product architecture from the bench.' },
    };
    history[-1002].push(preview);
  }
  for (const id of feedsToFill) history[id].sort((a, b) => b.id - a.id);

  // comments (PROTOCOL §6): Ana comments on the newest waveloop_devlog post; Bob replies to Ana
  {
    const target = history[-1002][0];
    const link = `https://t.me/waveloop_devlog/${Math.floor(target.id / 1048576)}`;
    history[-1013].push(text(600 << 20, -1013, `re: ${link}\nNice one. The bass is huge.`, NOW - 60));
    history[-1022].push(text(601 << 20, -1022, `re: https://t.me/tgs_ana_r/600\nAgreed.`, NOW - 30));
    // an owner may post anything else in their channel; readers skip it (§6.2)
    history[-1013].push(text(599 << 20, -1013, 'Housekeeping: this channel holds my comments.', NOW - 7000));
    history[-1013].sort((a, b) => b.id - a.id);
  }

  // ── persistence across reloads (sessionStorage) ─────────────────────────
  const WORLD_KEY = `mockWorld:${scenario}`;
  const saved = (() => {
    try {
      return JSON.parse(sessionStorage.getItem(WORLD_KEY) || 'null');
    } catch {
      return null;
    }
  })();
  if (saved) {
    Object.assign(chats, saved.chats);
    Object.assign(supergroups, saved.supergroups);
    Object.assign(fulls, saved.fulls);
    Object.assign(pinned, saved.pinned);
    Object.assign(history, saved.history);
    nextMsgId = saved.nextMsgId;
    chatSeq = saved.chatSeq;
  }
  function persist(auth) {
    try {
      sessionStorage.setItem(WORLD_KEY, JSON.stringify({ chats, supergroups, fulls, pinned, history, nextMsgId, chatSeq, auth }));
    } catch {}
  }

  // ── client ───────────────────────────────────────────────────────────────
  class MockTdClient {
    constructor(options) {
      this.onUpdate = options.onUpdate;
      this.auth = null;
      this.joined = new Set();
      this.floodUsed = false;
      this.ready = saved?.auth === 'ready';
      setTimeout(() => this.setAuth('authorizationStateWaitTdlibParameters'), slow);
      window.__mock = { history, pinned, chats, supergroups, fulls, client: this, persist };
    }

    emit(u) {
      setTimeout(() => this.onUpdate(u), 0);
    }

    setAuth(type, extra = {}) {
      this.auth = { '@type': type, ...extra };
      if (type === 'authorizationStateReady') persist('ready');
      if (type === 'authorizationStateClosed') sessionStorage.removeItem(WORLD_KEY);
      this.emit({ '@type': 'updateAuthorizationState', authorization_state: this.auth });
    }

    close() {}

    send(q) {
      return new Promise((resolve, reject) => {
        setTimeout(() => {
          try {
            const r = this.handle(q);
            if (/^(createNewSupergroupChat|setSupergroupUsername|deleteChat|deleteMessages|sendMessage|pinChatMessage|editMessageText|setChatDescription|joinChat)$/.test(q['@type'])) setTimeout(() => persist(this.auth?.['@type'] === 'authorizationStateReady' ? 'ready' : null), 30);
            resolve(r);
          } catch (e) {
            reject(e['@type'] === 'error' ? e : err(500, String(e.message || e)));
          }
        }, 5);
      });
    }

    paged(chatId, from, limit) {
      const list = history[chatId] || [];
      const start = from ? list.findIndex((m) => m.id === from) + 1 : 0;
      // first call from 0 returns a short page, like TDLib's local-only first pass
      const take = from === 0 ? Math.min(limit, 7) : limit;
      return { '@type': 'messages', total_count: list.length, messages: list.slice(start, start + take) };
    }

    handle(q) {
      const t = q['@type'];
      const ok = { '@type': 'ok' };
      switch (t) {
        case 'setTdlibParameters':
          if (!q.api_id || !q.api_hash) throw err(400, 'api_id missing');
          setTimeout(() => {
            this.setAuth(this.ready ? 'authorizationStateReady' : 'authorizationStateWaitPhoneNumber');
            this.emit({ '@type': 'updateConnectionState', state: { '@type': 'connectionStateReady' } });
          }, 20);
          return ok;
        case 'getOption':
          return { '@type': 'optionValueString', value: 'mock-1.8.49' };
        case 'setAuthenticationPhoneNumber':
          if (!/^\+?\d{8,}$/.test(q.phone_number)) throw err(400, 'PHONE_NUMBER_INVALID');
          setTimeout(() => this.setAuth('authorizationStateWaitCode'), 10);
          return ok;
        case 'checkAuthenticationCode':
          if (q.code === '99999') throw err(400, 'PHONE_CODE_INVALID');
          if (q.code === '77777') throw err(429, 'Too Many Requests: retry after 1');
          setTimeout(() => (q.code === '22222' ? this.setAuth('authorizationStateWaitPassword', { password_hint: 'the usual' }) : this.setAuth('authorizationStateReady')), 10);
          return ok;
        case 'checkAuthenticationPassword':
          if (q.password !== 'hunter2') throw err(400, 'PASSWORD_HASH_INVALID');
          setTimeout(() => this.setAuth('authorizationStateReady'), 10);
          return ok;
        case 'logOut':
          setTimeout(() => {
            this.setAuth('authorizationStateLoggingOut');
            this.setAuth('authorizationStateClosed');
          }, 10);
          return ok;
        case 'getMe':
          return users[1];
        case 'getUser':
          return users[q.user_id] || (() => { throw err(404, 'User not found'); })();
        case 'getCreatedPublicChats':
          return { '@type': 'chats', chat_ids: [-1001, -1002] };
        case 'getChat':
          if (!chats[q.chat_id]) throw err(404, 'Chat not found');
          return chats[q.chat_id];
        case 'getChatPinnedMessage':
          if (!pinned[q.chat_id]) throw err(404, 'Message not found');
          return pinned[q.chat_id];
        case 'getMessage': {
          const m = (history[q.chat_id] || []).find((x) => x.id === q.message_id) || (pinned[q.chat_id]?.id === q.message_id ? pinned[q.chat_id] : null);
          if (!m) throw err(404, 'Message not found');
          return m;
        }
        case 'getSupergroup':
          if (!supergroups[q.supergroup_id]) throw err(404, 'Supergroup not found');
          return supergroups[q.supergroup_id];
        case 'getSupergroupFullInfo':
          return fulls[q.supergroup_id] || { '@type': 'supergroupFullInfo', description: '' };
        case 'searchPublicChat': {
          const u = String(q.username).toLowerCase();
          const sg = Object.values(supergroups).find((s) => s.usernames?.editable_username?.toLowerCase() === u);
          if (!sg) throw err(400, 'USERNAME_NOT_OCCUPIED');
          return Object.values(chats).find((c) => c.type.supergroup_id === sg.id);
        }
        case 'searchPublicChats': {
          const ids = Object.values(chats).filter((c) => supergroups[c.type.supergroup_id]?.usernames?.editable_username?.startsWith(q.query)).map((c) => c.id);
          return { '@type': 'chats', chat_ids: ids.slice(0, 20) };
        }
        case 'checkChatUsername': {
          const u = String(q.username).toLowerCase();
          const taken = Object.values(supergroups).some((s) => s.usernames?.editable_username?.toLowerCase() === u);
          if (u === 'tgs_toomany') return { '@type': 'checkChatUsernameResultPublicChatsTooMany' };
          return { '@type': taken ? 'checkChatUsernameResultUsernameOccupied' : 'checkChatUsernameResultOk' };
        }
        case 'createNewSupergroupChat': {
          const sg = chatSeq;
          chatSeq += 1;
          const id = -100000 - sg;
          channel({ id, sg, title: q.title, username: null, description: q.description, creator: true, photo: false });
          return chats[id];
        }
        case 'setSupergroupUsername':
          if (q.username === 'tgs_toomany') throw err(400, 'Too many public channels.');
          supergroups[q.supergroup_id].usernames = { editable_username: q.username, active_usernames: [q.username] };
          return ok;
        case 'deleteChat':
          delete chats[q.chat_id];
          return ok;
        case 'sendMessage': {
          const tmpId = nextMsgId + 1;
          const realId = nextMsgId;
          nextMsgId += 1 << 20;
          const msg = text(realId, q.chat_id, q.input_message_content.text.text, Math.floor(Date.now() / 1000));
          const tmp = { ...msg, id: tmpId, sending_state: { '@type': 'messageSendingStatePending' } };
          setTimeout(() => {
            history[q.chat_id] = history[q.chat_id] || [];
            history[q.chat_id].unshift(msg);
            this.emit({ '@type': 'updateMessageSendSucceeded', old_message_id: tmpId, message: msg });
          }, 15);
          return tmp;
        }
        case 'pinChatMessage': {
          const m = (history[q.chat_id] || []).find((x) => x.id === q.message_id);
          if (m) pinned[q.chat_id] = m;
          return ok;
        }
        case 'editMessageText': {
          if (flood && !this.floodUsed) {
            this.floodUsed = true;
            throw err(429, 'Too Many Requests: retry after 1');
          }
          const m = pinned[q.chat_id];
          if (!m || m.id !== q.message_id) throw err(400, 'MESSAGE_ID_INVALID');
          m.content.text.text = q.input_message_content.text.text;
          return m;
        }
        case 'setChatDescription': {
          const sg = chats[q.chat_id]?.type.supergroup_id;
          if (sg) fulls[sg].description = q.description;
          return ok;
        }
        case 'setChatPhoto':
          return ok;
        case 'deleteMessages':
          history[q.chat_id] = (history[q.chat_id] || []).filter((m) => !q.message_ids.includes(m.id));
          return ok;
        case 'loadChats':
          if (this.loaded) throw err(404, 'Not Found');
          this.loaded = true;
          return ok;
        case 'getChats':
          return { '@type': 'chats', chat_ids: [-1001, -1002, -1003, -1004, -1010] };
        case 'getChatHistory':
          if (!chats[q.chat_id]) throw err(404, 'Chat not found');
          return this.paged(q.chat_id, q.from_message_id, q.limit);
        case 'downloadFile': {
          const file = { '@type': 'file', id: q.file_id, remote: { unique_id: `u${q.file_id}` }, local: { is_downloading_completed: false } };
          setTimeout(() => this.emit({ '@type': 'updateFile', file: { ...file, local: { is_downloading_completed: true, path: '/x' } } }), 20);
          return file;
        }
        case 'readFile': {
          const hue = (q.file_id * 37) % 360;
          const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="240"><rect width="320" height="240" fill="hsl(${hue} 30% 80%)"/><circle cx="160" cy="120" r="60" fill="hsl(${hue} 40% 55%)"/></svg>`;
          return { '@type': 'filePart', data: new Blob([svg], { type: 'image/svg+xml' }) };
        }
        case 'joinChat':
          this.joined.add(q.chat_id);
          return ok;
        case 'resendAuthenticationCode':
          return ok;
        default:
          throw err(400, `Method '${t}' is not supported by the mock`);
      }
    }
  }

  window.tdweb = { default: MockTdClient };
})();
