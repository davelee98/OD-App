(function (global) {
  'use strict';

  function emit(type, payload) {
    nativeBridge.emit(JSON.stringify({ type: type, payload: payload || {} }));
  }

  function errorText(error) {
    return error && error.message ? error.message : String(error || 'Unknown JavaScript error');
  }

  const ble = new OpenDisplayBLE({
    onLog: function (message, level) { emit('log', { message: String(message), level: String(level || 'info') }); },
    onError: function (error) { emit('error', { message: errorText(error) }); },
    onStatusChange: function (message, connected) {
      emit('status', { message: String(message), connected: !!connected });
    },
    onCommandError: function (code) { emit('error', { message: 'Device command error: ' + code }); },
    onNotification: function (bytes) {
      if (bytes && bytes.length >= 2 && bytes[0] === 0xFF &&
          ble.directWriteState && ble.directWriteState.active) {
        const state = ble.directWriteState;
        ble.directWriteState = null;
        if (state.onComplete) {
          state.onComplete(false, new Error('Device rejected image command 0x' + bytes[1].toString(16).padStart(2, '0')));
        }
      }
    }
  });

  ble.characteristic = {
    writeValueWithoutResponse: function (bytes) { return global.__odNativeWrite(bytes); }
  };

  global.__odSetConnected = function (connected) {
    ble.isConnected = !!connected;
    if (!connected) ble.resetState();
    else ble.characteristic = {
      writeValueWithoutResponse: function (bytes) { return global.__odNativeWrite(bytes); }
    };
  };

  global.__odNotify = function (hex) {
    const bytes = global.__odHexToBytes(hex);
    const event = { target: { value: new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength) } };
    ble.handleNotification(event).catch(function (error) {
      emit('error', { message: errorText(error) });
    });
  };

  function finish(id, result) { emit('operation', { id: id, ok: true, result: result || {} }); }
  function fail(id, error) { emit('operation', { id: id, ok: false, error: errorText(error) }); }

  function uploadPacked(id, args) {
    if (ble.directWriteState && ble.directWriteState.active) throw new Error('Direct write already in progress');
    const raw = global.__odHexToBytes(args.rawHex || '');
    const transmissionModes = Number(args.transmissionModes || 0);
    // Mirror opendisplay.org's ble-common.js gate: bit0 (streaming decompression) is the
    // authoritative "can inflate a stream" flag, and it forces the zip bit on. Net effect —
    // compress iff bit0 is set. (Keep line-for-line with the shared engine's direct-write path.)
    const TRANSMISSION_MODE_STREAMING_DECOMPRESSION = 0x01;
    const TRANSMISSION_MODE_ZIP = 0x02;
    let supportsZip = (transmissionModes & TRANSMISSION_MODE_ZIP) !== 0;
    const supportsStreamingDecompression = (transmissionModes & TRANSMISSION_MODE_STREAMING_DECOMPRESSION) !== 0;
    if (supportsStreamingDecompression) supportsZip = true;
    const supportsCompression = supportsZip && supportsStreamingDecompression;
    let compressed = null;
    if (args.compress !== false && supportsCompression && global.pako && global.pako.deflate) {
      compressed = global.pako.deflate(raw, { level: 9, windowBits: 9 });
    }
    const useCompressed = compressed && compressed.length > 0;
    const encrypted = !!ble.encryptionSession.authenticated;
    const chunkSize = encrypted ? 154 : 230;
    const maxStartPayload = encrypted ? 154 : 200;
    const wireBytes = useCompressed ? compressed : raw;
    let chunks = ble._prepareDirectWriteChunks(Array.from(wireBytes), chunkSize);
    let chunkIndex = 0;
    let startCommandHex = '0070';

    if (useCompressed) {
      const size = raw.length >>> 0;
      const header = new Uint8Array([size & 255, (size >>> 8) & 255, (size >>> 16) & 255, (size >>> 24) & 255]);
      const firstCount = Math.min(compressed.length, Math.max(0, maxStartPayload - 4));
      startCommandHex += global.__odBytesToHex(header) + global.__odBytesToHex(compressed.slice(0, firstCount));
      const remaining = compressed.slice(firstCount);
      chunks = ble._prepareDirectWriteChunks(Array.from(remaining), chunkSize);
    }

    ble.log(
      useCompressed
        ? 'Native JS upload compression: ' + raw.length + ' bytes to ' + compressed.length + ' bytes'
        : 'Native JS upload using ' + raw.length + ' uncompressed bytes',
      'info'
    );

    return ble._activateFullDirectWrite({
      compressed: useCompressed,
      chunks: chunks,
      chunkIndex: chunkIndex,
      useFastRefresh: !!args.useFastRefresh,
      chunkSize: chunkSize,
      pipelineSize: 1,
      trackPartial: false,
      newEtag: null,
      paletteBuffer: null,
      paletteWidth: 0,
      paletteHeight: 0,
      startCommandHex: startCommandHex,
      statusMessage: 'Starting native packed upload: ' + raw.length + ' bytes, ' + chunks.length + ' chunks',
      onProgress: function (progress, total) { emit('uploadProgress', { progress: progress, total: total }); },
      onStatusChange: function (message) { emit('uploadStatus', { message: String(message) }); },
      onComplete: function (success, error) {
        if (success) finish(id, {});
        else fail(id, error || new Error('Image upload failed'));
      }
    });
  }

  global.__odCall = function (id, operation, json) {
    let args = {};
    try { args = json ? JSON.parse(json) : {}; }
    catch (error) { fail(id, error); return; }

    let promise;
    try {
      switch (operation) {
        case 'sendHex':
          promise = ble.sendHexCommand(args.hex).then(function () { finish(id, {}); });
          break;
        case 'readFirmware':
          promise = ble.readFirmwareVersion(function (value, error) {
            if (error) fail(id, error);
            else finish(id, value || {});
          });
          break;
        case 'readMsd':
          promise = ble.readMsd(function (value, error) {
            if (error) fail(id, error);
            else finish(id, { hex: global.__odBytesToHex(value) });
          });
          break;
        case 'readConfig':
          promise = ble.readConfig(function (value, error) {
            if (error) fail(id, error);
            else finish(id, { hex: global.__odBytesToHex(new Uint8Array(value)) });
          }, function (received, total) {
            emit('configProgress', { received: received, total: total });
          });
          break;
        case 'writeConfig':
          promise = ble.writeConfig(global.__odHexToBytes(args.hex), function (error) {
            if (error) fail(id, error);
            else finish(id, {});
          });
          break;
        case 'authenticate':
          promise = ble.setEncryptionKey(global.__odHexToBytes(args.keyHex))
            .then(function () { return ble.authenticate(); })
            .then(function () { finish(id, {}); });
          break;
        case 'uploadPacked':
          promise = uploadPacked(id, args);
          break;
        case 'reboot':
          promise = ble.reboot().then(function () { finish(id, {}); });
          break;
        case 'bootloader':
          promise = ble.rebootToBootloader().then(function () { finish(id, {}); });
          break;
        default:
          throw new Error('Unknown bridge operation: ' + operation);
      }
      if (promise && typeof promise.catch === 'function') promise.catch(function (error) { fail(id, error); });
    } catch (error) {
      fail(id, error);
    }
  };

  global.__odRuntimeReady = true;
})(globalThis);
