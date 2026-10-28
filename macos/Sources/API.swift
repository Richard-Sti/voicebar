import Foundation

struct HTTPError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "HTTP \(status): \(body.prefix(300))" }
}

private func send(_ request: URLRequest, body: Data) async throws -> Data {
    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw HTTPError(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }
    return data
}

/// Phrases Whisper produces from music, noise or silence (it was trained on
/// subtitled video). A transcript consisting only of one is dropped.
private let whisperStockPhrases: Set<String> = [
    "you", "thank you", "thanks", "thank you very much", "thank you so much",
    "thanks for watching", "thank you for watching", "thank you so much for watching",
    "please subscribe", "bye", "subtitles by the amaraorg community",
]

func isLikelyHallucination(_ transcript: String) -> Bool {
    let normalised = transcript.lowercased()
        .filter { $0.isLetter || $0 == " " }
        .split(separator: " ").joined(separator: " ")
    return normalised.isEmpty || whisperStockPhrases.contains(normalised)
}

/// `text` in place of the template's "..." (or "…"), or after the template if it has neither.
func wrap(_ text: String, in template: String) -> String {
    guard let r = template.range(of: "...") ?? template.range(of: "…") else { return template + text }
    return template.replacingCharacters(in: r, with: text)
}

/// Empty wrapper and the number of Left presses to reach its placeholder.
func emptyWrapper(_ template: String) -> (text: String, left: Int) {
    guard let r = template.range(of: "...") ?? template.range(of: "…") else {
        return (template, 0)
    }
    return (wrap("", in: template), template[r.upperBound...].count)
}

/// Whisper transcription through an OpenAI-compatible endpoint (Groq or OpenAI).
struct Transcriber {
    let baseURL: URL
    let apiKey: String
    let model: String
    let language: String
    let prompt: String

    func transcribe(wav: Data) async throws -> String {
        let boundary = "voicebar-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
                .data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "text")
        field("temperature", "0")
        if !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n").data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: body)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
