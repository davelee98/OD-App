import Foundation

/// Reads and writes the exact outer-packet format defined by the website's Toolbox schema.
enum ODConfig {
    static func parse(_ data: Data) throws -> ODConfigModel {
        ODConfigModel(toolbox: try ToolboxPacketCodec.decode(data))
    }

    static func serialize(_ model: ODConfigModel) throws -> Data {
        try ToolboxPacketCodec.encode(model.toolbox)
    }
}
