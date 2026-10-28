import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'core_api.dart';

class PortInfo {
  const PortInfo(this.path, this.description, this.isUsb, this.isLikelyBridge);
  final String path;
  final String? description;
  final bool isUsb;
  final bool isLikelyBridge;
}

class LampController extends ChangeNotifier {
  LampController({CoreTransport? transport}) {
    try {
      _core = transport ?? CoreApi.open();
      _poll = Timer.periodic(const Duration(milliseconds: 80), (_) => _drain());
      refreshPorts();
    } catch (error) {
      status = '无法加载设备控制内核：$error';
    }
  }

  CoreTransport? _core;
  Timer? _poll;
  bool _autoconnect = true;
  List<PortInfo> ports = [];
  String? selectedPort;
  bool connected = false;
  bool connecting = false;
  bool scanning = false;
  bool pairing = false;
  String? remoteId;
  String status = '正在查找 USB 设备…';
  double brightness = 7;
  double temperature = 7;
  bool brightnessSet = false;
  bool temperatureSet = false;

  bool get canControl => connected && remoteId != null && !scanning && !pairing;

  void _send(Map<String, Object?> request) {
    try {
      _core?.send(jsonEncode(request));
    } catch (error) {
      status = '操作失败：$error';
      notifyListeners();
    }
  }

  void _drain() {
    String? raw;
    var changed = false;
    while ((raw = _core?.nextEvent()) != null) {
      final event = jsonDecode(raw!) as Map<String, dynamic>;
      switch (event['type']) {
        case 'ports':
          ports = (event['ports'] as List<dynamic>).map((item) {
            final port = item as Map<String, dynamic>;
            return PortInfo(
              port['path'] as String,
              port['description'] as String?,
              port['isUsb'] == true,
              port['isLikelyBridge'] == true,
            );
          }).toList();
          if (!ports.any((port) => port.path == selectedPort)) {
            final usb = ports.where((port) => port.isUsb).toList();
            selectedPort = usb.isNotEmpty
                ? usb.first.path
                : (ports.isNotEmpty ? ports.first.path : null);
          }
          if (ports.isEmpty && !connected && !connecting) {
            status = '没有找到串口设备，请插入 RF-Nano 后刷新。';
          }
          final candidates = ports
              .where((port) => port.isLikelyBridge)
              .toList();
          if (_autoconnect &&
              candidates.length == 1 &&
              !connected &&
              !connecting) {
            selectedPort = candidates.single.path;
            connect();
          }
          _autoconnect = false;
          changed = true;
        case 'state':
          connected = event['connected'] == true;
          connecting = event['connecting'] == true;
          scanning = event['scanning'] == true;
          pairing = event['pairing'] == true;
          remoteId = event['remoteId'] as String?;
          status = _statusText(event['status'] as String?);
          changed = true;
        case 'error':
          status = '设备连接或操作失败：${event['message']}';
          changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  String _statusText(String? value) => switch (value) {
    'connecting' => '正在连接 USB 模块…',
    'connected' => 'USB 模块已连接，可以操作挂灯。',
    'awaiting_remote' => '已连接，等待读取遥控器。',
    'scanning' => '正在读取遥控器。请将遥控器靠近模块并按压或转动。',
    'scan_stopped' => '已停止读取遥控器。',
    'remote_saved' => '已读取并保存遥控器编号，可以测试挂灯。',
    'pairing' => '正在发送配对指令…',
    'pair_sent' => '配对指令已发送，请观察挂灯是否闪烁。',
    'sending' => '正在发送控制指令…',
    'sent' => '指令已发送，请观察挂灯的变化。',
    'error' => '设备连接失败，请检查串口、驱动和模块。',
    _ => '设备未连接，请选择串口并连接。',
  };

  void refreshPorts() => _send({'type': 'refresh_ports'});
  void selectPort(String? path) {
    selectedPort = path;
    notifyListeners();
  }

  void connect() {
    final path = selectedPort;
    if (path == null || connecting || connected) return;
    connecting = true;
    status = '正在连接 USB 模块…';
    notifyListeners();
    _send({'type': 'connect', 'path': path});
  }

  void disconnect() => _send({'type': 'disconnect'});
  void scan() => _send({'type': scanning ? 'stop_scan' : 'scan'});
  void pair() => _send({'type': 'pair'});
  void toggle() => _send({'type': 'toggle'});
  void setBrightness(double value) {
    brightness = value.roundToDouble();
    brightnessSet = true;
    notifyListeners();
  }

  void commitBrightness() =>
      _send({'type': 'brightness', 'value': brightness.round()});
  void setTemperature(double value) {
    temperature = value.roundToDouble();
    temperatureSet = true;
    notifyListeners();
  }

  void commitTemperature() =>
      _send({'type': 'temperature', 'value': temperature.round()});

  @override
  void dispose() {
    _poll?.cancel();
    _core?.dispose();
    super.dispose();
  }
}
