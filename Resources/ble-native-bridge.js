(function (global) {
  'use strict';

  let nextWriteId = 1;
  let nextTimerId = 1;
  const writes = Object.create(null);
  const timers = Object.create(null);

  function bytesToHex(value) {
    const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
    return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
  }

  function hexToBytes(hex) {
    const clean = String(hex || '').replace(/[^0-9a-f]/gi, '');
    const bytes = new Uint8Array(clean.length / 2);
    for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(clean.substr(i * 2, 2), 16);
    return bytes;
  }

  global.console = global.console || {};
  global.console.log = global.console.log || function () {
    nativeBridge.log(Array.prototype.join.call(arguments, ' '));
  };
  global.console.warn = global.console.warn || global.console.log;
  global.console.error = global.console.error || global.console.log;

  global.setTimeout = function (callback, milliseconds) {
    const id = nextTimerId++;
    timers[id] = callback;
    nativeBridge.invoke(JSON.stringify({ method: 'scheduleTimer', id: id, milliseconds: Number(milliseconds) || 0 }));
    return id;
  };

  global.clearTimeout = function (id) {
    delete timers[id];
    nativeBridge.invoke(JSON.stringify({ method: 'cancelTimer', id: Number(id) || 0 }));
  };

  global.__odFireTimer = function (id) {
    const callback = timers[id];
    if (!callback) return;
    delete timers[id];
    callback();
  };

  global.TextEncoder = global.TextEncoder || function TextEncoder() {};
  global.TextEncoder.prototype.encode = function (text) {
    const encoded = unescape(encodeURIComponent(String(text)));
    const bytes = new Uint8Array(encoded.length);
    for (let i = 0; i < encoded.length; i++) bytes[i] = encoded.charCodeAt(i);
    return bytes;
  };

  global.crypto = global.crypto || {};
  global.crypto.getRandomValues = function (target) {
    const bytes = hexToBytes(nativeBridge.randomHex(target.length));
    target.set(bytes);
    return target;
  };
  global.crypto.subtle = {
    importKey: function (_format, keyData) {
      return Promise.resolve({ bytes: new Uint8Array(keyData) });
    },
    encrypt: function (algorithm, key, data) {
      const request = {
        key: bytesToHex(key.bytes),
        iv: bytesToHex(algorithm.iv || new Uint8Array(16)),
        data: bytesToHex(data)
      };
      const result = nativeBridge.aesCBC(JSON.stringify(request));
      if (!result || result.indexOf('error:') === 0) {
        return Promise.reject(new Error(result ? result.substring(6) : 'AES-CBC failed'));
      }
      return Promise.resolve(hexToBytes(result).buffer);
    }
  };

  global.fetch = global.fetch || function (path) {
    const isConfigRequest = String(path || '').split(/[?#]/, 1)[0].endsWith('/config.yaml') ||
      String(path || '').split(/[?#]/, 1)[0] === 'config.yaml';
    if (isConfigRequest && typeof global.__odConfigYAML === 'string') {
      return Promise.resolve({
        ok: true,
        status: 200,
        text: function () { return Promise.resolve(global.__odConfigYAML); }
      });
    }
    return Promise.resolve({ ok: false, status: 404, text: function () { return Promise.resolve(''); } });
  };

  global.__odNativeWrite = function (value) {
    const id = nextWriteId++;
    return new Promise(function (resolve, reject) {
      writes[id] = { resolve: resolve, reject: reject };
      nativeBridge.invoke(JSON.stringify({ method: 'write', id: id, hex: bytesToHex(value) }));
    });
  };

  global.__odResolveWrite = function (id, errorMessage) {
    const pending = writes[id];
    if (!pending) return;
    delete writes[id];
    if (errorMessage) pending.reject(new Error(errorMessage));
    else pending.resolve();
  };

  global.__odHexToBytes = hexToBytes;
  global.__odBytesToHex = bytesToHex;
})(globalThis);
