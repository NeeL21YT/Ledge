// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ledge",
    platforms: [.macOS(.v13)],
    targets: [
        // libwebp 1.5.0, vendored so image conversion needs no system libraries.
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            exclude: ["COPYING", "PATENTS"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .define("NDEBUG")]
        ),
        .executableTarget(name: "Ledge", dependencies: ["CWebP"], path: "Sources/Ledge")
    ]
)
