import Foundation

public enum ResetCountdown {
    public static func text(reset: Date?, now: Date) -> String? {
        guard let reset, reset > now else { return nil }
        let seconds = reset.timeIntervalSince(now)
        guard seconds.isFinite, seconds < 253402300800 else { return nil }
        let minutes = max(1, Int(ceil(seconds / 60)))
        let days = minutes / 1440, hours = (minutes % 1440) / 60, remainder = minutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if remainder > 0 { parts.append("\(remainder)min") }
        return parts.joined(separator: " ")
    }
}
