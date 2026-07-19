import Foundation

/// Single source of truth for every wire size budget. Budgets shrink when a session is encrypted
/// because each packet then carries the 31-byte CCM envelope (2 cmd + 16 nonce + 1 len + 12 tag).
/// Phase 1 only uses the plaintext values; the `encrypted` path is present so the crypto phase
/// slots in without touching call sites.
struct ODChunkPolicy {
    let encrypted: Bool

    /// Config-write data bytes per 0x41/0x42 chunk (matches generated `CONFIG_CHUNK_SIZE`).
    var configChunkSize: Int { Int(CONFIG_CHUNK_SIZE) }

    /// 0x71 direct-write data payload per chunk.
    var directWriteChunkSize: Int { encrypted ? 154 : 230 }

    /// Max payload after the 2-byte command in the 0x70 Image Start.
    var directWriteStartPayload: Int { encrypted ? 154 : 200 }

    /// Max leading compressed bytes that ride in the Image Start (after the 4-byte size header).
    var directWriteStartCompressedLeading: Int { directWriteStartPayload - 4 }   // 196 / 150

    /// PIPE 0x81 data payload per frame given the negotiated effective frame size. Plaintext frame is
    /// `cmd(2)+seq(1)+data`; encrypted wraps `[seq][data]` in the 31-byte CCM envelope, so the seq
    /// costs one extra plaintext byte: `data <= frameEff - 32`.
    func pipeDataSize(frameEff: Int) -> Int {
        max(1, encrypted ? frameEff - 32 : frameEff - Int(PIPE_FRAME_OVERHEAD))
    }
}
