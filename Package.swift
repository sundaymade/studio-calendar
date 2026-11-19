// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StudioCalendar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StudioCalendar", path: "Sources/StudioCalendar")
    ]
)
