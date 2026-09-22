import XCTest
import Darwin
@testable import SwitchGPT

func zstdFixture(_ data: Data, unknownSize: Bool = false) throws -> Data {
    typealias Compress = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int, Int32) -> Int
    typealias Bound = @convention(c) (Int) -> Int
    let handle = try XCTUnwrap(dlopen("/opt/homebrew/lib/libzstd.dylib", RTLD_NOW)
        ?? dlopen("/usr/local/lib/libzstd.dylib", RTLD_NOW))
    defer { dlclose(handle) }
    let compress = unsafeBitCast(try XCTUnwrap(dlsym(handle, "ZSTD_compress")), to: Compress.self)
    let bound = unsafeBitCast(try XCTUnwrap(dlsym(handle, "ZSTD_compressBound")), to: Bound.self)
    var encoded = Data(count: bound(data.count))
    let count: Int
    if unknownSize {
        typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
        typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Int
        typealias Parameter = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int
        typealias Compress2 = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
        let create = unsafeBitCast(try XCTUnwrap(dlsym(handle, "ZSTD_createCCtx")), to: Create.self)
        let free = unsafeBitCast(try XCTUnwrap(dlsym(handle, "ZSTD_freeCCtx")), to: Free.self)
        let parameter = unsafeBitCast(try XCTUnwrap(dlsym(handle, "ZSTD_CCtx_setParameter")), to: Parameter.self)
        let compress2 = unsafeBitCast(try XCTUnwrap(dlsym(handle, "ZSTD_compress2")), to: Compress2.self)
        let context = try XCTUnwrap(create())
        defer { _ = free(context) }
        _ = parameter(context, 200, 0) // ZSTD_c_contentSizeFlag
        count = data.withUnsafeBytes { input in
            encoded.withUnsafeMutableBytes { output in compress2(context, output.baseAddress, output.count, input.baseAddress, input.count) }
        }
    } else {
        count = data.withUnsafeBytes { input in
            encoded.withUnsafeMutableBytes { output in compress(output.baseAddress, output.count, input.baseAddress, input.count, 1) }
        }
    }
    XCTAssertLessThanOrEqual(count, encoded.count)
    encoded.count = count
    return encoded
}

final class ZstdRequestBodyTests: XCTestCase {
    func testDecoderRejectsCorruptionAndExpansionBeyondLimit() throws {
        XCTAssertNil(ZstdRequestBody.decode(Data("not zstd".utf8)))
        let plain = Data(repeating: 97, count: 10000)
        let encoded = try zstdFixture(plain)
        XCTAssertEqual(ZstdRequestBody.decode(encoded), plain)
        XCTAssertEqual(ZstdRequestBody.decode(try zstdFixture(plain, unknownSize: true)), plain)
        XCTAssertEqual(ZstdRequestBody.decode(encoded + encoded), plain + plain)
        XCTAssertNil(ZstdRequestBody.decode(encoded.dropLast()))
        XCTAssertNil(ZstdRequestBody.decode(try zstdFixture(Data(repeating: 97, count: ZstdRequestBody.decodedLimit + 1))))
    }

    func testCompressedFallbackPreservesOriginalBodyAndHeaders() async throws {
        let body = try zstdFixture(Data(#"{"model":"gpt-6-astra","reasoning":{"effort":"medium"},"input":"Rename this button"}"#.utf8))
        let request = RelayRequest(method: "POST", target: "/backend-api/codex/responses",
            headers: ["content-encoding": "zstd", "content-length": String(body.count), "thread-id": "fixture"], body: body)
        let disabled = await IntelligentModelRouter().route(request)
        XCTAssertEqual(disabled.request.body, body)
        XCTAssertEqual(disabled.request.headers, request.headers)
        XCTAssertEqual(disabled.decision?.reason, "disabled")
        let router = IntelligentModelRouter(classifier: { _, _ in JevRoutingAnswer(preset: "luna_max", confidence: 0.1) })
        router.update(enabled: true, apiKey: "fixture")
        let kept = await router.route(request)
        XCTAssertEqual(kept.request.body, body)
        XCTAssertEqual(kept.request.headers, request.headers)
        XCTAssertEqual(kept.decision?.reason, "low_confidence")
    }
}
