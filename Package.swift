// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClaudeTOC",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeTOC",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "/dev/null"], .when(platforms: [.macOS]))
            ]
        ),
    ]
)
