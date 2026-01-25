// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterSiri",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "BetterSiri", targets: ["BetterSiri"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
        
    ],
    targets: [
        .executableTarget(
            name: "BetterSiri",
            dependencies: [
                "KeyboardShortcuts"
            ],
            path: "Sources",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources/BrowserAgent"),
                .process("Resources/KaTeX")
            ]
        )
    ]
)
