import XCTest
import AppKit
@testable import SwitchGPT

final class ProfileImageTests: XCTestCase {
    @MainActor func testRefreshRetriesMissingPhotoAndManualRefreshReloadsChangedPhotoAtTheSameURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(#"{"sub":"profile-test"}"#.utf8).base64EncodedString()
        let credential = try Credential(data: JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt",
            "tokens": ["account_id": "profile-test", "access_token": "synthetic", "refresh_token": "synthetic", "id_token": "h.\(payload).s"]]))
        let session = CodexSession(home: root)
        try session.write(credential)
        func photo(width: Int) throws -> Data {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            for x in 0..<width { bitmap.setColor(.red, atX: x, y: 0) }
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let backend = ProfileBackend(photo: nil)
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"),
            usageClient: UsageClient(send: { try await backend.send($0) }),
            claudeUsageClient: ClaudeUsageClient(answers: { throw SwitchError(message: "synthetic") }),
            session: session, vault: ProfileVault(data: credential.data))
        store.accounts = [Account(id: credential.id, name: "Synthetic", savedAt: .now)]
        await store.refreshUsage()
        XCTAssertNil(store.profileImages[credential.id])
        await backend.replacePhoto(try photo(width: 1))
        await store.refreshUsage()
        XCTAssertEqual(store.profileImages[credential.id]?.size.width, 1)
        await backend.replacePhoto(try photo(width: 2))
        await store.refreshUsage()
        XCTAssertEqual(store.profileImages[credential.id]?.size.width, 1)
        await store.refreshUsage(refreshProfiles: true)
        XCTAssertEqual(store.profileImages[credential.id]?.size.width, 2)
        let requests = await backend.profileRequests
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
    }

    func testProfileImageCredentialsStayOnTrustedOrigin() {
        XCTAssertTrue(UsageClient.isTrustedImageURL(URL(string: "https://chatgpt.com/backend-api/estuary/content?id=example")!))
        for value in ["http://chatgpt.com/image", "https://chatgpt.com.example.org/image", "https://example.org/image", "https://chatgpt.com:444/image", "https://user@chatgpt.com/image"] {
            XCTAssertFalse(UsageClient.isTrustedImageURL(URL(string: value)!), value)
        }
    }
}

private actor ProfileBackend {
    var photo: Data?
    var profileRequests: [URLRequest] = []
    init(photo: Data?) { self.photo = photo }
    func replacePhoto(_ photo: Data) { self.photo = photo }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let data: Data
        if url.path.hasSuffix("profiles/me") {
            profileRequests.append(request)
            data = photo == nil ? Data(#"{"profile":{"profile_picture_url":null}}"#.utf8)
                : Data(#"{"profile":{"profile_picture_url":"https://chatgpt.com/backend-api/estuary/content?id=same"}}"#.utf8)
        } else if url.path.hasSuffix("content") {
            profileRequests.append(request)
            data = try XCTUnwrap(photo)
        } else { data = Data("{}".utf8) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class ProfileVault: CredentialVault {
    var data: Data
    init(data: Data) { self.data = data }
    func read(_ id: String) throws -> Data { data }
    func save(_ data: Data, id: String) throws { self.data = data }
    func remove(_ id: String) throws {}
}
