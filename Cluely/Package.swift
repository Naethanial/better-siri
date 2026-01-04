// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cluely",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Cluely", targets: ["Cluely"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Cluely",
            dependencies: [
                "KeyboardShortcuts"
            ],
            path: "Sources",
            exclude: ["Resources/Info.plist"]
        )
    ]
)
