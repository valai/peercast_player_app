/// Apply before opening media, never during keyboard/layout changes.
Future<void> configureNativePlayback(
  Future<void> Function(String name, String value) setProperty, {
  required bool silentSimulator,
}) async {
  await setProperty('cache-on-disk', 'no');
  // Keep audio as the clock; rendering delays must not retime the sound.
  await setProperty('video-sync', 'audio');
  // A bounded cushion for short UI/WebView load spikes (mpv default: 0.2 s).
  // This may delay software volume changes; verify on physical devices.
  await setProperty('audio-buffer', '0.5');
  if (silentSimulator) {
    // The bundled simulator libmpv has no audio output driver.
    // Do not override the real device's automatically selected output.
    await setProperty('ao', 'null');
  }
}
