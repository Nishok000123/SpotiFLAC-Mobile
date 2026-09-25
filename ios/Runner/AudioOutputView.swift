import AVKit
import Flutter
import UIKit

final class AudioOutputViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        AudioOutputView(frame: frame, id: viewId, messenger: messenger, arguments: args)
    }
}

private final class AudioOutputView: NSObject, FlutterPlatformView, AVRoutePickerViewDelegate {
    private let picker: AVRoutePickerView
    private let channel: FlutterMethodChannel

    init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger, arguments: Any?) {
        picker = AVRoutePickerView(frame: frame)
        channel = FlutterMethodChannel(name: "com.zarz.spotiflac/audio_output/\(id)", binaryMessenger: messenger)
        super.init()
        picker.backgroundColor = .clear
        picker.prioritizesVideoDevices = false
        picker.delegate = self
        update(arguments)
        channel.setMethodCallHandler { [weak self] call, result in
            if call.method == "update" {
                self?.update(call.arguments)
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func update(_ arguments: Any?) {
        guard let values = arguments as? [String: Any] else { return }
        if let value = values["color"] as? NSNumber {
            let argb = value.uint32Value
            picker.tintColor = UIColor(
                red: CGFloat((argb >> 16) & 0xff) / 255,
                green: CGFloat((argb >> 8) & 0xff) / 255,
                blue: CGFloat(argb & 0xff) / 255,
                alpha: CGFloat((argb >> 24) & 0xff) / 255
            )
            picker.activeTintColor = picker.tintColor
        }
        picker.accessibilityLabel = values["label"] as? String
    }

    func view() -> UIView { picker }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        channel.invokeMethod("pickerChanged", arguments: true)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        channel.invokeMethod("pickerChanged", arguments: false)
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }
}
