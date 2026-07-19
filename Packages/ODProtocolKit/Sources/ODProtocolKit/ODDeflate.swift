import Foundation
import Czlib

/// zlib deflate/inflate via libz, pinned to **windowBits = 9** (a 512-byte window).
///
/// This is the streaming-decompression contract the panel firmware requires — the on-device
/// inflater has only a 512-byte window, so the stream MUST advertise `CINFO = 1` (zlib header byte
/// `0x18`). Apple's `Compression` framework cannot express a non-default window, which is why this
/// goes through libz `deflateInit2_` directly. There is deliberately **no default** for `windowBits`
/// at the call sites so it can never silently become 32 KB.
public enum ODDeflate {
    public enum Error: Swift.Error { case deflateInit(Int32), deflate(Int32), inflateInit(Int32), inflate(Int32) }

    /// Deflate `data` to a zlib stream. `level` 9 for full-frame image, 6 for partial payloads.
    public static func deflate(_ data: Data, level: Int32, windowBits: Int32) throws -> Data {
        // libz's next_in must be non-nil even when avail_in is 0; an empty Data would hand it a nil
        // baseAddress. Feed a 1-byte scratch buffer with avail_in 0 to keep the pointer valid.
        var input = data.isEmpty ? [UInt8](repeating: 0, count: 1) : [UInt8](data)
        let availIn = uInt(data.count)
        var stream = z_stream()
        let rc = deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY,
                               ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw Error.deflateInit(rc) }
        defer { deflateEnd(&stream) }

        var output = [UInt8]()
        let bufSize = 16384
        var buffer = [UInt8](repeating: 0, count: bufSize)

        return try input.withUnsafeMutableBufferPointer { inPtr -> Data in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = availIn
            repeat {
                let ret: Int32 = try buffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(bufSize)
                    let r = Czlib.deflate(&stream, Z_FINISH)
                    guard r == Z_OK || r == Z_STREAM_END else { throw Error.deflate(r) }
                    output.append(contentsOf: outPtr.prefix(bufSize - Int(stream.avail_out)))
                    return r
                }
                if ret == Z_STREAM_END { break }
            } while stream.avail_out == 0
            return Data(output)
        }
    }

    /// Inflate a windowBits-9 zlib stream. Test-only (round-trip verification).
    public static func inflate(_ data: Data, windowBits: Int32) throws -> Data {
        var stream = z_stream()
        let rc = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw Error.inflateInit(rc) }
        defer { inflateEnd(&stream) }

        var input = [UInt8](data)
        var output = [UInt8]()
        let bufSize = 16384
        var buffer = [UInt8](repeating: 0, count: bufSize)

        return try input.withUnsafeMutableBufferPointer { inPtr -> Data in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)
            repeat {
                let ret: Int32 = try buffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(bufSize)
                    let r = Czlib.inflate(&stream, Z_NO_FLUSH)
                    guard r == Z_OK || r == Z_STREAM_END else { throw Error.inflate(r) }
                    output.append(contentsOf: outPtr.prefix(bufSize - Int(stream.avail_out)))
                    return r
                }
                if ret == Z_STREAM_END { break }
            } while stream.avail_out == 0
            return Data(output)
        }
    }
}
