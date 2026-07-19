import Foundation

/// The 0x50 two-step challenge/response handshake (always plaintext, even when re-authenticating).
///
/// Step 1  host→device `[00][50][00]` → device `[00][50][status][server_nonce:16][device_id:4?]`
///         (old firmware omits device_id; default to `00 00 00 01`). status `ALREADY (0x02)` on the
///         first try means a stale session — resend step 1 once to force a fresh challenge.
/// Step 2  host→device `[00][50][client_nonce:16][mac:16]`, mac = CMAC(master, server_nonce ‖
///         client_nonce ‖ device_id) → device `[00][50][status][server_proof:16]`.
/// On success, derive the session key/id and **verify the device's proof** (constant-time compare of
/// the recomputed `CMAC(session_key, server_nonce ‖ client_nonce ‖ device_id)`) so a peer that just
/// echoes status OK without the master key is rejected.
@MainActor
struct Authenticator {
    let router: ODNotificationRouter
    let transmit: (Data) async throws -> Void        // sends plaintext (0x50 is never encrypted)
    let setExpectedOpcode: (UInt8?) -> Void
    /// Injectable for deterministic tests; production uses 16 secure-random bytes.
    var makeClientNonce: () -> [UInt8] = { (0..<16).map { _ in UInt8.random(in: 0...255) } }

    struct Session { let key: [UInt8]; let id: [UInt8] }

    func authenticate(masterKey: [UInt8]) async throws -> Session {
        let lo = UInt8(CMD_AUTHENTICATE & 0xFF)
        setExpectedOpcode(lo)
        defer { setExpectedOpcode(nil) }

        // --- Step 1: request a challenge, retrying once past a stale ALREADY session. ---
        var serverNonce: [UInt8] = []
        var deviceID = ODCrypto.deviceID
        for attempt in 0..<2 {
            try await transmit(ODFrame.command(CMD_AUTHENTICATE, payload: [AUTH_STATUS_CHALLENGE]))
            let note = try await router.awaitNotification(operation: "authChallenge", timeout: 10) { $0.opcode == lo }
            let p = note.payload   // [status][server_nonce:16][device_id:4?]
            guard let status = p.first else { throw ODProtocolError.malformedResponse("auth challenge empty") }
            if status == AUTH_STATUS_ALREADY, attempt == 0 { continue }
            try Self.throwIfStatusBad(status, stage: "challenge")
            guard p.count >= 17 else { throw ODProtocolError.malformedResponse("auth challenge too short") }
            serverNonce = Array(p[1..<17])
            if p.count >= 21 { deviceID = Array(p[17..<21]) }   // wire order; not host-endian
            break
        }
        guard !serverNonce.isEmpty else { throw ODProtocolError.authFailed("no fresh challenge (session busy)") }

        // --- Step 2: prove key knowledge, receive the device's proof. ---
        let clientNonce = makeClientNonce()
        let mac = try ODCrypto.challengeResponse(master: masterKey, serverNonce: serverNonce,
                                                 clientNonce: clientNonce, deviceID: deviceID)
        setExpectedOpcode(lo)
        try await transmit(ODFrame.command(CMD_AUTHENTICATE, payload: clientNonce + mac))
        let note = try await router.awaitNotification(operation: "authProof", timeout: 10) { $0.opcode == lo }
        let p = note.payload   // [status][server_proof:16]
        guard let status = p.first else { throw ODProtocolError.malformedResponse("auth proof empty") }
        try Self.throwIfStatusBad(status, stage: "proof")
        guard p.count >= 17 else { throw ODProtocolError.malformedResponse("auth proof too short") }
        let serverProof = Array(p[1..<17])

        // --- Derive session + verify mutual auth. ---
        let sessionKey = try ODCrypto.deriveSessionKey(master: masterKey, clientNonce: clientNonce,
                                                       serverNonce: serverNonce, deviceID: deviceID)
        let expected = try ODCrypto.serverProof(sessionKey: sessionKey, serverNonce: serverNonce,
                                                clientNonce: clientNonce, deviceID: deviceID)
        guard ODCrypto.constantTimeEqual(expected, serverProof) else {
            throw ODProtocolError.authFailed("mutual authentication failed: server proof mismatch")
        }
        let sessionID = try ODCrypto.deriveSessionID(sessionKey: sessionKey, clientNonce: clientNonce, serverNonce: serverNonce)
        return Session(key: sessionKey, id: sessionID)
    }

    /// Map a 0x50 status byte to an error; `CHALLENGE/SUCCESS (0x00)` and `ALREADY (0x02)` are not
    /// terminal here (the caller handles ALREADY's retry).
    private static func throwIfStatusBad(_ status: UInt8, stage: String) throws {
        switch status {
        case AUTH_STATUS_SUCCESS, AUTH_STATUS_ALREADY: return
        case AUTH_STATUS_FAILED:     throw ODProtocolError.authFailed("\(stage): wrong key")
        case AUTH_STATUS_NOT_CONFIG: throw ODProtocolError.authFailed("\(stage): encryption not configured on device")
        case AUTH_STATUS_RATE_LIMIT: throw ODProtocolError.authFailed("\(stage): rate limited (too many attempts)")
        default:                     throw ODProtocolError.authFailed("\(stage): device error 0x\(String(status, radix: 16))")
        }
    }
}
