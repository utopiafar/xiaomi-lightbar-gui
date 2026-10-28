import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaomi_lightbar_desktop/core_api.dart';
import 'package:xiaomi_lightbar_desktop/lamp_controller.dart';
import 'package:xiaomi_lightbar_desktop/main.dart';

class FakeCore implements CoreTransport {
  final requests = <Map<String, dynamic>>[];
  final events = Queue<String>();

  void event(Map<String, Object?> value) => events.add(jsonEncode(value));

  @override
  void send(String request) =>
      requests.add(jsonDecode(request) as Map<String, dynamic>);

  @override
  String? nextEvent() => events.isEmpty ? null : events.removeFirst();

  @override
  void dispose() {}
}

void main() {
  testWidgets('connects a known bridge and enables controls only after an ID', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeCore();
    final controller = LampController(transport: core);
    final powerButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '切换挂灯开关',
    );
    await tester.pumpWidget(
      LightbarApp(desktop: DesktopIntegration(), controller: controller),
    );

    expect(core.requests.first['type'], 'refresh_ports');
    expect(tester.widget<IconButton>(powerButton).onPressed, isNull);
    core.event({
      'type': 'ports',
      'ports': [
        {
          'path': 'COM3',
          'description': 'USB Serial',
          'isUsb': true,
          'isLikelyBridge': true,
        },
      ],
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.requests.last, {'type': 'connect', 'path': 'COM3'});
    core.event({
      'type': 'state',
      'connected': true,
      'connecting': false,
      'scanning': false,
      'pairing': false,
      'remoteId': '0A:05:F1',
      'status': 'connected',
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<IconButton>(powerButton).onPressed, isNotNull);
    await tester.tap(powerButton);
    expect(core.requests.last, {'type': 'toggle'});
  });

  testWidgets('does not auto-connect when multiple bridges are present', (
    tester,
  ) async {
    final core = FakeCore();
    final controller = LampController(transport: core);
    await tester.pumpWidget(
      LightbarApp(desktop: DesktopIntegration(), controller: controller),
    );
    core.event({
      'type': 'ports',
      'ports': [
        {'path': 'COM3', 'isUsb': true, 'isLikelyBridge': true},
        {'path': 'COM4', 'isUsb': true, 'isLikelyBridge': true},
      ],
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.requests.map((request) => request['type']), ['refresh_ports']);
    expect(controller.selectedPort, 'COM3');
  });

  testWidgets('does not auto-connect to an unrelated USB serial port', (
    tester,
  ) async {
    final core = FakeCore();
    final controller = LampController(transport: core);
    await tester.pumpWidget(
      LightbarApp(desktop: DesktopIntegration(), controller: controller),
    );
    core.event({
      'type': 'ports',
      'ports': [
        {'path': 'COM8', 'isUsb': true, 'isLikelyBridge': false},
      ],
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.requests.map((request) => request['type']), ['refresh_ports']);
    expect(controller.selectedPort, 'COM8');
  });
}
