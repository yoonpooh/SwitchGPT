import Foundation
import Darwin

/// Loads the bundled decoder; development builds may use the build dependency.
/// Decoded input is bounded independently of the compressed HTTP body limit.
enum ZstdRequestBody {
    static let decodedLimit = 8 * 1024 * 1024
    private final class Decoder: @unchecked Sendable {
        typealias Decode = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
        typealias Size = @convention(c) (UnsafeRawPointer?, Int) -> UInt64
        typealias IsError = @convention(c) (Int) -> UInt32
        let handle: UnsafeMutableRawPointer
        let decode: Decode
        let size: Size
        let isError: IsError

        init?() {
            var paths: [String] = []
            if let frameworks = Bundle.main.privateFrameworksURL {
                paths.append(frameworks.appendingPathComponent("libzstd.dylib").path)
            }
            // Packaged apps must never silently depend on a Homebrew installation.
            if Bundle.main.bundleURL.pathExtension != "app" {
                paths += ["/opt/homebrew/lib/libzstd.dylib", "/usr/local/lib/libzstd.dylib"]
            }
            guard let handle = paths.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else { return nil }
            guard let decode = dlsym(handle, "ZSTD_decompress"),
                  let size = dlsym(handle, "ZSTD_getFrameContentSize"),
                  let isError = dlsym(handle, "ZSTD_isError") else { dlclose(handle); return nil }
            self.handle = handle
            self.decode = unsafeBitCast(decode, to: Decode.self)
            self.size = unsafeBitCast(size, to: Size.self)
            self.isError = unsafeBitCast(isError, to: IsError.self)
        }
        deinit { dlclose(handle) }
    }
    private static let decoder = Decoder()

    static func decode(_ data: Data) -> Data? {
        guard !data.isEmpty, let decoder else { return nil }
        return data.withUnsafeBytes { source in
            let declared = decoder.size(source.baseAddress, source.count)
            guard declared != UInt64.max - 1 else { return nil } // invalid frame
            guard declared == UInt64.max || declared <= decodedLimit else { return nil }
            // Reserve the cap for unknown-size or concatenated frames too.
            var result = Data(count: decodedLimit)
            let count = result.withUnsafeMutableBytes { destination in
                decoder.decode(destination.baseAddress, destination.count, source.baseAddress, source.count)
            }
            guard decoder.isError(count) == 0, count <= decodedLimit else { return nil }
            result.count = count
            return result
        }
    }
}
