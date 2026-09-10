import Foundation

/// One HTTP request per connection; responses explicitly close the connection.
struct RelayRequest {
    static let headerLimit = 65_536
    static let bodyLimit = 64 * 1024 * 1024
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    var isModelRequest: Bool {
        method == "POST" && target.components(separatedBy: "?")[0] == "/backend-api/codex/responses"
    }

    static func parse(_ data: Data) throws -> RelayRequest? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > headerLimit { throw HTTPFailure(status: 431) }
            return nil
        }
        guard split.lowerBound <= headerLimit,
              let text = String(data: data[..<split.lowerBound], encoding: .utf8) else {
            throw HTTPFailure(status: 400)
        }
        var lines = text.components(separatedBy: "\r\n")
        let first = lines.removeFirst().components(separatedBy: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(first[0]) else {
            throw HTTPFailure(status: 405)
        }
        let target = first[1]
        let path = target.components(separatedBy: "?")[0]
        guard path.hasPrefix("/backend-api/codex/"),
              let decoded = path.removingPercentEncoding,
              !decoded.contains(".."), !decoded.contains("\\"), !decoded.contains("//"),
              !target.contains("#") else { throw HTTPFailure(status: 404) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { throw HTTPFailure(status: 400) }
            let name = String(line[..<separator]).lowercased()
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
            }), headers[name] == nil else { throw HTTPFailure(status: 400) }
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        // Browsers must not be able to spend the selected account's quota through localhost.
        guard headers["origin"] == nil else { throw HTTPFailure(status: 403) }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            throw HTTPFailure(status: 400)
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= bodyLimit else {
            throw HTTPFailure(status: 413)
        }
        guard data.count - split.upperBound >= length else { return nil }
        return RelayRequest(method: first[0], target: target, headers: headers,
                            body: Data(data[split.upperBound..<(split.upperBound + length)]))
    }

    func upstreamRequest(baseURL: URL, credentials: RelayCredentials) throws -> URLRequest {
        guard let url = URL(string: target, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.scheme == baseURL.scheme, url.port == baseURL.port else {
            throw HTTPFailure(status: 400)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        let excluded: Set<String> = ["host", "authorization", "chatgpt-account-id", "connection",
                                     "proxy-connection", "proxy-authorization", "transfer-encoding", "content-length",
                                     "accept-encoding", "upgrade", "x-openai-actor-authorization", "cookie"]
        let connectionHeaders = Set((headers["connection"] ?? "").lowercased()
            .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        for (name, value) in headers where !excluded.contains(name) && !connectionHeaders.contains(name) && !name.hasPrefix("sec-websocket-") {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

struct HTTPFailure: Error {
    let status: Int
}
