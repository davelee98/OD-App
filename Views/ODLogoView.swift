import SwiftUI

struct ODLogoView: View {
    var height: CGFloat = 28

    var body: some View {
        Image("ODLogo")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(height: height)
    }
}
