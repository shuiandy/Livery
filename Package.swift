// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Livery",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "livery", targets: ["livery"]),
        .executable(name: "LiveryApp", targets: ["LiveryApp"]),
        .executable(name: "LiveryHelper", targets: ["LiveryHelper"]),
    ],
    targets: [
        .target(
            name: "LiveryCore",
            path: "Sources/LiveryCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "livery",
            dependencies: ["LiveryCore"],
            path: "Sources/livery"
        ),
        .executableTarget(
            name: "LiveryApp",
            dependencies: ["LiveryCore"],
            path: "Sources/LiveryApp"
        ),
        .testTarget(
            name: "LiveryCoreTests",
            dependencies: ["LiveryCore"],
            path: "Tests/LiveryCoreTests"
        ),
        .executableTarget(
            name: "LiveryHelper",
            dependencies: ["LiveryCore"],
            path: "Sources/LiveryHelper",
            exclude: ["Info.plist"],
            // A daemon is not a bundle; TCC and System Settings read its identity from an embedded Info.plist, like Replacicon's helper.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "Sources/LiveryHelper/Info.plist"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
