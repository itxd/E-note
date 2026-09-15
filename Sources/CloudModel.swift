import Foundation
import CryptoKit

// 作者：韦冬 2220285589@qq.com
indirect enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    static func date(_ value: Date?) -> Self { value.map { .number($0.timeIntervalSince1970) } ?? .null }
    static func uuid(_ value: UUID?) -> Self { value.map { .string($0.uuidString) } ?? .null }
}

struct CloudEntity: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var revision: Int = 0
    var deleted = false
    var payload: [String: JSONValue]
    var comparisonPayload: [String: JSONValue] {
        var p = payload
        // Server allocates account-wide TODO numbers. UUID remains the permanent identity.
        if kind == "todo" { p["number"] = nil }
        p["modifiedAt"] = nil
        p["createdAt"] = nil
        for field in ["dueAt", "deletedAt", "completedAt", "archivedAt", "archiveRestoredAt"] {
            if let value = p[field]?.number { p[field] = .number(floor(value)) }
        }
        return p
    }
    func sameContent(as other: CloudEntity?) -> Bool {
        guard let other = other else { return deleted }
        return kind == other.kind && deleted == other.deleted && (deleted || comparisonPayload == other.comparisonPayload)
    }
}

struct CloudSnapshot: Codable {
    var cursor: Int = 0
    var entities: [CloudEntity] = []
    var workflows: [[String: JSONValue]] = []
    var serverTime: Double = 0
}

struct SyncConflict: Codable, Identifiable {
    var id: String { local.id }
    var local: CloudEntity
    var remote: CloudEntity
    var fields: [String]
}

/// Three-way, per-field merge. Divergent edits are kept for explicit resolution.
/// Deletion vs editing is a conflict; a stale device never silently resurrects deleted data.
enum CloudMerge {
    static func merge(base: CloudEntity?, local: CloudEntity?, remote: CloudEntity?) -> (CloudEntity?, SyncConflict?) {
        guard let remote = remote else { return (local, nil) }
        guard let local = local else {
            guard let base = base, !base.deleted else { return (remote, nil) }
            var tombstone = base; tombstone.deleted = true
            return merge(base: base, local: tombstone, remote: remote)
        }
        if local.sameContent(as: remote) { return (remote, nil) }
        if local.sameContent(as: base) { return (remote, nil) }
        if remote.sameContent(as: base) { var v = local; v.revision = remote.revision; return (v, nil) }
        if local.deleted || remote.deleted {
            return (local, SyncConflict(local: local, remote: remote, fields: ["删除与修改"]))
        }
        var merged = remote
        var conflicts: [String] = []
        let keys = Set(local.comparisonPayload.keys).union(remote.comparisonPayload.keys)
        for key in keys {
            let l = local.payload[key], r = remote.payload[key], b = base?.payload[key]
            if l == r || l == b { continue }
            if r == b { merged.payload[key] = l }
            else { conflicts.append(key) }
        }
        if !conflicts.isEmpty { return (local, SyncConflict(local: local, remote: remote, fields: conflicts.sorted())) }
        merged.payload["modifiedAt"] = .date(Date())
        return (merged, nil)
    }
}

enum LocalProfile {
    static var epoch = UUID()
    private static var marker: URL { AppPaths.supportDir.appendingPathComponent("active-profile") }
    static var current: String = {
        let value = (try? String(contentsOf: marker, encoding: .utf8)) ?? "offline"
        return value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? value : "offline"
    }()
    static func key(server: String, account: String) -> String {
        SHA256.hash(data: Data((server + "|" + account).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func directory(_ profile: String) -> URL {
        if profile == "offline" { return AppPaths.supportDir }
        return AppPaths.supportDir.appendingPathComponent("accounts").appendingPathComponent(profile)
    }
    static var directory: URL { directory(current) }
    static func activate(_ value: String) throws {
        guard NoteStoreIO.atomicWrite(Data(value.utf8), to: marker) else { throw APIError(500, "无法保存账号切换") }
        current = value
        epoch = UUID()
    }
}

/// Public bootstrap metadata only; contains no account credential or registration code.
enum CloudServerDefaults {
    static let server = "https://47.96.175.129:8443"
    static var pin: String {
        guard let url = Bundle.main.url(forResource: "cloud-server", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return "" }
        return json["certificateSHA256"] ?? ""
    }
}
