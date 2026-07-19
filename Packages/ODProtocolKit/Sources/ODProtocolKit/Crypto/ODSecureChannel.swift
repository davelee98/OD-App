import Foundation

/// Owns the live session state and transparently wraps/unwraps the CCM envelope at the transport
/// seam. Mirrors the py-opendisplay driver's `_encrypt_frame` / `_read` behavior exactly:
///
/// - Outbound: once a session exists, every command is encrypted **except** the two bootstrap
///   opcodes (`CMD_AUTHENTICATE 0x50` opens the session; `CMD_FIRMWARE_VERSION 0x43` must be
///   readable pre-auth). The nonce counter starts at 0 and is used-then-incremented per frame.
/// - Inbound: a response is encrypted only if it is at least `encryptedResponseMinLen` (31) bytes;
///   shorter frames (direct-write ACKs, `FF FF` compressed-fail, the 3-byte `FE`/`FF` frames) are
///   sent plaintext by the firmware even during a session and pass through untouched. A decrypted
///   response is re-framed to `[cmd_high][cmd_low][payload]`, byte-identical in shape to a plaintext
///   `[status][opcode][payload]`, so it flows through the same classifier.
@MainActor
final class ODSecureChannel {
    private var sessionKey: [UInt8]?
    private var sessionID: [UInt8]?
    private var counter: UInt64 = 0

    /// Opcodes that stay plaintext even with a live session.
    private static let plaintextOpcodes: Set<UInt8> =
        [UInt8(CMD_AUTHENTICATE & 0xFF), UInt8(CMD_FIRMWARE_VERSION & 0xFF)]

    /// cmd(2) + nonce(16) + len(1) + tag(12); anything shorter is plaintext.
    static let encryptedResponseMinLen = 31

    var isEstablished: Bool { sessionKey != nil && sessionID != nil }

    func establish(sessionKey: [UInt8], sessionID: [UInt8]) {
        self.sessionKey = sessionKey
        self.sessionID = sessionID
        self.counter = 0
    }

    func reset() {
        sessionKey = nil
        sessionID = nil
        counter = 0
    }

    /// Encrypt an outbound `[00][opcode][payload…]` frame, unless there is no session or it targets a
    /// bootstrap opcode. Advances the nonce counter only on a successful wrap.
    func wrapOutbound(_ frame: Data) throws -> Data {
        guard let sk = sessionKey, let sid = sessionID, frame.count >= 2 else { return frame }
        let opcode = frame[frame.index(frame.startIndex, offsetBy: 1)]
        if Self.plaintextOpcodes.contains(opcode) { return frame }
        let cmd = Array(frame.prefix(2))
        let payload = Array(frame.dropFirst(2))
        let out = try ODCrypto.encryptCommand(sessionKey: sk, sessionID: sid, counter: counter, cmd: cmd, payload: payload)
        counter &+= 1
        return Data(out)
    }

    /// Decrypt an inbound response when a session is active and the frame is envelope-sized; otherwise
    /// return it unchanged. Returns the `[cmd_high][cmd_low][payload…]` plaintext-equivalent framing.
    func unwrapInbound(_ raw: Data) throws -> Data {
        guard let sk = sessionKey, raw.count >= Self.encryptedResponseMinLen else { return raw }
        let (cmd, payload) = try ODCrypto.decryptResponse(sessionKey: sk, raw: Array(raw))
        return Data([UInt8(cmd >> 8), UInt8(cmd & 0xFF)] + payload)
    }
}
