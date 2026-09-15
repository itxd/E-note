import Foundation

// 作者：韦冬 2220285589@qq.com
// API tokens remain local. Cloud credentials are never returned to AI or the bridge.
enum CloudAPIRouter {
    @MainActor static func handle(_ method: String, _ path: String, _ data: Data) async throws -> Any {
        let cloud = CloudSync.shared
        let value: [String: Any]
        if data.isEmpty { value = [:] }
        else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] { value = json }
        else { throw APIError(400, "需要 JSON 对象") }
        if method == "GET", path == "/v1/sync/status" { return cloud.statusJSON() }
        if method == "POST", path == "/v1/sync" {
            try await cloud.sync()
            return cloud.statusJSON()
        }
        if method == "POST", path == "/v1/sync/resolve" {
            guard let id = value["id"] as? String, let choice = value["choice"] as? String else { throw APIError(400, "需要 id、choice") }
            try cloud.resolve(id: id, choice: choice)
            return cloud.statusJSON()
        }
        if method == "POST", path == "/v1/account/login" || path == "/v1/account/register" {
            guard let server = value["server"] as? String, let username = value["username"] as? String,
                  let password = value["password"] as? String else { throw APIError(400, "需要 server、username、password") }
            try await cloud.login(server: server, pin: value["certificateSHA256"] as? String ?? "",
                                  username: username, password: password,
                                  registrationCode: path.hasSuffix("register") ? (value["registrationCode"] as? String ?? "") : nil,
                                  importOffline: value["importOffline"] as? Bool ?? false)
            return cloud.statusJSON()
        }
        if method == "POST", path == "/v1/account/logout" { try await cloud.logout(); return cloud.statusJSON() }
        if method == "GET", path == "/v1/workflows" {
            try await cloud.sync()
            let workflows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cloud.workflows))
            return ["workflows": workflows, "sync": cloud.statusJSON()]
        }
        if method == "POST", path.hasPrefix("/v1/workflows") { return try await cloud.workflow(path, body: value) }
        throw APIError(404, "接口不存在")
    }
}
