import Foundation
import SwiftUI
import os

/// Owns the lifecycle of the LAN transcription server. Because it lives inside the
/// app it starts and stops with VoiceInk; the toggle in Settings controls whether it
/// runs at all. Requests reuse the already-loaded local Whisper model.
@MainActor
final class LocalTranscriptionServerController: ObservableObject {
    static let enabledKey = "NetworkTranscriptionServerEnabled"
    static let portKey = "NetworkTranscriptionServerPort"
    static let defaultPort = 17893

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var logEntries: [ServerLogEntry] = []

    private weak var engine: VoiceInkEngine?
    private var server: LocalTranscriptionServer?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LocalTranscriptionServerController")
    private let maxLogEntries = 500

    init(engine: VoiceInkEngine) {
        self.engine = engine
    }

    struct ServerLogEntry: Identifiable {
        enum Level { case info, success, error }
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    private func appendLog(_ message: String, level: ServerLogEntry.Level = .info) {
        logEntries.append(ServerLogEntry(date: Date(), level: level, message: message))
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
    }

    func clearLog() {
        logEntries.removeAll()
    }

    /// Starts or stops the server to match the persisted toggle/port.
    func applyFromDefaults() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            start()
        } else {
            stop()
        }
    }

    var port: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: Self.portKey)
        return UInt16(raw > 0 && raw <= 65535 ? raw : Self.defaultPort)
    }

    func start() {
        stop()
        let port = self.port
        let server = LocalTranscriptionServer(port: port) { [weak self] request in
            await self?.respond(to: request) ?? .error(503, "Server unavailable")
        }
        do {
            try server.start()
            self.server = server
            isRunning = true
            statusMessage = "Listening on port \(port)"
            appendLog("Server started — listening on port \(port)", level: .success)
            logger.notice("Network transcription server started on port \(port)")
        } catch {
            self.server = nil
            isRunning = false
            statusMessage = "Failed to start: \(error.localizedDescription)"
            appendLog("Failed to start: \(error.localizedDescription)", level: .error)
            logger.error("Failed to start server: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        let wasRunning = server != nil
        server?.stop()
        server = nil
        isRunning = false
        statusMessage = nil
        if wasRunning {
            appendLog("Server stopped")
        }
    }

    // MARK: - Request handling

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        if request.method == "GET" && path == "/" {
            return .text("VoiceInk transcription server\n")
        }

        guard request.method == "POST", path == "/inference" || path == "/v1/audio/transcriptions" else {
            return .error(404, "Not found. POST audio to /inference")
        }

        var audio: Data?
        var fileExtension = "wav"
        var responseFormat = "json"

        let contentType = request.headers["content-type"] ?? ""
        if contentType.hasPrefix("multipart/form-data"), let boundary = MultipartParser.boundary(fromContentType: contentType) {
            for part in MultipartParser.parse(body: request.body, boundary: boundary) {
                if part.filename != nil || part.name == "file" {
                    audio = part.body
                    if let filename = part.filename, let ext = filename.split(separator: ".").last {
                        fileExtension = String(ext)
                    }
                } else if part.name == "response_format", let value = String(data: part.body, encoding: .utf8) {
                    responseFormat = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            }
        } else if !request.body.isEmpty {
            audio = request.body
        }

        guard let audioData = audio, !audioData.isEmpty else {
            appendLog("Rejected request: no audio provided", level: .error)
            return .error(400, "No audio provided. Send multipart/form-data with a 'file' field.")
        }

        appendLog("Request received — \(byteCount(audioData.count)) .\(fileExtension), format: \(responseFormat)")

        do {
            let text = try await transcribe(audioData: audioData, fileExtension: fileExtension)
            appendLog("Transcribed \(text.count) chars: \(preview(of: text))", level: .success)
            if responseFormat == "text" {
                return .text(text)
            }
            return .json(["text": text])
        } catch {
            appendLog("Transcription failed: \(error.localizedDescription)", level: .error)
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            return .error(500, error.localizedDescription)
        }
    }

    private func preview(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(empty)" }
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 280 { return "\"\(oneLine)\"" }
        return "\"\(oneLine.prefix(280))…\""
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Mirrors the file-transcription path in AudioFileTranscriptionManager:
    /// normalize to 16kHz mono samples, write a canonical WAV, then transcribe.
    private func transcribe(audioData: Data, fileExtension: String) async throws -> String {
        guard let engine else { throw ServerError.engineUnavailable }
        guard let model = resolveLocalWhisperModel() else { throw ServerError.noLocalModel }

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let inputURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension.isEmpty ? "wav" : fileExtension)
        try audioData.write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let processor = AudioProcessor()
        let samples = try await processor.processAudioToSamples(inputURL)

        let wavURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try processor.saveSamplesAsWav(samples: samples, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        return try await engine.serviceRegistry.transcribe(audioURL: wavURL, model: model)
    }

    private func resolveLocalWhisperModel() -> (any TranscriptionModel)? {
        guard let engine else { return nil }
        let whisper = engine.whisperModelManager
        let models = engine.transcriptionModelManager

        if let current = models.currentTranscriptionModel,
           current.provider == .whisper,
           whisper.availableModels.contains(where: { $0.name == current.name }) {
            return current
        }

        guard let preferredName = whisper.loadedWhisperModel?.name ?? whisper.availableModels.first?.name else {
            return nil
        }
        return models.allAvailableModels.first { $0.provider == .whisper && $0.name == preferredName }
    }

    enum ServerError: LocalizedError {
        case engineUnavailable
        case noLocalModel

        var errorDescription: String? {
            switch self {
            case .engineUnavailable:
                return "Transcription engine unavailable"
            case .noLocalModel:
                return "No local Whisper model available. Download a Whisper model in VoiceInk first."
            }
        }
    }

    // MARK: - Networking helpers

    /// Best-effort primary IPv4 address for display in Settings.
    static func primaryIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer?.pointee {
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface.ifa_addr,
                                   socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: host)
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return address
    }
}
