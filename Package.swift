// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClaudeTOC",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ClaudeTOC",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"], .when(platforms: [.macOS]))
            ]
        ),
    ]
)
