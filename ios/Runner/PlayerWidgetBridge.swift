import Flutter
import Foundation
import WidgetKit

@MainActor
final class PlayerWidgetBridge {
    static let shared = PlayerWidgetBridge()
    private var channel: FlutterMethodChannel?
    private var ready = false
    private var pending: [(UUID, String, CheckedContinuation<Bool, Never>)] = []
    private let writer = DispatchQueue(label: "com.zarz.spotiflac.player-widget", qos: .utility)

    func attach(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "com.zarz.spotiflac/player_widget", binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(nil); return }
            switch call.method {
            case "ready":
                self.ready = true
                result(nil)
                self.flush()
            case "update":
                guard let values = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "bad_state", message: "Missing widget state", details: nil))
                    return
                }
                self.writer.async {
                    do {
                        try Self.write(values)
                        WidgetCenter.shared.reloadTimelines(ofKind: PlayerWidgetState.kind)
                        DispatchQueue.main.async { result(nil) }
                    } catch {
                        DispatchQueue.main.async {
                            result(FlutterError(code: "widget_update", message: error.localizedDescription, details: nil))
                        }
                    }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func perform(_ command: String) async -> Bool {
        guard ["play", "pause", "toggle", "previous", "next", "open"].contains(command) else { return false }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            pending.append((id, command, continuation))
            flush()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.finish(id, success: false)
            }
        }
    }

    private var sent = Set<UUID>()

    private func flush() {
        guard ready, let channel else { return }
        for (id, command, _) in pending where !sent.contains(id) {
            sent.insert(id)
            channel.invokeMethod("command", arguments: command) { [weak self] result in
                self?.finish(id, success: result as? Bool == true)
            }
        }
    }

    private func finish(_ id: UUID, success: Bool) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        let entry = pending.remove(at: index)
        sent.remove(id)
        entry.2.resume(returning: success)
    }

    nonisolated private static func write(_ values: [String: Any]) throws {
        guard let directory = PlayerWidgetState.container else {
            throw NSError(domain: "PlayerWidget", code: 1, userInfo: [NSLocalizedDescriptionKey: "Widget App Group is unavailable"])
        }
        let previous = PlayerWidgetState.read()
        var state = PlayerWidgetState()
        state.id = values["id"] as? String ?? ""
        state.title = values["title"] as? String ?? ""
        state.artist = values["artist"] as? String ?? ""
        state.album = values["album"] as? String ?? ""
        state.playing = values["playing"] as? Bool ?? false
        state.canPlay = values["canPlay"] as? Bool ?? false
        state.canPrevious = values["canPrevious"] as? Bool ?? false
        state.canNext = values["canNext"] as? Bool ?? false
        state.background = (values["background"] as? NSNumber)?.uint32Value ?? state.background
        state.artworkKey = values["artworkKey"] as? String ?? ""
        if !state.artworkKey.isEmpty {
            if state.artworkKey == previous.artworkKey, previous.artworkURL != nil {
                state.artworkName = previous.artworkName
            } else if let artwork = values["artwork"] as? FlutterStandardTypedData {
                state.artworkName = "cover-\(UUID().uuidString).png"
                try artwork.data.write(to: directory.appendingPathComponent(state.artworkName), options: .atomic)
            }
        }
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("player.json"), options: .atomic)
        // Retain the current and preceding image while an older timeline is
        // being rendered. The widget never receives the music files.
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if url.lastPathComponent.hasPrefix("cover-"), url.pathExtension == "png",
               url.lastPathComponent != state.artworkName, url.lastPathComponent != previous.artworkName {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
