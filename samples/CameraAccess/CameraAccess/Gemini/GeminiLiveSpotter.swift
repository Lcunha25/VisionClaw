import Foundation
import UIKit

final class GeminiLiveSpotter {
  private let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 8
    return URLSession(configuration: config)
  }()

  struct SpotterRequestItem: Hashable {
    let id: String
    let name: String
    let aiPrompt: String
    let expectedObjects: [String]
  }

  func detectVisibleItemIDs(
    image: UIImage,
    items: [SpotterRequestItem]
  ) async throws -> [String] {
    guard !items.isEmpty else { return [] }

    guard GeminiConfig.isConfigured else {
      return []
    }

    guard let jpegData = image.jpegData(compressionQuality: 0.55) else {
      return []
    }

    let base64 = jpegData.base64EncodedString()
    let itemHints = items.map {
      [
        "id": $0.id,
        "name": $0.name,
        "ai_prompt": $0.aiPrompt,
        "expected_objects": $0.expectedObjects
      ] as [String: Any]
    }
    let prompt = """
      You are the live SOP brain for an operations execution app.
      Each candidate item has an AI prompt describing what visual completion looks like.
      Expected objects run in parallel with the prompt, but the prompt is the main rule.

      Candidate steps: \(itemHints)

      Look at the image and decide which candidate steps are clearly complete right now.
      Only mark a step complete if the image strongly satisfies that step's ai_prompt.
      If evidence is ambiguous, do not include it.

      Reply ONLY with a valid JSON array of the item IDs you clearly see as complete.
      Example: [\"wallet\", \"thermos\"]
      """

    let payload: [String: Any] = [
      "contents": [
        [
          "parts": [
            ["text": prompt],
            [
              "inline_data": [
                "mime_type": "image/jpeg",
                "data": base64
              ]
            ]
          ]
        ]
      ],
      "generationConfig": [
        "temperature": 0.1,
        "maxOutputTokens": 64,
        "responseMimeType": "application/json"
      ]
    ]

    let model = "models/gemini-2.5-flash-lite"
    let endpoint = "https://generativelanguage.googleapis.com/v1beta/\(model):generateContent?key=\(GeminiConfig.apiKey)"
    guard let url = URL(string: endpoint) else { return [] }

    let data = try JSONSerialization.data(withJSONObject: payload)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data

    let (responseData, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode) else {
      return []
    }

    return parseVisibleIDs(from: responseData, allowedIDs: Set(items.map(\.id)))
  }

  private func parseVisibleIDs(from data: Data, allowedIDs: Set<String>) -> [String] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let candidates = json["candidates"] as? [[String: Any]],
          let first = candidates.first,
          let content = first["content"] as? [String: Any],
          let parts = content["parts"] as? [[String: Any]],
          let text = parts.compactMap({ $0["text"] as? String }).joined(separator: "\n").nonEmpty else {
      return []
    }

    // Try direct JSON array first.
    if let ids = parseJSONArrayIDs(from: text) {
      return ids.filter { allowedIDs.contains($0) }
    }

    // If model wrapped in markdown fences.
    let cleaned = text
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if let ids = parseJSONArrayIDs(from: cleaned) {
      return ids.filter { allowedIDs.contains($0) }
    }

    return []
  }

  private func parseJSONArrayIDs(from raw: String) -> [String]? {
    guard let rawData = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: rawData) as? [String] else {
      return nil
    }

    return array.map {
      $0
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
