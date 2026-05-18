import SwiftUI

/// Authentic Rotten Tomatoes badge that uses the official artwork shipped in
/// `Assets.xcassets` (`tomato`, `splat`, `certified`).
///
/// Verdict thresholds match rottentomatoes.com's common heuristic:
/// - `score >= 75` → **Certified Fresh** (gold ribbon — `certified`)
/// - `score >= 60` → **Fresh** (red tomato — `tomato`)
/// - `score <  60` → **Rotten** (green splat — `splat`)
struct RottenTomatoesBadge: View {
    enum Verdict: String {
        case certifiedFresh = "certified"
        case fresh = "tomato"
        case rotten = "splat"

        init(score: Int) {
            switch score {
            case 75...: self = .certifiedFresh
            case 60..<75: self = .fresh
            default: self = .rotten
            }
        }

        var accessibilityPrefix: String {
            switch self {
            case .certifiedFresh: "Certified Fresh"
            case .fresh: "Fresh"
            case .rotten: "Rotten"
            }
        }
    }

    let score: Int
    var iconSize: CGFloat = 18

    private var verdict: Verdict { Verdict(score: score) }

    var body: some View {
        HStack(spacing: 6) {
            Image(verdict.rawValue)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .layoutPriority(1)
            Text("\(score)%")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        // Always size to content — never let an enclosing HStack squeeze the
        // badge into wrapping ("96 %" → "96" / "%") or truncating ("108 min" →
        // "108 mi…"). The whole pill is atomic.
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(verdict.accessibilityPrefix), \(score) percent on Rotten Tomatoes")
    }
}
