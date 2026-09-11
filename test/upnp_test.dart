import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:peercast_app/screens/upnp_screen.dart';
import 'package:peercast_app/services/upnp_service.dart';
import 'package:xml/xml.dart';

const serviceType = 'urn:schemas-upnp-org:service:WANIPConnection:1';
final gateway = UpnpGateway(
  Uri.parse('http://192.168.1.1/control'),
  serviceType,
  '192.168.1.20',
);
http.Response reply(String action, [String values = '']) => http.Response(
  '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
  '<u:${action}Response xmlns:u="$serviceType">$values</u:${action}Response></s:Body></s:Envelope>',
  200,
);
http.Response fault(int code) => http.Response(
  '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>'
  '<detail><UPnPError><errorCode>$code</errorCode><errorDescription>error</errorDescription>'
  '</UPnPError></detail></s:Fault></s:Body></s:Envelope>',
  500,
);
String mapping({
  String address = '192.168.1.20',
  String description = 'PeerCast App',
  String enabled = '1',
  int lease = 0,
}) =>
    '<NewInternalClient>$address</NewInternalClient><NewInternalPort>7145</NewInternalPort>'
    '<NewPortMappingDescription>$description</NewPortMappingDescription><NewEnabled>$enabled</NewEnabled>'
    '<NewLeaseDuration>$lease</NewLeaseDuration>';

void main() {
  test('SSDP headers ignore case and reject unrelated locations', () {
    final sender = InternetAddress('192.168.1.1');
    expect(
      UpnpService.discoveryLocation(
        'HTTP/1.1 200 OK\r\nlOcAtIoN: http://192.168.1.1:5000/root.xml\r\n',
        sender,
      )?.port,
      5000,
    );
    expect(
      UpnpService.discoveryLocation(
        'HTTP/1.1 200 OK\r\nLOCATION: http://example.com/root.xml\r\n',
        sender,
      ),
      isNull,
    );
    expect(
      UpnpService.discoveryLocation(
        'NOTIFY * HTTP/1.1\r\nLOCATION: http://192.168.1.1/root.xml\r\n',
        sender,
      ),
      isNull,
    );
  });

  test(
    'Nested namespaced IGD descriptions support URLBase, PPP and version 2',
    () {
      final result = UpnpService.parseDescription(
        '''
      <d:root xmlns:d="urn:schemas-upnp-org:device-1-0">
      <d:URLBase>http://192.168.1.1:5000/base/</d:URLBase><d:device><d:serviceList>
      <d:service><d:serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</d:serviceType><d:controlURL>ppp</d:controlURL></d:service>
      <d:service><d:serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</d:serviceType><d:controlURL>/ip</d:controlURL></d:service>
      <d:service><d:serviceType>$serviceType</d:serviceType><d:controlURL>http://example.com/control</d:controlURL></d:service>
      </d:serviceList></d:device></d:root>''',
        Uri.parse('http://192.168.1.1/root.xml'),
        gateway.localAddress,
      );
      expect(result.map((e) => e.controlUrl.toString()), [
        'http://192.168.1.1:5000/base/ppp',
        'http://192.168.1.1:5000/ip',
      ]);
    },
  );

  test(
    'Registers TCP mapping and reads it back before reporting success',
    () async {
      final actions = <String>[];
      final service = UpnpService(
        discover: () async => [gateway],
        client: MockClient((request) async {
          final action = request.headers['SOAPAction']!
              .split('#')
              .last
              .replaceAll('"', '');
          actions.add(action);
          expect(request.followRedirects, isFalse);
          expect(request.url, gateway.controlUrl);
          final xml = XmlDocument.parse(request.body);
          expect(xml.findAllElements('NewProtocol').single.innerText, 'TCP');
          expect(
            xml.findAllElements('NewExternalPort').single.innerText,
            '7145',
          );
          if (action == 'AddPortMapping') {
            expect(
              xml.findAllElements('NewInternalClient').single.innerText,
              gateway.localAddress,
            );
            expect(
              xml.findAllElements('NewInternalPort').single.innerText,
              '7145',
            );
            return reply(action);
          }
          return actions.length == 1 ? fault(714) : reply(action, mapping());
        }),
      );
      addTearDown(service.dispose);
      expect(await service.open(7145), contains('登録しました'));
      expect(actions, [
        'GetSpecificPortMappingEntry',
        'AddPortMapping',
        'GetSpecificPortMappingEntry',
      ]);
    },
  );

  for (final remove in [false, true]) {
    for (final existing in [
      mapping(address: '192.168.1.99'),
      mapping(description: 'Other app'),
    ]) {
      test(
        'Does not ${remove ? 'delete' : 'overwrite'} another mapping: $existing',
        () async {
          var calls = 0;
          final service = UpnpService(
            discover: () async => [gateway],
            client: MockClient((request) async {
              calls++;
              return reply('GetSpecificPortMappingEntry', existing);
            }),
          );
          addTearDown(service.dispose);
          await expectLater(
            remove ? service.remove(7145) : service.open(7145),
            throwsA(isA<UpnpException>()),
          );
          expect(calls, 1);
        },
      );
    }
  }

  test('Deletes only the mapping belonging to this client', () async {
    var calls = 0;
    final service = UpnpService(
      discover: () async => [gateway],
      client: MockClient((request) async {
        calls++;
        return calls == 1
            ? reply('GetSpecificPortMappingEntry', mapping())
            : reply('DeletePortMapping');
      }),
    );
    addTearDown(service.dispose);
    expect(await service.remove(7145), contains('削除しました'));
    expect(calls, 2);
  });

  for (final response in [fault(718), http.Response('invalid XML', 500)]) {
    test(
      'Router faults and malformed responses do not report success ${response.body}',
      () async {
        final service = UpnpService(
          discover: () async => [gateway],
          client: MockClient((_) async => response),
        );
        addTearDown(service.dispose);
        await expectLater(service.open(7145), throwsA(isA<Exception>()));
      },
    );
  }

  test('Missing mapping after add is not success', () async {
    final service = UpnpService(
      discover: () async => [gateway],
      client: MockClient(
        (request) async =>
            request.headers['SOAPAction']!.contains('#AddPortMapping')
            ? reply('AddPortMapping')
            : fault(714),
      ),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.open(7145),
      throwsA(
        isA<UpnpException>().having(
          (e) => e.message,
          'message',
          contains('確認できません'),
        ),
      ),
    );
  });

  test('Timeout after mutation does not repeat on another gateway', () async {
    var calls = 0;
    final service = UpnpService(
      discover: () async => [gateway, gateway],
      client: MockClient((_) async {
        calls++;
        if (calls == 1) return fault(714);
        throw TimeoutException('router');
      }),
    );
    addTearDown(service.dispose);
    await expectLater(service.open(7145), throwsA(isA<TimeoutException>()));
    expect(calls, 2);
  });

  test('Invalid port does not discover routers', () async {
    final service = UpnpService(
      discover: () async => throw StateError('must not discover'),
    );
    addTearDown(service.dispose);
    await expectLater(service.open(80), throwsA(isA<UpnpException>()));
  });

  testWidgets('Requires Wi-Fi before discovering', (tester) async {
    final service = FakeService();
    await tester.pumpWidget(
      MaterialApp(
        home: UpnpScreen(
          port: 7145,
          relays: 2,
          service: service,
          checkConnectivity: () async => [ConnectivityResult.mobile],
        ),
      ),
    );
    await tester.tap(find.text('自動でポートを開放'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fiに接続してください。'), findsOneWidget);
    expect(service.calls, 0);
    service.dispose();
  });

  testWidgets('Disables duplicate actions while busy and shows result', (
    tester,
  ) async {
    final service = FakeService();
    await tester.pumpWidget(
      MaterialApp(
        home: UpnpScreen(
          port: 7145,
          relays: 2,
          service: service,
          checkConnectivity: () async => [ConnectivityResult.wifi],
        ),
      ),
    );
    await tester.tap(find.text('自動でポートを開放'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(service.calls, 1);
    service.result.complete('登録成功');
    await tester.pumpAndSettle();
    expect(find.text('登録成功'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    service.dispose();
  });
}

class FakeService extends UpnpService {
  int calls = 0;
  final result = Completer<String>();
  @override
  Future<String> open(int port) {
    calls++;
    return result.future;
  }
}
