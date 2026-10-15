import Foundation

/// Yandex Smart Home (the devices of "Дом с Алисой"), through its official REST API at
/// api.iot.yandex.net with an OAuth token (scopes iot:view + iot:control). Lights, sockets
/// and switches become lamps, `thermostat.ac` devices become air conditioners and anything
/// reporting a temperature can stand in for an AC's room reading.
///
/// The API has no push channel, so while the plan links Yandex devices a light poll
/// (one `user/info` every few seconds) tells the hub when something changed elsewhere —
/// a lamp switched by voice through Alice, say.
@MainActor
public final class YandexService: DeviceService {
    public let id = "yandex"
    public let title = "Yandex"
    public var onChange: (() -> Void)?

    struct Config: Codable {
        var token: String
        var refreshToken: String?
        var clientId: String?
        var clientSecret: String?
        var household: String?
    }

    /// What `beginLogin` hands the editor: a code to type on oauth.yandex.ru/device.
    public struct Login {
        public var deviceCode: String
        public var userCode: String
        public var url: String
        public var interval: Int
        public var expiresIn: Int
    }

    static let api = "https://api.iot.yandex.net/v1.0"
    static let oauth = "https://oauth.yandex.ru"
    /// How often the linked devices are read for changes made elsewhere.
    static let watchInterval: UInt64 = 4_000_000_000

    private let vault: SecretStore
    private var config: Config?
    private let session: URLSession
    /// The last `user/info`, by device id, and when it was read.
    private var catalog: [String: [String: Any]] = [:]
    private var roomNames: [String: String] = [:]
    private var catalogDate = Date.distantPast
    private var watched: Set<String> = []
    private var watcher: Task<Void, Never>?
    private var lastSignature = ""
    /// A login in progress (the client id and secret it was started with).
    private var pending: (clientId: String, clientSecret: String)?

    public init(vault: SecretStore) {
        self.vault = vault
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
        config = vault.read().flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }

    public var isConnected: Bool { config != nil }

    public var info: [String: Any] {
        guard let config else { return ["connected": false] }
        return ["connected": true, "name": config.household ?? "Yandex", "refreshable": config.refreshToken != nil]
    }

    /// For a paired iPhone, like Home Assistant's token.
    public var shareable: [String: Any]? {
        guard let config, let data = try? JSONEncoder().encode(config),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    public func adopt(_ shared: [String: Any]?) {
        guard let shared, let data = try? JSONSerialization.data(withJSONObject: shared.filter { $0.key != "updated" }),
              let incoming = try? JSONDecoder().decode(Config.self, from: data) else {
            if config != nil { disconnect() }
            return
        }
        guard incoming.token != config?.token else { return }
        store(incoming)
    }

    // MARK: - Connecting

    /// Step one of the device flow: Yandex returns a short code the user types on
    /// oauth.yandex.ru/device while signed in, which grants this app its token.
    public func beginLogin(clientId: String, clientSecret: String) async throws -> Login {
        let clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else { throw ServiceFailure("Enter the ClientID of your Yandex OAuth app.") }
        let json = try await form("\(Self.oauth)/device/code", [
            "client_id": clientId, "device_name": "House Control",
        ])
        guard let code = json["device_code"] as? String, let user = json["user_code"] as? String else {
            throw ServiceFailure(Self.oauthError(json) ?? "Yandex did not return a code")
        }
        pending = (clientId, clientSecret)
        return Login(deviceCode: code, userCode: user,
                     url: json["verification_url"] as? String ?? "https://oauth.yandex.ru/device",
                     interval: (json["interval"] as? Int) ?? 5, expiresIn: (json["expires_in"] as? Int) ?? 300)
    }

    /// Step two, asked every few seconds: true once the user has confirmed the code.
    public func finishLogin(deviceCode: String) async throws -> Bool {
        guard let pending else { throw ServiceFailure("Start the sign-in again.") }
        var body = ["grant_type": "device_code", "code": deviceCode, "client_id": pending.clientId]
        if !pending.clientSecret.isEmpty { body["client_secret"] = pending.clientSecret }
        let json = try await form("\(Self.oauth)/token", body)
        if let token = json["access_token"] as? String {
            try await adoptToken(Config(token: token, refreshToken: json["refresh_token"] as? String,
                                        clientId: pending.clientId, clientSecret: pending.clientSecret.isEmpty ? nil : pending.clientSecret))
            self.pending = nil
            return true
        }
        switch json["error"] as? String {
        case "authorization_pending", "slow_down": return false
        case "invalid_client": throw ServiceFailure("Yandex does not know this ClientID / Client secret pair.")
        case "invalid_grant", "expired_token": throw ServiceFailure("The code expired. Start again.")
        default: throw ServiceFailure(Self.oauthError(json) ?? "Yandex refused the sign-in")
        }
    }

    /// A token obtained some other way (oauth.yandex.ru/authorize?response_type=token…).
    public func connect(token raw: String) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "OAuth ", with: "").replacingOccurrences(of: "Bearer ", with: "")
        guard !token.isEmpty else { throw ServiceFailure("Paste an OAuth token with the iot:view and iot:control rights.") }
        try await adoptToken(Config(token: token))
    }

    private func adoptToken(_ candidate: Config) async throws {
        var candidate = candidate
        let info = try await request("GET", "/user/info", config: candidate)
        let households = info["households"] as? [[String: Any]] ?? []
        candidate.household = households.first?["name"] as? String
        store(candidate)
        absorb(info)
    }

    private func store(_ new: Config?) {
        config = new
        vault.write(new.flatMap { try? JSONEncoder().encode($0) })
        restartWatcher()
    }

    public func watch(_ ids: Set<String>) {
        watched = ids
        restartWatcher()
    }

    public func disconnect() {
        store(nil)
        catalog = [:]
        roomNames = [:]
        pending = nil
    }

    // MARK: - Devices

    public func devices() async throws -> [ServiceDevice] {
        try await refreshCatalog(maxAge: 0)
        return catalog.values.flatMap { Self.devices(from: $0, rooms: roomNames) }
            .sorted { ($0.kind.rawValue, $0.room ?? "", $0.name) < ($1.kind.rawValue, $1.room ?? "", $1.name) }
    }

    public func read(_ ids: Set<String>) async throws -> [String: DeviceReading] {
        guard !ids.isEmpty else { return [:] }
        try await refreshCatalog(maxAge: 1.5)
        var out: [String: DeviceReading] = [:]
        for id in ids {
            let deviceId = Self.baseId(id)
            guard let device = catalog[deviceId] else { continue }
            out[id] = Self.reading(from: device)
        }
        return out
    }

    public func send(kind: DeviceKind, id: String, patch: [String: Any], state: [String: Any]) async throws {
        let deviceId = Self.baseId(id)
        if catalog[deviceId] == nil { try await refreshCatalog(maxAge: 0) }
        guard let device = catalog[deviceId] else { throw ServiceFailure("Yandex no longer has this device") }
        let actions = Self.actions(for: device, kind: kind, patch: patch, state: state)
        guard !actions.isEmpty else { return }
        let result = try await request("POST", "/devices/actions", body: ["devices": [["id": deviceId, "actions": actions]]])
        if let failure = Self.actionFailure(result) { throw ServiceFailure(failure) }
        // Keep the cached copy in step, so a read right after does not undo the change.
        catalog[deviceId] = Self.applying(actions, to: device)
    }

    private func refreshCatalog(maxAge: TimeInterval) async throws {
        guard Date().timeIntervalSince(catalogDate) > maxAge || catalog.isEmpty else { return }
        absorb(try await request("GET", "/user/info"))
    }

    private func absorb(_ info: [String: Any]) {
        var devices: [String: [String: Any]] = [:]
        for device in info["devices"] as? [[String: Any]] ?? [] {
            if let id = device["id"] as? String { devices[id] = device }
        }
        var rooms: [String: String] = [:]
        for room in info["rooms"] as? [[String: Any]] ?? [] {
            if let id = room["id"] as? String, let name = room["name"] as? String { rooms[id] = name }
        }
        catalog = devices
        roomNames = rooms
        catalogDate = Date()
    }

    // MARK: - Watching for changes made elsewhere (Alice, the Yandex app, a wall switch)

    private func restartWatcher() {
        watcher?.cancel()
        watcher = nil
        guard config != nil, !watched.isEmpty else { return }
        lastSignature = signature()
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.watchInterval)
                guard !Task.isCancelled, let self else { return }
                guard (try? await self.refreshCatalog(maxAge: 1)) != nil else { continue }
                let now = self.signature()
                if now != self.lastSignature {
                    self.lastSignature = now
                    self.onChange?()
                }
            }
        }
    }

    /// The states of the watched devices, as one comparable string.
    private func signature() -> String {
        watched.map(Self.baseId).sorted().map { id -> String in
            guard let device = catalog[id] else { return id }
            let states = (device["capabilities"] as? [[String: Any]] ?? []).map { "\($0["type"] ?? ""):\(Self.describe(($0["state"] as? [String: Any])?["value"]))" }
            let props = (device["properties"] as? [[String: Any]] ?? []).map { "\(Self.describe(($0["state"] as? [String: Any])?["value"]))" }
            return id + "|" + (device["state"] as? String ?? "") + "|" + (states + props).joined(separator: ",")
        }.joined(separator: ";")
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "-" }
        if let dict = value as? [String: Any] { return dict.keys.sorted().map { "\($0)=\(dict[$0] ?? "")" }.joined(separator: "&") }
        return "\(value)"
    }

    // MARK: - Mapping (static, so the tests can run it without the cloud)

    /// A temperature sensor that is also something else (an AC, a humidifier) is listed a
    /// second time as a sensor, under this suffix.
    static let sensorSuffix = "#temperature"
    static func baseId(_ id: String) -> String {
        id.hasSuffix(sensorSuffix) ? String(id.dropLast(sensorSuffix.count)) : id
    }

    static func capability(_ device: [String: Any], _ type: String, instance: String? = nil) -> [String: Any]? {
        (device["capabilities"] as? [[String: Any]] ?? []).first { cap in
            guard cap["type"] as? String == "devices.capabilities.\(type)" else { return false }
            guard let instance else { return true }
            let params = cap["parameters"] as? [String: Any] ?? [:]
            let state = cap["state"] as? [String: Any] ?? [:]
            return (params["instance"] as? String ?? state["instance"] as? String) == instance
        }
    }

    static func property(_ device: [String: Any], _ instance: String) -> [String: Any]? {
        (device["properties"] as? [[String: Any]] ?? []).first {
            ($0["parameters"] as? [String: Any])?["instance"] as? String == instance
        }
    }

    static func isOnline(_ device: [String: Any]) -> Bool {
        (device["state"] as? String) != "offline"
    }

    /// Types never shown as lamps even though they switch on and off.
    static let ignoredTypes = ["devices.types.media_device", "devices.types.smart_speaker", "devices.types.camera"]

    static func devices(from device: [String: Any], rooms: [String: String]) -> [ServiceDevice] {
        guard let id = device["id"] as? String else { return [] }
        let type = device["type"] as? String ?? ""
        let name = device["name"] as? String ?? id
        let room = (device["room"] as? String).flatMap { rooms[$0] }
        let short = type.replacingOccurrences(of: "devices.types.", with: "")
        var out: [ServiceDevice] = []

        if type.hasPrefix("devices.types.thermostat.ac") || type == "devices.types.thermostat" {
            var ac = ServiceDevice(id: id, name: name, kind: .ac, room: room)
            if let range = (capability(device, "range", instance: "temperature")?["parameters"] as? [String: Any])?["range"] as? [String: Any],
               let lo = range.double("min"), let hi = range.double("max") {
                ac.range = (max(lo, 10), min(hi, 32))
            }
            let modes = modeValues(device, "thermostat")
            ac.detail = short + (modes.isEmpty ? "" : " · " + modes.joined(separator: ", "))
            ac.online = isOnline(device)
            out.append(ac)
        } else if !type.hasPrefix("devices.types.sensor"), !ignoredTypes.contains(where: { type.hasPrefix($0) }),
                  capability(device, "on_off") != nil {
            var light = ServiceDevice(id: id, name: name, kind: .light, room: room)
            light.capabilities = lightCapabilities(device)
            light.detail = short + " · " + (light.capabilities.isEmpty ? "on/off" : light.capabilities.joined(separator: ", "))
            light.online = isOnline(device)
            out.append(light)
        }

        if property(device, "temperature") != nil {
            // A plain sensor keeps its own id; a device that is also an AC or a lamp gets a suffix.
            var sensor = ServiceDevice(id: out.isEmpty ? id : id + sensorSuffix, name: name, kind: .sensor, room: room)
            sensor.detail = out.isEmpty ? "\(short) · temperature" : "temperature of \(short)"
            sensor.online = isOnline(device)
            out.append(sensor)
        }
        return out
    }

    static func lightCapabilities(_ device: [String: Any]) -> [String] {
        var caps: [String] = []
        if capability(device, "range", instance: "brightness") != nil { caps.append("brightness") }
        let color = capability(device, "color_setting")?["parameters"] as? [String: Any] ?? [:]
        if color["temperature_k"] != nil { caps.append("temp") }
        if color["color_model"] != nil { caps.append("color") }
        return caps
    }

    static func modeValues(_ device: [String: Any], _ instance: String) -> [String] {
        let params = capability(device, "mode", instance: instance)?["parameters"] as? [String: Any] ?? [:]
        return (params["modes"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
    }

    static func state(_ cap: [String: Any]?) -> Any? {
        (cap?["state"] as? [String: Any])?["value"]
    }

    /// The panel's AC modes and Yandex's thermostat values for them.
    static func modeTable(_ values: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for (panel, names) in [("cool", ["cool"]), ("heat", ["heat"]), ("dry", ["dry"]),
                               ("fan", ["fan_only"]), ("auto", ["auto", "heat_cool"])] {
            if let name = names.first(where: values.contains) { out[panel] = name }
        }
        return out
    }

    static func reading(from device: [String: Any]) -> DeviceReading {
        var reading = DeviceReading(online: isOnline(device))
        if let t = (property(device, "temperature")?["state"] as? [String: Any])?.double("value") { reading.temperature = t }
        guard reading.online else { return reading }
        let type = device["type"] as? String ?? ""
        let on = state(capability(device, "on_off")) as? Bool

        if type.hasPrefix("devices.types.thermostat") {
            var ac: [String: Any] = [:]
            if let on { ac["on"] = on }
            let modes = modeTable(modeValues(device, "thermostat"))
            if let current = state(capability(device, "mode", instance: "thermostat")) as? String,
               let mode = modes.first(where: { $0.value == current })?.key { ac["mode"] = mode }
            if let t = (capability(device, "range", instance: "temperature")?["state"] as? [String: Any])?.double("value") { ac["target"] = t }
            if let room = reading.temperature { ac["roomTemp"] = room }
            let fans = FanNames.table(modeValues(device, "fan_speed"))
            if let current = state(capability(device, "mode", instance: "fan_speed")) as? String,
               let fan = FanNames.panel(current), fans[fan] != nil { ac["fan"] = fan }
            let swings = modeValues(device, "swing")
            if let swing = state(capability(device, "mode", instance: "swing")) as? String, swings.count > 1 {
                ac["swing"] = swing == "stationary" ? "off" : "swing"
            }
            reading.ac = ac
            reading.features = [
                "modes": ["cool", "heat", "dry", "fan", "auto"].filter { modes[$0] != nil },
                "fans": FanNames.order.filter { fans[$0] != nil },
                "swing": swings.contains("stationary") && swings.count > 1,
                "sleep": false, "eco": false,
            ]
            return reading
        }

        guard let on else { return reading }
        var light: [String: Any] = ["on": on]
        if let b = (capability(device, "range", instance: "brightness")?["state"] as? [String: Any])?.double("value") {
            light["brightness"] = max(0.05, min(1, b / 100))
        }
        if let color = capability(device, "color_setting")?["state"] as? [String: Any] {
            switch color["instance"] as? String {
            case "temperature_k":
                if let k = color.double("value") { light["temp"] = max(2200, min(6500, k)); light["color"] = NSNull() }
            case "rgb":
                if let v = color.double("value") {
                    let n = Int(v)
                    light["color"] = ColorMath.hex(r: Double((n >> 16) & 0xFF) / 255, g: Double((n >> 8) & 0xFF) / 255, b: Double(n & 0xFF) / 255)
                }
            case "hsv":
                if let hsv = color["value"] as? [String: Any], let hue = hsv.double("h"), let s = hsv.double("s") {
                    light["color"] = ColorMath.hex(hue: hue, saturation: s / 100)
                }
            default: break
            }
        }
        reading.light = light
        return reading
    }

    /// The `actions` of one device for a change made in the panel.
    static func actions(for device: [String: Any], kind: DeviceKind, patch: [String: Any], state: [String: Any]) -> [[String: Any]] {
        func action(_ type: String, _ instance: String, _ value: Any) -> [String: Any] {
            ["type": "devices.capabilities.\(type)", "state": ["instance": instance, "value": value]]
        }
        func clamp(_ v: Double, _ cap: [String: Any]?) -> Double {
            let range = (cap?["parameters"] as? [String: Any])?["range"] as? [String: Any] ?? [:]
            return min(range.double("max") ?? v, max(range.double("min") ?? v, v))
        }
        var out: [[String: Any]] = []
        let on = patch["on"] as? Bool

        if kind == .ac {
            if on == false { return [action("on_off", "on", false)] }
            if on == true || patch["mode"] != nil, capability(device, "on_off") != nil { out.append(action("on_off", "on", true)) }
            if let mode = patch["mode"] as? String, let name = modeTable(modeValues(device, "thermostat"))[mode] {
                out.append(action("mode", "thermostat", name))
            }
            if let t = patch["target"] as? Double {
                let cap = capability(device, "range", instance: "temperature")
                if cap != nil { out.append(action("range", "temperature", clamp(t, cap))) }
            }
            if let fan = patch["fan"] as? String, let name = FanNames.table(modeValues(device, "fan_speed"))[fan] {
                out.append(action("mode", "fan_speed", name))
            }
            if let swing = patch["swing"] as? String {
                let values = modeValues(device, "swing")
                let name = swing == "off" ? "stationary" : (values.first { $0 != "stationary" } ?? "auto")
                if values.contains(name) { out.append(action("mode", "swing", name)) }
            }
            return out
        }

        // A lamp, a socket or a switch.
        if on == false { return [action("on_off", "on", false)] }
        let lit = DeviceKind.withPower(patch, state: state)
        if lit["on"] as? Bool == true { out.append(action("on_off", "on", true)) }
        if let b = lit["brightness"] as? Double {
            let cap = capability(device, "range", instance: "brightness")
            if cap != nil { out.append(action("range", "brightness", Int(clamp((b * 100).rounded(), cap)))) }
        }
        let color = capability(device, "color_setting")?["parameters"] as? [String: Any] ?? [:]
        if let k = lit["temp"] as? Double, let range = color["temperature_k"] as? [String: Any] {
            let value = min(range.double("max") ?? k, max(range.double("min") ?? k, k))
            out.append(action("color_setting", "temperature_k", Int(value)))
        }
        if let hex = lit["color"] as? String, let model = color["color_model"] as? String {
            if model == "hsv", let (h, s, _) = ColorMath.hsv(hex) {
                let v = Int(((state.double("brightness") ?? 1) * 100).rounded())
                out.append(action("color_setting", "hsv", ["h": Int(h.rounded()), "s": Int((s * 100).rounded()), "v": max(1, v)]))
            } else if let (r, g, b) = ColorMath.rgb(hex) {
                let value = (Int((r * 255).rounded()) << 16) | (Int((g * 255).rounded()) << 8) | Int((b * 255).rounded())
                out.append(action("color_setting", "rgb", value))
            }
        }
        return out
    }

    /// The first failed action in a `devices/actions` answer, as a sentence.
    static func actionFailure(_ result: [String: Any]) -> String? {
        for device in result["devices"] as? [[String: Any]] ?? [] {
            for cap in device["capabilities"] as? [[String: Any]] ?? [] {
                let outcome = (cap["state"] as? [String: Any])?["action_result"] as? [String: Any] ?? [:]
                if outcome["status"] as? String == "ERROR" {
                    let code = outcome["error_code"] as? String ?? "ERROR"
                    let message = outcome["error_message"] as? String
                    return code == "DEVICE_UNREACHABLE" ? "The device is offline" : message ?? "Yandex: \(code)"
                }
            }
        }
        return nil
    }

    /// The device as it will be once `actions` are applied.
    static func applying(_ actions: [[String: Any]], to device: [String: Any]) -> [String: Any] {
        var device = device
        var caps = device["capabilities"] as? [[String: Any]] ?? []
        for action in actions {
            guard let type = action["type"] as? String, let new = action["state"] as? [String: Any] else { continue }
            let instance = new["instance"] as? String
            let colour = type == "devices.capabilities.color_setting"
            if let i = caps.firstIndex(where: { cap in
                guard cap["type"] as? String == type else { return false }
                if colour { return true }
                let params = cap["parameters"] as? [String: Any] ?? [:]
                return params["instance"] as? String == nil || params["instance"] as? String == instance
            }) {
                caps[i]["state"] = new
            }
        }
        device["capabilities"] = caps
        return device
    }

    static func oauthError(_ json: [String: Any]) -> String? {
        (json["error_description"] as? String) ?? (json["error"] as? String)
    }

    // MARK: - HTTP

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         config explicit: Config? = nil, retried: Bool = false) async throws -> [String: Any] {
        guard let config = explicit ?? self.config, let url = URL(string: Self.api + path) else {
            throw ServiceFailure("Connect Yandex first")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceFailure("Yandex did not answer: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300:
            return json
        case 401, 403:
            if explicit == nil, !retried, try await renew() {
                return try await self.request(method, path, body: body, retried: true)
            }
            throw ServiceFailure("Yandex refused the token (\(status)). It needs the iot:view and iot:control rights; sign in again.")
        default:
            let text = json["message"] as? String ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw ServiceFailure("Yandex answered \(status) \(text)")
        }
    }

    /// Swaps the refresh token for a new access token. False when there is no way to.
    private func renew() async throws -> Bool {
        guard var current = config, let refresh = current.refreshToken, let clientId = current.clientId else { return false }
        var body = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientId]
        if let secret = current.clientSecret { body["client_secret"] = secret }
        let json = try await form("\(Self.oauth)/token", body)
        guard let token = json["access_token"] as? String else { return false }
        current.token = token
        if let next = json["refresh_token"] as? String { current.refreshToken = next }
        store(current)
        return true
    }

    /// A form POST to oauth.yandex.ru; answers with the JSON whatever the status.
    private func form(_ address: String, _ fields: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw ServiceFailure("Bad address \(address)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw ServiceFailure("oauth.yandex.ru did not answer: \(error.localizedDescription)")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
