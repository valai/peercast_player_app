import 'package:flutter/services.dart';

/// Native runtime detection; unavailable detection retains real-device policy.
class RuntimeEnvironment {
  static const channel = MethodChannel('peercast_app/runtime');

  static Future<bool> isEmulator() async {
    try {
      return await channel.invokeMethod<bool>('isEmulator') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
