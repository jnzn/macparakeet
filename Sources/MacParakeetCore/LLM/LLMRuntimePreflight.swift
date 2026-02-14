import Foundation
#if canImport(Metal)
import Metal
#endif

enum LLMRuntimePreflight {
    static func validate() throws {
        #if arch(x86_64)
        throw LLMServiceError.runtimeUnavailable(
            "Qwen local inference requires Apple Silicon."
        )
        #endif

        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw LLMServiceError.runtimeUnavailable(
                "No Metal device is available on this Mac."
            )
        }
        #endif

        guard hasAccessibleMetalLibrary() else {
            throw LLMServiceError.runtimeUnavailable(missingMetalLibraryMessage())
        }
    }

    static func missingMetalLibraryMessage(detail: String? = nil) -> String {
        var parts: [String] = [
            "MLX Metal shaders (`default.metallib`) were not found."
        ]

        if let detail, !detail.isEmpty {
            parts.append(detail)
        }

        if isLikelySwiftPMRun() {
            parts.append(
                "This often happens when running from `swift run` without bundled MLX resources."
            )
            parts.append(
                "Build/run with Xcode or `xcodebuild`, or run the packaged app so `mlx-swift_Cmlx.bundle` is present."
            )
        } else {
            parts.append(
                "Reinstall or rebuild the app to restore `mlx-swift_Cmlx.bundle`."
            )
        }

        return parts.joined(separator: " ")
    }

    private static func hasAccessibleMetalLibrary() -> Bool {
        let fileManager = FileManager.default
        var seen = Set<String>()

        for candidate in metalLibraryCandidates() {
            let path = candidate.path
            if seen.insert(path).inserted && fileManager.fileExists(atPath: path) {
                return true
            }
        }

        return false
    }

    private static func metalLibraryCandidates() -> [URL] {
        var urls: [URL] = []
        let fileManager = FileManager.default

        if let executableURL = Bundle.main.executableURL {
            let binaryDir = executableURL.deletingLastPathComponent()
            urls.append(binaryDir.appendingPathComponent("mlx.metallib"))
            urls.append(binaryDir.appendingPathComponent("Resources/mlx.metallib"))
        }

        // MLX fallback: default.metallib path is relative to process cwd when not absolute.
        let cwdURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        urls.append(cwdURL.appendingPathComponent("default.metallib"))

        // MLX SwiftPM search path:
        //   base + "/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        let swiftPMBundleName = "mlx-swift_Cmlx.bundle"
        urls.append(cwdURL.appendingPathComponent(swiftPMBundleName).appendingPathComponent("Contents/Resources/default.metallib"))

        let baseURLs: [URL] = [Bundle.main.bundleURL] + Bundle.allBundles.compactMap(\.resourceURL)
        for baseURL in baseURLs {
            urls.append(
                baseURL
                    .appendingPathComponent(swiftPMBundleName)
                    .appendingPathComponent("Contents/Resources/default.metallib")
            )
        }

        return urls
    }

    private static func isLikelySwiftPMRun() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        return bundlePath.contains("/.build/") || bundlePath.hasSuffix("/debug")
    }
}
