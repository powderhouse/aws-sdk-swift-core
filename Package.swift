// swift-tools-version:3.1

import PackageDescription

let package = Package(
    name: "AWSSDKSwiftCore",
    targets: [
        Target(name: "AWSSDKSwiftCore")
    ],
    dependencies: [
        .Package(url: "https://github.com/powderhouse/Prorsum.git", .exactly("0.0.1")),
        .Package(url: "https://github.com/noppoMan/HypertextApplicationLanguage.git", majorVersion: 1)
    ]
)
