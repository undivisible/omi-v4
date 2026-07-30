import Foundation
import FoundationModels

let exportMember = "memories_decrypted.json"
let gemma = "google/gemma-3-4b-it"
let flash = "google/gemini-2.5-flash-lite"

func environment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw NSError(domain: "memory-bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) is required"])
    }
    return value
}

func archiveMember(_ archive: String, _ member: String) throws -> Data {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archive, member]
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "memory-bench", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not read \(member)"])
    }
    return output.fileHandleForReading.readDataToEndOfFile()
}

func archiveMembers(_ archive: String) throws -> [String] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", archive]
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n")
        .map(String.init)
        .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
        .prefix(4)
        .map { $0 }
}

func memoryCases(_ data: Data) throws -> [String] {
    guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw NSError(domain: "memory-bench", code: 3, userInfo: [NSLocalizedDescriptionKey: "invalid memory export"])
    }
    return values.compactMap { value in
        guard value["user_review"] as? Bool == true, let content = value["content"] as? String else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (40...320).contains(trimmed.count) ? trimmed : nil
    }.prefix(12).map { $0 }
}

func openRouter(_ key: String, _ model: String, _ messages: [[String: Any]]) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "temperature": 0, "messages": messages])
    let started = Date()
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = value["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any],
          let answer = message["content"] as? String else {
        throw NSError(domain: "memory-bench", code: 4, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
    }
    return ["answer": answer, "latency_ms": Int(Date().timeIntervalSince(started) * 1000), "usage": value["usage"] ?? NSNull()]
}

func localAnswer(_ prompt: String) async -> [String: Any] {
    let started = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: 64))
        return ["answer": response.content, "latency_ms": Int(Date().timeIntervalSince(started) * 1000)]
    } catch {
        return ["error": error.localizedDescription]
    }
}

func answerPrompt(_ citation: String) -> String {
    "Answer using only this cited memory. Be concise. If it does not establish an answer, say insufficient evidence.\n\nCited memory:\n\(citation)\n\nQuestion: What does this tell me about my work or preferences?"
}

Task {
    do {
        let export = try environment("OMI_MEMORY_EXPORT_ZIP")
        let key = try environment("OPENROUTER_API_KEY")
        let report = ProcessInfo.processInfo.environment["OMI_MEMORY_BENCH_REPORT"] ?? "/tmp/omi-memory-bench.json"
        let limit = Int(ProcessInfo.processInfo.environment["OMI_MEMORY_BENCH_LIMIT"] ?? "4") ?? 4
        let cases = Array(try memoryCases(archiveMember(export, exportMember)).prefix(max(1, limit)))
        var memoryResults = [[String: Any]]()
        for citation in cases {
            let prompt = answerPrompt(citation)
            async let local = localAnswer(prompt)
            async let gemmaResult = openRouter(key, gemma, [["role": "user", "content": prompt]])
            async let flashResult = openRouter(key, flash, [["role": "user", "content": prompt]])
            memoryResults.append([
                "citation": citation,
                "foundation": await local,
                "gemma_3_4b": (try? await gemmaResult) ?? ["error": "request failed"],
                "gemini_flash_lite": (try? await flashResult) ?? ["error": "request failed"],
            ])
        }
        var screenshots = [[String: Any]]()
        if let archive = ProcessInfo.processInfo.environment["OMI_SCREENSHOTS_ZIP"] {
            for member in try archiveMembers(archive) {
                let image = try archiveMember(archive, member).base64EncodedString()
                let content: [[String: Any]] = [
                    ["type": "text", "text": "Return concise JSON with visible app, active task, and visible details only."],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)"]],
                ]
                async let gemmaResult = openRouter(key, gemma, [["role": "user", "content": content]])
                async let flashResult = openRouter(key, flash, [["role": "user", "content": content]])
                screenshots.append([
                    "member": member,
                    "gemma_3_4b": (try? await gemmaResult) ?? ["error": "request failed"],
                    "gemini_flash_lite": (try? await flashResult) ?? ["error": "request failed"],
                ])
            }
        }
        let result: [String: Any] = ["memory_cases": memoryResults, "screenshot_cases": screenshots, "models": ["local": "Apple Foundation Models", "gemma": gemma, "flash": flash]]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: report))
        print("{\"report\":\"\(report)\",\"memory_cases\":\(cases.count),\"screenshot_cases\":\(screenshots.count)}")
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
dispatchMain()
