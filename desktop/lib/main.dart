import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import 'lamp_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final desktop = DesktopIntegration();
  await desktop.initialize();
  runApp(LightbarApp(desktop: desktop));
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(390, 640),
      minimumSize: Size(350, 480),
      center: true,
      title: '小米挂灯控制',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

class DesktopIntegration with WindowListener {
  tray.TrayIcon? _icon;
  tray.Image? _image;
  tray.Menu? _menu;
  tray.MenuItem? _showItem;
  tray.MenuItem? _quitItem;

  Future<void> initialize() async {
    try {
      _icon = tray.TrayIcon.create();
      _image = tray.ImageAsset.fromAsset('assets/app_icon.png');
      _menu = tray.Menu.create();
      _showItem = tray.MenuItem.createWithLabelAndType(
        '打开控制面板',
        tray.MenuItemType.normal,
      );
      _quitItem = tray.MenuItem.createWithLabelAndType(
        '退出',
        tray.MenuItemType.normal,
      );
      if (_icon == null ||
          _image == null ||
          _menu == null ||
          _showItem == null ||
          _quitItem == null) {
        return;
      }
      _showItem!.addListener((event) async {
        if (event is tray.MenuItemClickedEvent) await showWindow();
      });
      _quitItem!.addListener((event) async {
        if (event is tray.MenuItemClickedEvent) await quit();
      });
      _menu!.addItem(_showItem);
      _menu!.addSeparator();
      _menu!.addItem(_quitItem);
      _icon!.icon = _image;
      _icon!.setTooltip('小米挂灯控制');
      _icon!.setContextMenu(_menu);
      _icon!.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
      _icon!.addListener((event) async {
        if (event is tray.TrayIconClickedEvent) await showWindow();
      });
      if (!_icon!.setVisible(true)) return;
      // Some Linux desktops do not provide a notification area. Leaving the
      // close button alone keeps the application reachable on those systems.
      if (!Platform.isLinux) {
        await windowManager.setPreventClose(true);
        windowManager.addListener(this);
      }
    } catch (error) {
      debugPrint('Unable to initialize system tray: $error');
    }
  }

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    windowManager.removeListener(this);
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Future<void> onWindowClose() async => windowManager.hide();
}

class LightbarApp extends StatefulWidget {
  const LightbarApp({super.key, required this.desktop, this.controller});
  final DesktopIntegration desktop;
  final LampController? controller;

  @override
  State<LightbarApp> createState() => _LightbarAppState();
}

class _LightbarAppState extends State<LightbarApp> {
  late final controller = widget.controller ?? LampController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xffd78a45);
    return MaterialApp(
      title: '小米挂灯控制',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: accent),
        useMaterial3: true,
        fontFamilyFallback: Platform.isLinux ? const ['NotoSansSC'] : null,
      ),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: const Icon(
                          Icons.lightbulb_outline_rounded,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '屏幕挂灯',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Icon(
                                  Icons.circle,
                                  size: 8,
                                  color: controller.canControl
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _connectionText(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton.filled(
                        tooltip: '切换挂灯开关',
                        onPressed: controller.canControl
                            ? controller.toggle
                            : null,
                        icon: const Icon(Icons.power_settings_new),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    controller.status,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Divider(height: 30),
                  _levelSlider(
                    context,
                    title: '亮度',
                    icon: Icons.wb_sunny_outlined,
                    minimum: '最暗',
                    maximum: '最亮',
                    value: controller.brightness,
                    hasTarget: controller.brightnessSet,
                    onChanged: controller.setBrightness,
                    onChangeEnd: controller.commitBrightness,
                  ),
                  const SizedBox(height: 18),
                  _levelSlider(
                    context,
                    title: '色温',
                    icon: Icons.thermostat_outlined,
                    minimum: '暖',
                    maximum: '冷',
                    value: controller.temperature,
                    hasTarget: controller.temperatureSet,
                    onChanged: controller.setTemperature,
                    onChangeEnd: controller.commitTemperature,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '滑块显示设置目标，遥控器调整不会同步显示。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Divider(height: 30),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text('设备与配对'),
                    initiallyExpanded: !controller.connected,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(controller.selectedPort),
                              initialValue: controller.selectedPort,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '串口设备',
                                isDense: true,
                              ),
                              items: controller.ports
                                  .map(
                                    (port) => DropdownMenuItem(
                                      value: port.path,
                                      child: Text(
                                        port.description == null
                                            ? port.path
                                            : '${port.path} · ${port.description}',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged:
                                  controller.connected || controller.connecting
                                  ? null
                                  : controller.selectPort,
                            ),
                          ),
                          IconButton(
                            tooltip: '刷新设备',
                            onPressed: controller.refreshPorts,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          FilledButton.tonal(
                            onPressed: controller.connecting
                                ? null
                                : (controller.connected
                                      ? controller.disconnect
                                      : controller.connect),
                            child: Text(controller.connected ? '断开' : '连接'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              controller.remoteId == null
                                  ? '尚未设置遥控编号'
                                  : '遥控编号：${controller.remoteId}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed:
                                controller.connected && !controller.pairing
                                ? controller.scan
                                : null,
                            child: Text(controller.scanning ? '停止读取' : '读取遥控器'),
                          ),
                          OutlinedButton(
                            onPressed:
                                controller.connected && !controller.pairing
                                ? () => _showPairing(context)
                                : null,
                            child: const Text('配对电脑…'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: widget.desktop.quit,
                      child: const Text('退出'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _connectionText() {
    if (controller.connecting) return '正在连接';
    if (controller.scanning) return '正在读取遥控器';
    if (controller.connected && controller.remoteId != null) return '已连接';
    if (controller.connected) return '等待遥控器编号';
    return '设备未连接';
  }

  Widget _levelSlider(
    BuildContext context, {
    required String title,
    required IconData icon,
    required String minimum,
    required String maximum,
    required double value,
    required bool hasTarget,
    required ValueChanged<double> onChanged,
    required VoidCallback onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 7),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(
              hasTarget ? '目标 ${value.round() + 1} / 16' : '拖动设置',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        Slider(
          value: value,
          min: 0,
          max: 15,
          divisions: 15,
          onChanged: controller.canControl ? onChanged : null,
          onChangeEnd: controller.canControl ? (_) => onChangeEnd() : null,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(minimum), Text(maximum)],
        ),
      ],
    );
  }

  Future<void> _showPairing(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('配对电脑控制'),
        content: const Text(
          '保持 RF-Nano 已连接。先将挂灯断电再接通，在 10 秒内点击“发送配对”。挂灯闪烁表示配对成功。\n\n这可能替换原遥控器的绑定。重新配对原遥控器后，电脑需要再次读取遥控器编号或重新配对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('发送配对'),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.pair();
  }
}
