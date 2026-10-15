import XCTest
@testable import HouseCore

/// Yandex Smart Home: its devices and capabilities in the panel's vocabulary, without the cloud.
@MainActor
final class YandexTests: XCTestCase {
    let lamp: [String: Any] = [
        "id": "lamp-1", "name": "Люстра", "type": "devices.types.light", "room": "r1",
        "capabilities": [
            ["type": "devices.capabilities.on_off", "state": ["instance": "on", "value": true]],
            ["type": "devices.capabilities.range",
             "parameters": ["instance": "brightness", "range": ["min": 1, "max": 100]],
             "state": ["instance": "brightness", "value": 50]],
            ["type": "devices.capabilities.color_setting",
             "parameters": ["color_model": "hsv", "temperature_k": ["min": 2700, "max": 6500]],
             "state": ["instance": "temperature_k", "value": 4000]],
        ],
    ]
    let relay: [String: Any] = [
        "id": "relay-1", "name": "Свет в коридоре", "type": "devices.types.switch",
        "capabilities": [["type": "devices.capabilities.on_off", "state": ["instance": "on", "value": false]]],
    ]
    let ac: [String: Any] = [
        "id": "ac-1", "name": "Кондиционер", "type": "devices.types.thermostat.ac",
        "capabilities": [
            ["type": "devices.capabilities.on_off", "state": ["instance": "on", "value": true]],
            ["type": "devices.capabilities.range",
             "parameters": ["instance": "temperature", "range": ["min": 16, "max": 30]],
             "state": ["instance": "temperature", "value": 23]],
            ["type": "devices.capabilities.mode",
             "parameters": ["instance": "thermostat", "modes": [["value": "cool"], ["value": "heat"], ["value": "fan_only"]]],
             "state": ["instance": "thermostat", "value": "cool"]],
            ["type": "devices.capabilities.mode",
             "parameters": ["instance": "fan_speed", "modes": [["value": "auto"], ["value": "low"], ["value": "high"]]],
             "state": ["instance": "fan_speed", "value": "high"]],
        ],
        "properties": [["type": "devices.properties.float", "parameters": ["instance": "temperature"],
                        "state": ["instance": "temperature", "value": 25.5]]],
    ]

    func testListsLampsRelaysAndAirConditioners() {
        let rooms = ["r1": "Гостиная"]
        let light = YandexService.devices(from: lamp, rooms: rooms)
        XCTAssertEqual(light.first?.kind, .light)
        XCTAssertEqual(light.first?.room, "Гостиная")
        XCTAssertEqual(light.first?.capabilities, ["brightness", "temp", "color"])
        XCTAssertEqual(YandexService.devices(from: relay, rooms: [:]).first?.capabilities, [])
        let climate = YandexService.devices(from: ac, rooms: [:])
        XCTAssertEqual(climate.map(\.kind), [.ac, .sensor])
        XCTAssertEqual(climate.last?.id, "ac-1" + YandexService.sensorSuffix)
        XCTAssertEqual(climate.first?.range?.min, 16)
        XCTAssertTrue(YandexService.devices(from: ["id": "s", "type": "devices.types.smart_speaker",
                                                    "capabilities": [["type": "devices.capabilities.on_off"]]], rooms: [:]).isEmpty)
    }

    func testReadsState() {
        let light = YandexService.reading(from: lamp).light!
        XCTAssertEqual(light["on"] as? Bool, true)
        XCTAssertEqual(light["brightness"] as? Double, 0.5)
        XCTAssertEqual(light["temp"] as? Double, 4000)
        let reading = YandexService.reading(from: ac)
        XCTAssertEqual(reading.ac?["mode"] as? String, "cool")
        XCTAssertEqual(reading.ac?["target"] as? Double, 23)
        XCTAssertEqual(reading.ac?["fan"] as? String, "high")
        XCTAssertEqual(reading.temperature, 25.5)
        XCTAssertEqual(reading.features?["modes"] as? [String], ["cool", "heat", "fan"])
        var offline = relay
        offline["state"] = "offline"
        XCTAssertFalse(YandexService.reading(from: offline).online)
    }

    func testBuildsActions() {
        let off = YandexService.actions(for: lamp, kind: .light, patch: ["on": false], state: [:])
        XCTAssertEqual(off.count, 1)
        let dim = YandexService.actions(for: lamp, kind: .light, patch: ["brightness": 0.3], state: ["on": true])
        XCTAssertEqual(dim.compactMap { ($0["state"] as? [String: Any])?["instance"] as? String }, ["on", "brightness"])
        XCTAssertEqual((dim.last?["state"] as? [String: Any])?["value"] as? Int, 30)
        let red = YandexService.actions(for: lamp, kind: .light, patch: ["color": "#ff0000"], state: ["brightness": 1.0])
        let hsv = (red.first?["state"] as? [String: Any])?["value"] as? [String: Int]
        XCTAssertEqual(hsv, ["h": 0, "s": 100, "v": 100])
        let heat = YandexService.actions(for: ac, kind: .ac, patch: ["mode": "heat", "target": 40.0], state: [:])
        XCTAssertEqual(heat.compactMap { ($0["state"] as? [String: Any])?["value"] as? String }, ["heat"])
        XCTAssertEqual(heat.compactMap { ($0["state"] as? [String: Any])?["value"] as? Double }, [30])
        XCTAssertEqual(YandexService.actions(for: relay, kind: .light, patch: ["brightness": 0.5], state: [:]).count, 0)
    }

    func testCachedStateFollowsActions() {
        let actions = YandexService.actions(for: relay, kind: .light, patch: ["on": true], state: [:])
        let after = YandexService.applying(actions, to: relay)
        XCTAssertEqual(YandexService.reading(from: after).light?["on"] as? Bool, true)
    }
}
