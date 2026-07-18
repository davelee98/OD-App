import SwiftUI

/// Startup splash shown briefly before the main "My Displays" list appears. Colors and type
/// scale are lifted from opendisplay.org's `:root` design tokens (css/colors_and_type.css) so
/// the app's first impression matches the website.
struct SplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("ODLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .containerRelativeFrame(.horizontal) { width, _ in width * 0.5 }
                .frame(maxWidth: 320)
                // Splash always uses the fixed-light "paper" background, so pin the logo to its
                // light-appearance variant. Otherwise, in system dark mode the dark (light-ink)
                // logo variant would render near-white lettering on the light paper and vanish.
                .environment(\.colorScheme, .light)

            VStack(spacing: 10) {
                (
                    Text("Your data.\nYour screen.\n")
                        .foregroundStyle(ODPalette.ink)
                    + Text("Designed for e-paper.")
                        .foregroundStyle(ODPalette.blueInk)
                )
                .font(.system(size: 28, weight: .semibold, design: .default))
                .multilineTextAlignment(.center)

                Text("OpenDisplay is an open standard and open firmware that lets any sender put pictures on any screen. Local, low-power, no cloud in the middle.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ODPalette.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 4) {
                Text("Version \(AppInfo.version)")
                Text("Copyright (c) 2026 by OpenDisplay.org")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(ODPalette.ink3)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ODPalette.paper)
    }
}

/// A subset of opendisplay.org's brand palette (css/colors_and_type.css `:root`).
private enum ODPalette {
    static let ink      = Color(red: 0x0B / 255, green: 0x0F / 255, blue: 0x12 / 255)   // --od-ink / fg1
    static let ink2     = Color(red: 0x2A / 255, green: 0x31 / 255, blue: 0x38 / 255)   // --od-ink-2 / fg2
    static let ink3     = Color(red: 0x5A / 255, green: 0x64 / 255, blue: 0x70 / 255)   // --od-ink-3 / fg3
    static let blueInk  = Color(red: 0x00 / 255, green: 0xA6 / 255, blue: 0xDD / 255)   // --od-blue-ink
    static let paper    = Color(red: 0xFB / 255, green: 0xFA / 255, blue: 0xF7 / 255)   // --od-paper / bg1
}
