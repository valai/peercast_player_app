import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class UpnpException implements Exception {
  const UpnpException(this.message, [this.code]);
  final String message;
  final int? code;
  @override
  String toString() => message;
}

class UpnpGateway {
  const UpnpGateway(this.controlUrl, this.serviceType, this.localAddress);
  final Uri controlUrl;
  final String serviceType, localAddress;
}

String _value(XmlNode node, String name) =>
    node.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == name)
        .map((e) => e.innerText.trim())
        .firstOrNull ??
    '';

/// Discovers IGDs and changes only the TCP mapping explicitly requested by UI.
class UpnpService {
  UpnpService({
    http.Client? client,
    Future<List<UpnpGateway>> Function()? discover,
  }) : _client = client ?? http.Client(),
       _discoverOverride = discover;
  final http.Client _client;
  final Future<List<UpnpGateway>> Function()? _discoverOverride;
  // Restore only together with iOS signing entitlements; see docs/ios-upnp.md.
  static bool get isSupported => defaultTargetPlatform != TargetPlatform.iOS;
  static const unavailableMessage =
      'iOSではUPnPによる自動ポート開放を一時的に無効にしています。ルーターで手動設定してください。';

  static const description = 'PeerCast App';
  static const timeout = Duration(seconds: 5);
  void dispose() => _client.close();

  static Uri? discoveryLocation(String response, InternetAddress sender) {
    if (!response.startsWith('HTTP/1.1 200')) return null;
    for (final line in const LineSplitter().convert(response)) {
      final colon = line.indexOf(':');
      if (colon < 0 || line.substring(0, colon).toLowerCase() != 'location') {
        continue;
      }
      final uri = Uri.tryParse(line.substring(colon + 1).trim());
      // Contact only the responding device, never an unrelated URL.
      if (uri != null &&
          uri.scheme == 'http' &&
          uri.host == sender.address &&
          uri.userInfo.isEmpty) {
        return uri;
      }
    }
    return null;
  }

  static List<UpnpGateway> parseDescription(
    String body,
    Uri location,
    String local,
  ) {
    final document = XmlDocument.parse(body);
    final baseText = _value(document, 'URLBase');
    final base = baseText.isEmpty ? location : location.resolve(baseText);
    final result = <UpnpGateway>[];
    for (final service in document.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'service',
    )) {
      final type = _value(service, 'serviceType');
      if (!RegExp(r'^urn:schemas-upnp-org:service:WAN(IP|PPP)Connection:[12]$')
          .hasMatch(type)) {
        continue;
      }
      final path = _value(service, 'controlURL');
      if (path.isEmpty) continue;
      final url = base.resolve(path);
      if (url.scheme != 'http' ||
          url.host != location.host ||
          url.userInfo.isNotEmpty) {
        continue;
      }
      result.add(UpnpGateway(url, type, local));
    }
    return result;
  }

  Future<List<UpnpGateway>> discover() async {
    if (!isSupported) throw const UpnpException(unavailableMessage);
    if (_discoverOverride != null) return _discoverOverride();
    final locations = <Uri>{};
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.multicastHops = 2;
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        final uri = discoveryLocation(
          utf8.decode(packet!.data, allowMalformed: true),
          packet.address,
        );
        if (uri != null && locations.length < 8) locations.add(uri);
      }
    }, onError: (Object _) {});
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        for (final target in [
          'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
          'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
        ]) {
          socket.send(
            utf8.encode(
              'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: $target\r\n\r\n',
            ),
            InternetAddress('239.255.255.250'),
            1900,
          );
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      socket.close();
      await subscription.cancel();
    }
    final gateways = <UpnpGateway>[];
    for (final location in locations) {
      try {
        // Resolve the outgoing interface instead of guessing the first NIC.
        final route = await Socket.connect(
          location.host,
          location.port,
          timeout: timeout,
        );
        final local = route.address.address;
        route.destroy();
        final response = await _send(
          http.Request('GET', location)..followRedirects = false,
        );
        if (response.statusCode == 200) {
          gateways.addAll(parseDescription(response.body, location, local));
        }
      } catch (_) {
        // Ignore stale discovery responses and try the next device.
      }
    }
    if (gateways.isEmpty) {
      throw const UpnpException(
        'UPnP対応ルーターが見つかりません。Wi-Fi、ルーターのUPnP設定、アプリのローカルネットワーク権限を確認してください。',
      );
    }
    return gateways;
  }

  Future<http.Response> _send(http.BaseRequest request) => (() async {
    final response = await _client.send(request);
    return http.Response.fromStream(response);
  })().timeout(timeout);

  Future<XmlDocument> _action(
    UpnpGateway gateway,
    String action,
    Map<String, String> arguments,
  ) async {
    final builder = XmlBuilder();
    builder.element(
      's:Envelope',
      attributes: {
        'xmlns:s': 'http://schemas.xmlsoap.org/soap/envelope/',
        's:encodingStyle': 'http://schemas.xmlsoap.org/soap/encoding/',
      },
      nest: () {
        builder.element(
          's:Body',
          nest: () {
            builder.element(
              'u:$action',
              attributes: {'xmlns:u': gateway.serviceType},
              nest: () {
                arguments.forEach(
                  (key, value) => builder.element(key, nest: value),
                );
              },
            );
          },
        );
      },
    );
    final request = http.Request('POST', gateway.controlUrl)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPAction': '"${gateway.serviceType}#$action"',
      })
      ..body = builder.buildDocument().toXmlString();
    final response = await _send(request);
    final document = XmlDocument.parse(response.body);
    final code = int.tryParse(_value(document, 'errorCode'));
    if (code != null) {
      throw UpnpException(
        'ルーターが要求を拒否しました (UPnP $code: ${_value(document, 'errorDescription')})',
        code,
      );
    }
    if (response.statusCode != 200 ||
        !document.descendants.whereType<XmlElement>().any(
          (e) => e.name.local == '${action}Response',
        )) {
      throw UpnpException('ルーターから正常な応答がありません (HTTP ${response.statusCode})');
    }
    return document;
  }

  Map<String, String> _key(int port) => {
    'NewRemoteHost': '',
    'NewExternalPort': '$port',
    'NewProtocol': 'TCP',
  };
  Future<XmlDocument?> _mapping(UpnpGateway gateway, int port) async {
    try {
      return await _action(gateway, 'GetSpecificPortMappingEntry', _key(port));
    } on UpnpException catch (e) {
      if (e.code == 714) return null;
      rethrow;
    }
  }

  bool _ours(XmlDocument mapping, UpnpGateway gateway, int port) =>
      _value(mapping, 'NewInternalClient') == gateway.localAddress &&
      _value(mapping, 'NewInternalPort') == '$port' &&
      _value(mapping, 'NewPortMappingDescription') == description;
  Future<String> open(int port) => _change(port, remove: false);
  Future<String> remove(int port) => _change(port, remove: true);

  Future<String> _change(int port, {required bool remove}) async {
    if (port < 1024 || port > 65535) {
      throw const UpnpException('1024〜65535のポートを指定してください');
    }
    final gateways = await discover();
    Object? failure;
    for (final gateway in gateways) {
      try {
        final existing = await _mapping(gateway, port);
        if (existing != null && !_ours(existing, gateway, port)) {
          throw const UpnpException('このTCPポートには別の転送設定があります。別の待受ポートを指定してください。');
        }
        if (remove) {
          if (existing == null) continue;
          await _action(gateway, 'DeletePortMapping', _key(port));
          return 'TCP $port のポート転送を削除しました。';
        }
        await _action(gateway, 'AddPortMapping', {
          ..._key(port),
          'NewInternalPort': '$port',
          'NewInternalClient': gateway.localAddress,
          'NewEnabled': '1',
          'NewPortMappingDescription': description,
          'NewLeaseDuration': '0',
        });
        final registered = await _mapping(gateway, port);
        if (registered == null ||
            !_ours(registered, gateway, port) ||
            !['1', 'true'].contains(_value(registered, 'NewEnabled'))) {
          throw const UpnpException(
            '登録要求は送信しましたが、転送設定を確認できません。ルーターの設定を確認してください。',
          );
        }
        final lease = int.tryParse(_value(registered, 'NewLeaseDuration'));
        final duration = lease == null
            ? '有効期間はルーターの設定を確認してください。'
            : lease == 0
            ? '削除するまで設定を保持します（ルーターの再起動等で失われる場合があります）。'
            : '有効期間は約$lease秒です。期限後は再度開放してください。';
        return 'TCP $port → ${gateway.localAddress}:$port を登録しました。$duration\nSPで外部からの到達を確認してください。';
      } on UpnpException catch (e) {
        // Only unsupported actions may fall through to another IGD service.
        // Never repeat a mutation after a timeout or ambiguous response.
        if (e.code != 401) rethrow;
        failure = e;
      }
    }
    if (failure != null) throw failure;
    if (remove) return 'TCP $port のポート転送は登録されていません。';
    throw const UpnpException('利用できるUPnPサービスがありません。');
  }
}
