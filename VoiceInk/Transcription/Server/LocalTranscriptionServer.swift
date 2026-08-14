import Foundation
import Network
import os

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func json(_ object: [String: String], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(string.utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    var statusText: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// Minimal HTTP/1.1 server backed by Network.framework. Handles one request per
/// connection (Connection: close) and delegates each request to an async handler.
final class LocalTranscriptionServer {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let port: NWEndpoint.Port
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.transcriptionserver")
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LocalTranscriptionServer")
    private let maxBodyBytes = 200 * 1024 * 1024
    private var listener: NWListener?

    private static let headerSeparator = Data("\r\n\r\n".utf8)

    init(port: UInt16, handler: @escaping Handler) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 17893
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error = error {
                self.logger.error("Receive error: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }

            var buffer = buffer
            if let data = data { buffer.append(data) }

            guard let headerRange = buffer.range(of: Self.headerSeparator) else {
                if isComplete || buffer.count > self.maxBodyBytes {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
                return
            }

            let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
            guard let parsed = self.parseHead(headerData) else {
                self.respond(connection, .error(400, "Malformed request"))
                return
            }

            let contentLength = Int(parsed.headers["content-length"] ?? "") ?? 0
            if contentLength > self.maxBodyBytes {
                self.respond(connection, .error(413, "Payload too large"))
                return
            }

            let bodyStart = headerRange.upperBound
            let bodyAvailable = buffer.count - bodyStart
            if bodyAvailable < contentLength {
                if isComplete || buffer.count > self.maxBodyBytes {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
                return
            }

            let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            let request = HTTPRequest(method: parsed.method, path: parsed.path, headers: parsed.headers, body: body)

            Task {
                let response = await self.handler(request)
                self.respond(connection, response)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(response.statusText)\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func parseHead(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return (String(components[0]), String(components[1]), headers)
    }
}

/// Parses `multipart/form-data` bodies into their constituent parts.
enum MultipartParser {
    struct Part {
        var name: String?
        var filename: String?
        var contentType: String?
        var body: Data
    }

    static func boundary(fromContentType contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        var value = String(contentType[range.upperBound...])
        if let semicolon = value.firstIndex(of: ";") {
            value = String(value[..<semicolon])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    static func parse(body: Data, boundary: String) -> [Part] {
        let delimiter = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let headerSeparator = Data("\r\n\r\n".utf8)

        var boundaryIndices: [Int] = []
        var searchStart = body.startIndex
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            boundaryIndices.append(range.lowerBound)
            searchStart = range.upperBound
        }
        guard boundaryIndices.count >= 2 else { return [] }

        var parts: [Part] = []
        for index in 0..<(boundaryIndices.count - 1) {
            let segmentStart = boundaryIndices[index] + delimiter.count
            let segmentEnd = boundaryIndices[index + 1]
            guard segmentStart <= segmentEnd else { continue }
            var segment = body.subdata(in: segmentStart..<segmentEnd)

            if segment.starts(with: crlf) {
                segment = segment.subdata(in: (segment.startIndex + crlf.count)..<segment.endIndex)
            }
            if segment.count >= crlf.count, segment.suffix(crlf.count) == crlf {
                segment = segment.subdata(in: segment.startIndex..<(segment.endIndex - crlf.count))
            }
            if segment.starts(with: Data("--".utf8)) { continue }

            guard let headerEnd = segment.range(of: headerSeparator) else { continue }
            let headerText = String(data: segment.subdata(in: segment.startIndex..<headerEnd.lowerBound), encoding: .utf8) ?? ""
            let content = segment.subdata(in: headerEnd.upperBound..<segment.endIndex)

            var part = Part(name: nil, filename: nil, contentType: nil, body: content)
            for line in headerText.components(separatedBy: "\r\n") {
                let lowered = line.lowercased()
                if lowered.hasPrefix("content-disposition:") {
                    part.name = quotedValue(of: "name", in: line)
                    part.filename = quotedValue(of: "filename", in: line)
                } else if lowered.hasPrefix("content-type:") {
                    part.contentType = line.split(separator: ":", maxSplits: 1).last
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                }
            }
            parts.append(part)
        }
        return parts
    }

    private static func quotedValue(of key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[keyRange.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
