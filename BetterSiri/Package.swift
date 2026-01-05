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
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2"),
        .package(url: "https://github.com/colinc86/LaTeXSwiftUI", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "BetterSiri",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "LaTeXSwiftUI", package: "LaTeXSwiftUI")
            ],
            path: "Sources",
            exclude: ["Resources/Info.plist"]
        )
    ]
)
