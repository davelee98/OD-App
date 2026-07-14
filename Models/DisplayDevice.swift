import Foundation
import CoreGraphics
import SwiftData

/// A saved OpenDisplay e-paper screen in the local registry.
///
/// `friendlyName` and `deviceLocation` are **user-entered** — the firmware config schema
/// (`ble_proto.packet_types`, max id 43) exposes no name/location field, and the 16-byte scan
/// advertisement can't carry strings. `lastKnownResolution`/`colorScheme` are cached from the
/// device's Toolbox config (read on connect) so the Composer can lay out a photo offline.
///
/// This is the `Codable` DTO the UI works with; it is persisted through `SavedDisplayEntity`
/// (SwiftData). If firmware ever adds a name/location packet, populate these in `apply(config:)`.
struct DisplayDevice: Identifiable, Codable, Equatable {
    /// The CoreBluetooth peripheral identifier (stable per app install) — our reconnect key.
    let id: String
    var friendlyName: String
    var deviceLocation: String
    var lastKnownResolution: CGSize
    var colorScheme: Int
    var lastSeen: Date

    init(id: String,
         friendlyName: String,
         deviceLocation: String = "",
         lastKnownResolution: CGSize = CGSize(width: 800, height: 480),
         colorScheme: Int = 0,
         lastSeen: Date = .now) {
        self.id = id
        self.friendlyName = friendlyName
        self.deviceLocation = deviceLocation
        self.lastKnownResolution = lastKnownResolution
        self.colorScheme = colorScheme
        self.lastSeen = lastSeen
    }
}

/// SwiftData persistence mirror of `DisplayDevice`. Stored as `width`/`height` ints rather than a
/// `CGSize` so every stored property maps onto a native SwiftData attribute type.
@Model
final class SavedDisplayEntity {
    @Attribute(.unique) var id: String
    var friendlyName: String
    var deviceLocation: String
    var width: Int
    var height: Int
    var colorScheme: Int
    var lastSeen: Date
    var dateAdded: Date
    /// True once `width`/`height`/`colorScheme` came from an actual hardware config read (via
    /// `apply(config:)`); false while they are still the fallback guess. Distinguishes a confirmed
    /// panel from "we never asked", so the UI can mark provisional values and safe overwrites.
    /// Defaults to false so a lightweight SwiftData migration of existing stores treats their
    /// values as unconfirmed until the next successful read.
    var resolutionConfirmed: Bool = false

    init(id: String,
         friendlyName: String,
         deviceLocation: String = "",
         width: Int = 800,
         height: Int = 480,
         colorScheme: Int = 0,
         resolutionConfirmed: Bool = false,
         lastSeen: Date = .now,
         dateAdded: Date = .now) {
        self.id = id
        self.friendlyName = friendlyName
        self.deviceLocation = deviceLocation
        self.width = width
        self.height = height
        self.colorScheme = colorScheme
        self.resolutionConfirmed = resolutionConfirmed
        self.lastSeen = lastSeen
        self.dateAdded = dateAdded
    }
}

extension SavedDisplayEntity {
    convenience init(from dto: DisplayDevice) {
        self.init(id: dto.id,
                  friendlyName: dto.friendlyName,
                  deviceLocation: dto.deviceLocation,
                  width: Int(dto.lastKnownResolution.width),
                  height: Int(dto.lastKnownResolution.height),
                  colorScheme: dto.colorScheme,
                  lastSeen: dto.lastSeen)
    }

    /// Snapshot as the Codable DTO (export / value-type use).
    var dto: DisplayDevice {
        DisplayDevice(id: id,
                      friendlyName: friendlyName,
                      deviceLocation: deviceLocation,
                      lastKnownResolution: resolution,
                      colorScheme: colorScheme,
                      lastSeen: lastSeen)
    }

    var resolution: CGSize { CGSize(width: width, height: height) }

    /// Refresh cached hardware facts from a freshly-read device config. This is the only path that
    /// marks the resolution confirmed — a plain Save never fabricates one.
    func apply(config: ODConfigModel) {
        if config.displayWidth > 0 { width = config.displayWidth }
        if config.displayHeight > 0 { height = config.displayHeight }
        colorScheme = Int(config.colorScheme)
        resolutionConfirmed = true
        lastSeen = .now
    }
}
