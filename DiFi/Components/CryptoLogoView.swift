import SwiftUI

/// Renders a coin's logo from a public icon CDN, falling back to a colored initial
/// badge when the symbol isn't in the set or the request fails (e.g. offline).
struct CryptoLogoView: View {
    let symbol: String
    var size: CGFloat = 36

    private var iconURL: URL? {
        if symbol.uppercased() == "EUR" { return nil }
        return URL(string: "https://cdn.jsdelivr.net/gh/atomiclabs/cryptocurrency-icons@master/128/color/\(symbol.lowercased()).png")
    }

    var body: some View {
        Group {
            if symbol.uppercased() == "EUR" {
                Image(systemName: "eurosign.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            } else if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        fallbackBadge
                    }
                }
            } else {
                fallbackBadge
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var fallbackBadge: some View {
        Circle()
            .fill(badgeColor.gradient)
            .overlay(
                Text(String(symbol.prefix(1)))
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private var badgeColor: Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .mint, .cyan, .brown]
        let hash = symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[hash % palette.count]
    }
}
