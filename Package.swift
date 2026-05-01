// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ActiveLabel",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17)
    ],
    products: [
        .library(name: "ActiveLabel", targets: ["ActiveLabel"])
    ],
    targets: [
        .target(
            name: "ActiveLabel",
            path: "ActiveLabel",
            exclude: ["Info.plist"]
        )
    ]
)
