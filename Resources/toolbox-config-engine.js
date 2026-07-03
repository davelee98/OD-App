(function (global) {
  'use strict';

  let schema = null;
  let schemaYAML = '';
  let presets = null;

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function parseYAML(text) {
    if (!global.jsyaml || typeof global.jsyaml.load !== 'function') {
      throw new Error('js-yaml is unavailable');
    }
    const document = global.jsyaml.load(String(text || ''));
    if (!document || !document.ble_proto || !document.ble_proto.packet_types) {
      throw new Error('Invalid YAML: missing ble_proto.packet_types');
    }
    return document.ble_proto;
  }

  function initialize(yamlText, presetsJSON) {
    schemaYAML = String(yamlText || '');
    schema = parseYAML(schemaYAML);
    presets = JSON.parse(String(presetsJSON || '{}'));
    if (!Array.isArray(presets.driverBoards) || !Array.isArray(presets.displays) ||
        !Array.isArray(presets.powerOptions)) {
      throw new Error('Invalid simple-config-presets.json');
    }
  }

  function parseSize(size) {
    if (typeof size === 'number' && Number.isFinite(size)) return Math.max(0, Math.floor(size));
    const match = String(size == null ? '' : size).trim().match(/^(\d+)(?:\s+bytes?)?$/i);
    return match ? parseInt(match[1], 10) : null;
  }

  function parseNumber(raw) {
    if (typeof raw === 'number') return Number.isFinite(raw) ? raw : null;
    const text = String(raw == null ? '' : raw).trim();
    if (!text) return null;
    if (/^[-+]?0x[0-9a-f]+$/i.test(text)) {
      const negative = text[0] === '-';
      const body = text.replace(/^[-+]?0x/i, '');
      const value = parseInt(body, 16);
      return negative ? -value : value;
    }
    return /^[-+]?\d+$/.test(text) ? parseInt(text, 10) : null;
  }

  function hexBytes(raw) {
    let text = String(raw == null ? '' : raw).trim();
    if (/^0x/i.test(text)) text = text.slice(2);
    text = text.replace(/[^0-9a-f]/gi, '');
    if (text.length % 2) text = '0' + text;
    const bytes = [];
    for (let i = 0; i < text.length; i += 2) bytes.push(parseInt(text.slice(i, i + 2), 16));
    return bytes;
  }

  function bytesToHex(bytes) {
    return Array.from(bytes || []).map(function (byte) {
      return Number(byte).toString(16).padStart(2, '0');
    }).join('');
  }

  function utf8Encode(text) {
    const encoded = unescape(encodeURIComponent(String(text == null ? '' : text)));
    const bytes = [];
    for (let i = 0; i < encoded.length; i++) bytes.push(encoded.charCodeAt(i));
    return bytes;
  }

  function utf8Decode(bytes) {
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    try { return decodeURIComponent(escape(binary)); }
    catch (_) { return binary; }
  }

  function littleEndian(number, size) {
    let value = Number(number || 0);
    if (value < 0) value += Math.pow(256, size);
    const bytes = [];
    for (let index = 0; index < size; index++) {
      bytes.push(((value % 256) + 256) % 256);
      value = Math.floor(value / 256);
    }
    return bytes;
  }

  function crc16(bytes) {
    let crc = 0xffff;
    for (const byte of bytes) {
      crc ^= (byte << 8);
      for (let bit = 0; bit < 8; bit++) {
        crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) : (crc << 1);
        crc &= 0xffff;
      }
    }
    return crc;
  }

  function packetDefinition(id) {
    return schema.packet_types[String(parseInt(id, 10))] || schema.packet_types[String(id)] || null;
  }

  function encodeField(field, raw) {
    const size = parseSize(field.size);
    if (size == null) return hexBytes(raw);
    let bytes = [];
    if (field.type === 'text' || field.name === 'ssid' || field.name === 'password') {
      bytes = utf8Encode(raw).slice(0, Math.max(0, size - 1));
    } else if (field.name === 'encryption_key' ||
               String(field.name).toLowerCase().startsWith('reserved')) {
      bytes = hexBytes(raw).slice(0, size);
    } else {
      bytes = littleEndian(parseNumber(raw) || 0, size);
    }
    while (bytes.length < size) bytes.push(0);
    return bytes.slice(0, size);
  }

  function decodeField(field, bytes) {
    if (field.type === 'text' || field.name === 'ssid' || field.name === 'password') {
      const zero = bytes.indexOf(0);
      return utf8Decode(zero >= 0 ? bytes.slice(0, zero) : bytes);
    }
    if (field.name === 'encryption_key') return bytesToHex(bytes);
    if (String(field.name).toLowerCase().startsWith('reserved') || bytes.length > 8) {
      return bytesToHex(bytes);
    }
    let value = 0;
    let multiplier = 1;
    for (const byte of bytes) {
      value += byte * multiplier;
      multiplier *= 256;
    }
    return value === 0 ? '0x0' : String(value);
  }

  function sequenceCapacity() {
    const fields = schema.packet_structure && schema.packet_structure.single_packet &&
      schema.packet_structure.single_packet.fields;
    const numberField = Array.isArray(fields) && fields.find(function (field) { return field.name === 'number'; });
    const size = numberField ? parseSize(numberField.size) : 1;
    return Math.pow(256, size || 1);
  }

  function instanceCapacity(definition) {
    const field = definition.fields && definition.fields.find(function (item) {
      return item.name === 'instance_number';
    });
    const size = field ? parseSize(field.size) : null;
    return size == null ? sequenceCapacity() : Math.pow(256, size);
  }

  function validationIssues(config, encodedLength) {
    const packets = Array.isArray(config.packets) ? config.packets : [];
    const issues = [];
    const counts = Object.create(null);

    for (const packet of packets) {
      const id = String(parseInt(packet.id, 10));
      const definition = packetDefinition(id);
      if (!definition) {
        issues.push({ severity: 'error', code: 'unknown_packet', message: 'Unknown packet type ' + id });
        continue;
      }
      counts[id] = (counts[id] || 0) + 1;
    }

    for (const id of Object.keys(schema.packet_types)) {
      const definition = schema.packet_types[id];
      const count = counts[String(parseInt(id, 10))] || 0;
      if (definition.required && count === 0) {
        issues.push({ severity: 'error', code: 'missing_required', message: definition.name + ' is required' });
      }
      if (!definition.repeatable && count > 1) {
        issues.push({ severity: 'error', code: 'not_repeatable', message: definition.name + ' may appear only once' });
      }
      if (definition.repeatable && count > instanceCapacity(definition)) {
        issues.push({ severity: 'error', code: 'instance_limit', message: definition.name + ' exceeds its instance-number capacity' });
      }
      if (definition.repeatable && count > 0) {
        const used = Object.create(null);
        for (const packet of packets.filter(function (item) { return parseInt(item.id, 10) === parseInt(id, 10); })) {
          const value = parseNumber(packet.fields && packet.fields.instance_number);
          if (value == null || value < 0 || value >= instanceCapacity(definition)) {
            issues.push({ severity: 'error', code: 'invalid_instance', message: definition.name + ' has an invalid instance number' });
          } else if (used[value]) {
            issues.push({ severity: 'error', code: 'duplicate_instance', message: definition.name + ' instance ' + value + ' is duplicated' });
          }
          used[value] = true;
        }
      }
    }

    if (packets.length > sequenceCapacity()) {
      issues.push({ severity: 'error', code: 'packet_limit', message: 'Configuration exceeds the packet-number capacity' });
    }
    if (encodedLength > 4096) {
      issues.push({ severity: 'warning', code: 'size_warning', message: 'Configuration exceeds the website\'s recommended 4 KiB size' });
    }
    return issues;
  }

  function encode(config, skipValidation) {
    if (!schema) throw new Error('Schema is not loaded');
    const packets = Array.isArray(config.packets) ? config.packets : [];
    if (!skipValidation) {
      const errors = validationIssues(config, 0).filter(function (issue) { return issue.severity === 'error'; });
      if (errors.length) throw new Error(errors.map(function (issue) { return issue.message; }).join('; '));
    }

    const outer = [0, 0, Number(config.version == null ? schema.version : config.version) & 0xff];
    packets.forEach(function (packet, sequence) {
      const definition = packetDefinition(packet.id);
      if (!definition) throw new Error('Unknown packet type ' + packet.id);
      outer.push(sequence & 0xff);
      outer.push(parseInt(packet.id, 10) & 0xff);
      for (const field of definition.fields || []) {
        outer.push.apply(outer, encodeField(field, packet.fields ? packet.fields[field.name] : null));
      }
    });

    if (config.unknown_tail_hex) outer.push.apply(outer, hexBytes(config.unknown_tail_hex));
    const crc = crc16(outer);
    const totalLength = outer.length + 2;
    if (totalLength > 0xffff) throw new Error('Configuration exceeds the 16-bit outer length');
    outer[0] = totalLength & 0xff;
    outer[1] = (totalLength >> 8) & 0xff;
    outer.push(crc & 0xff, (crc >> 8) & 0xff);
    return outer;
  }

  function decode(hex) {
    const bytes = hexBytes(hex);
    if (bytes.length < 5) throw new Error('Configuration is too short');
    const declared = bytes[0] | (bytes[1] << 8);
    if (declared !== bytes.length) throw new Error('Configuration length does not match its header');
    const storedCRC = bytes[bytes.length - 2] | (bytes[bytes.length - 1] << 8);
    const body = bytes.slice(0, -2);
    const crcInput = body.slice();
    crcInput[0] = 0;
    crcInput[1] = 0;
    if (crc16(crcInput) !== storedCRC) throw new Error('Configuration CRC does not match');

    const result = {
      version: bytes[2],
      minor_version: Number(schema.minor_version || 0),
      packets: [],
      unknown_tail_hex: ''
    };
    let offset = 3;
    const end = bytes.length - 2;
    while (offset < end) {
      if (offset + 2 > end) throw new Error('Truncated packet header');
      const headerOffset = offset;
      const id = bytes[offset + 1];
      offset += 2;
      const definition = packetDefinition(id);
      if (!definition) {
        result.unknown_tail_hex = bytesToHex(bytes.slice(headerOffset, end));
        break;
      }
      const fields = {};
      for (const field of definition.fields || []) {
        const size = parseSize(field.size);
        if (size == null) throw new Error('Cannot decode non-final variable field ' + field.name);
        if (offset + size > end) throw new Error('Truncated field ' + field.name);
        fields[field.name] = decodeField(field, bytes.slice(offset, offset + size));
        offset += size;
      }
      result.packets.push({ id: String(id), fields: fields });
    }
    return result;
  }

  function upsert(config, id, fields, instance) {
    const numericID = parseInt(id, 10);
    const packets = config.packets || (config.packets = []);
    const index = packets.findIndex(function (packet) {
      if (parseInt(packet.id, 10) !== numericID) return false;
      return instance == null || String(parseNumber(packet.fields && packet.fields.instance_number) || 0) ===
        String(parseNumber(instance) || 0);
    });
    const value = { id: String(numericID), fields: clone(fields || {}) };
    if (index >= 0) packets[index] = value;
    else packets.push(value);
  }

  function presetIndex(item, list) {
    if (!item || !list) return 0;
    if (item.index != null && item.index !== '') return Number(item.index);
    const index = list.findIndex(function (candidate) { return candidate.id === item.id; });
    return index < 0 ? 0 : index + 1;
  }

  function buildDisplay(display, board) {
    const pins = board && board.displayPins ? board.displayPins : {
      reset: '0xff', busy: '0xff', dc: '0xff', cs: '0xff', data: '0x0', clk: '0x0'
    };
    const values = clone(display.config || {});
    values.instance_number = '0x0';
    values.display_technology = '1';
    values.panel_ic_type = String(display.panelIcType);
    values.legacy_tagtype = '0x0';
    values.rotation = '0';
    values.reset_pin = pins.reset || '0xff';
    values.busy_pin = pins.busy || '0xff';
    values.dc_pin = pins.dc || '0xff';
    values.cs_pin = pins.cs || '0xff';
    values.data_pin = pins.data || '0x0';
    values.clk_pin = pins.clk || '0x0';
    values.transmission_modes = board && board.transmission_modes != null
      ? String(board.transmission_modes)
      : String(values.transmission_modes == null ? '10' : values.transmission_modes);
    return values;
  }

  function buildSimple(args) {
    const board = presets.driverBoards.find(function (item) { return item.id === args.board_id; });
    const display = presets.displays.find(function (item) { return item.id === args.display_id; });
    const power = presets.powerOptions.find(function (item) { return item.id === args.power_id; });
    if (!board || !display || !power) throw new Error('Driver board, display, and power option are required');

    const config = clone(args.base_config || {
      version: Number(schema.version || 1), minor_version: Number(schema.minor_version || 0), packets: []
    });
    config.version = Number(schema.version || 1);
    config.minor_version = Number(schema.minor_version || 0);
    config.packets = Array.isArray(config.packets) ? config.packets : [];
    const originalStructure = config.packets.map(function (packet) { return String(parseInt(packet.id, 10)); }).join(',');

    upsert(config, 1, board.systemConfig);
    const manufacturer = clone(board.manufacturerData || {});
    delete manufacturer.reserved;
    manufacturer.simple_config_driver_index = String(presetIndex(board, presets.driverBoards));
    manufacturer.simple_config_display_index = String(presetIndex(display, presets.displays));
    manufacturer.simple_config_power_index = String(presetIndex(power, presets.powerOptions));
    manufacturer.simple_config_configured_at = String(Number(args.configured_at || 0));
    upsert(config, 2, manufacturer);

    const powerFields = clone(power.powerOption || {});
    if (String(powerFields.power_mode) !== '2' && board.powerDefaults) {
      Object.assign(powerFields, clone(board.powerDefaults));
    }
    if (board.installConfig && board.installConfig.type === 'esp32') {
      powerFields.deep_sleep_time_seconds = String(Math.max(0, Math.min(43200, Number(args.deep_sleep_seconds || 0))));
    }
    upsert(config, 4, powerFields);
    upsert(config, 32, buildDisplay(display, board), '0x0');

    const optional = [
      [33, board.led], [35, board.sensorData], [36, board.dataBus], [37, board.buttons],
      [40, board.touchController], [41, board.buzzerConfig], [42, board.nfcConfig], [43, board.flashConfig]
    ];
    optional.forEach(function (entry) {
      if (entry[1]) upsert(config, entry[0], entry[1], entry[1].instance_number);
    });
    (board.extraPackets || []).forEach(function (packet) {
      upsert(config, packet.pid, packet.fields, packet.fields && packet.fields.instance_number);
    });

    if (args.encryption_key && String(args.encryption_key).length === 32) {
      upsert(config, 39, {
        encryption_enabled: '1', encryption_key: String(args.encryption_key),
        session_timeout_seconds: '0', flags: '2', reset_pin: '0xff'
      });
    } else {
      config.packets = config.packets.filter(function (packet) { return parseInt(packet.id, 10) !== 39; });
    }
    if (config.unknown_tail_hex) {
      const updatedStructure = config.packets.map(function (packet) { return String(parseInt(packet.id, 10)); }).join(',');
      if (updatedStructure !== originalStructure) {
        throw new Error('Cannot add, remove, or reorder packets while preserving an unknown packet tail');
      }
    }
    return config;
  }

  function call(operation, inputJSON) {
    try {
      const args = inputJSON ? JSON.parse(inputJSON) : {};
      let result;
      switch (operation) {
      case 'initialize':
        initialize(args.yaml, args.presets_json);
        result = { version: schema.version, minor_version: schema.minor_version };
        break;
      case 'apply_schema':
        schemaYAML = String(args.yaml || '');
        schema = parseYAML(schemaYAML);
        result = { schema: { ble_proto: schema } };
        break;
      case 'schema': result = { schema: { ble_proto: schema }, yaml: schemaYAML }; break;
      case 'build_simple': result = { configuration: buildSimple(args) }; break;
      case 'encode': result = { hex: bytesToHex(encode(args.configuration, false)) }; break;
      case 'decode': result = { configuration: decode(args.hex) }; break;
      case 'validate': {
        let length = 0;
        try { length = encode(args.configuration, true).length; } catch (_) {}
        result = { issues: validationIssues(args.configuration, length), encoded_length: length };
        break;
      }
      default: throw new Error('Unknown Toolbox operation: ' + operation);
      }
      return JSON.stringify({ ok: true, result: result });
    } catch (error) {
      return JSON.stringify({ ok: false, error: error && error.message ? error.message : String(error) });
    }
  }

  global.__odToolboxCall = call;
})(globalThis);
