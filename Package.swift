// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClaudeTOC",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeTOC",
            exclude: [
                "TOC Icon.icon",
                "appicon-1024x1024@1x.png",
                "appicon64@3x.png",
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "ClaudeTOCTests",
            dependencies: ["ClaudeTOC"]
        ),
    ]
)
