import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var playbackAudioChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "peercast_app/playback_audio",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    playbackAudioChannel = channel
    channel.setMethodCallHandler { call, result in
      let session = AVAudioSession.sharedInstance()
      do {
        switch call.method {
        case "activate":
          // libmpv needs an active playback session before opening audio output.
          try session.setCategory(.playback, mode: .moviePlayback)
          try session.setActive(true)
          result(nil)
        case "deactivate":
          // Dart stops libmpv before releasing the session.
          try session.setActive(false, options: .notifyOthersOnDeactivation)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(
          code: "audio_session_\(call.method)_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }
}
