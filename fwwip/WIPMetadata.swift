import Foundation

/// Optional, explicitly authored memo properties. This personal panel's action recipient is David.
nonisolated struct WIPMetadata: Decodable, Sendable {
    let update: String?
    let occurredAt: String?
    let verifiedAt: String?
    let evidenceURL: String?
    let needsUser: Bool?
    let actionReason: String?
    let actionRecipient: String?
    let conversationURL: String?
    let conversationVerifiedAt: String?

    var isPresent: Bool {
        update != nil || occurredAt != nil || verifiedAt != nil || evidenceURL != nil || needsUser != nil ||
        actionReason != nil || actionRecipient != nil || conversationURL != nil || conversationVerifiedAt != nil
    }

    private enum CodingKeys: String, CodingKey {
        case update = "wip_update", occurredAt = "wip_occurred_at", verifiedAt = "wip_verified_at"
        case evidenceURL = "wip_evidence_url", needsUser = "wip_needs_user"
        case actionReason = "wip_action_reason", actionRecipient = "wip_action_recipient"
        case conversationURL = "wip_conversation_url", conversationVerifiedAt = "wip_conversation_verified_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        update = try? c.decode(String.self, forKey: .update)
        occurredAt = try? c.decode(String.self, forKey: .occurredAt)
        verifiedAt = try? c.decode(String.self, forKey: .verifiedAt)
        evidenceURL = try? c.decode(String.self, forKey: .evidenceURL)
        needsUser = try? c.decode(Bool.self, forKey: .needsUser)
        actionReason = try? c.decode(String.self, forKey: .actionReason)
        actionRecipient = try? c.decode(String.self, forKey: .actionRecipient)
        conversationURL = try? c.decode(String.self, forKey: .conversationURL)
        conversationVerifiedAt = try? c.decode(String.self, forKey: .conversationVerifiedAt)
    }

    struct Projection {
        var update: MeaningfulUpdate?
        var attention: Attention = .unknown
        var verifiedAt: Date?
        var evidenceURL: URL?
        var conversationURL: URL?
    }

    func projected(now: Date) -> Projection {
        var result = Projection()
        if let verified = Self.timestamp(verifiedAt), verified <= now,
           let evidence = Self.httpsURL(evidenceURL) {
            result.verifiedAt = verified
            result.evidenceURL = evidence
            if let text = Self.text(update), let occurred = Self.timestamp(occurredAt), occurred <= verified {
                result.update = MeaningfulUpdate(text: text, occurredAt: occurred, source: evidence.absoluteString)
            }
            if Self.text(actionRecipient) == "David", let needed = needsUser,
               let reason = Self.text(actionReason) {
                result.attention = needed ? .needsYou(reason) : .noAction(reason)
            }
        }
        if let verified = Self.timestamp(conversationVerifiedAt), verified <= now,
           let url = Self.httpsURL(conversationURL) {
            result.conversationURL = url
        }
        return result
    }

    private static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 1000 else { return nil }
        return clean
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value, value.count <= 40 else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }

    private static func httpsURL(_ value: String?) -> URL? {
        guard let value, value.count <= 2048, !value.contains(where: { $0.isWhitespace }),
              let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
}
