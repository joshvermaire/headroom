import Foundation
import HeadroomCore

/// Made-up but plausible data for README screenshots, so they don't show anyone's real disk.
enum Demo {
    static let volume = VolumeStatus(total: 994_662_584_320, available: 96_400_000_000, free: 81_900_000_000)

    static let sizes: [String: (bytes: Int64, growth: Int64)] = [
        "xcode-derived-data": (18_400_000_000, 2_600_000_000),
        "npm": (9_700_000_000, 420_000_000),
        "pnpm": (6_300_000_000, 900_000_000),
        "xcode-device-support": (5_600_000_000, 0),
        "gradle": (4_100_000_000, 0),
        "homebrew": (3_200_000_000, 310_000_000),
        "uv": (2_800_000_000, 0),
        "docker": (41_800_000_000, 6_300_000_000),
        "ios-backups": (22_400_000_000, 0),
        "simulators": (14_200_000_000, 0),
        "downloads": (8_900_000_000, 1_100_000_000),
        "agent-data": (3_600_000_000, 400_000_000),
    ]

    /// Hourly samples over the last week: a slow slide, a cleanup three days ago, then a faster slide.
    static func history(now: Date) -> History {
        var history = History()
        let current = Double(volume.available)
        for hoursAgo in stride(from: 7 * 24, through: 0, by: -1) {
            let days = Double(hoursAgo) / 24
            let trend = days > 3.2
                ? 131e9 - (7 - days) * 4.5e9
                : current + days * 10.5e9
            let wiggle = hoursAgo == 0 ? 0 : sin(Double(hoursAgo) / 3.7) * 0.8e9
            history.record(VolumeSample(date: now.addingTimeInterval(-Double(hoursAgo) * 3600), available: Int64(trend + wiggle)))
        }
        return history
    }

    static func nodeModules(now: Date) -> [NodeModulesFolder] {
        let projects: [(name: String, bytes: Int64, daysIdle: Double)] = [
            ("storefront", 1_310_000_000, 2),
            ("electron-playground", 1_120_000_000, 214),
            ("mobile-app", 960_000_000, 0.25),
            ("design-system", 820_000_000, 4),
            ("marketing-site", 710_000_000, 47),
            ("api-gateway", 580_000_000, 11),
            ("hackathon-2025", 490_000_000, 139),
            ("docs", 330_000_000, 1),
            ("chrome-extension", 270_000_000, 76),
        ]
        return projects.map {
            NodeModulesFolder(
                path: "/Users/demo/code/\($0.name)/node_modules", projectName: $0.name,
                lastActive: now.addingTimeInterval(-$0.daysIdle * 86_400), bytes: $0.bytes)
        }
    }
}
