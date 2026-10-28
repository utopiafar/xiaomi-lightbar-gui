# xiaomi-lightbar-mac

[English](README.md) | [简体中文](README.zh-CN.md)

> 跨平台 Flutter 桌面应用正在 [`desktop/`](desktop/README.md) 中开发，
> macOS、Windows 和 Linux 共用 Rust 设备控制内核。下文介绍的原版 macOS
> 应用仍可使用。

一个独立的 macOS 菜单栏工具，用来控制**第一代小米米家显示器挂灯 MJGJD01YL**。通过 USB 连接的 RF-Nano 作为 2.4 GHz 无线桥接器，无需蓝牙、云账号或 Home Assistant。

<img src="assets/app-icon.png" alt="显示器和屏幕挂灯的插画" width="128">

> **早期项目。** 已在一盏真实挂灯上使用已保存的遥控器编号验证开关。遥控器编号读取和滑块指令流程已有串口模拟测试，但尚未在多种真实设备上充分验证。欢迎反馈设备型号和使用结果。

## 功能

- 从 Mac 菜单栏打开控制面板，通过按钮和滑块操作开关、亮度和色温。
- 读取原遥控器的编号并保存到 RF-Nano，让电脑使用相同编号发送指令，无需主动让挂灯重新配对。
- 若无法读取原遥控器，可选择单独的「配对电脑」流程。
- SwiftUI 应用和 Arduino 兼容固件均在本地运行。

挂灯不会向电脑反馈状态。电源按钮是**切换**，不能明确指定开或关。滑块显示的是设置目标，并非灯具实测状态；原遥控器的操作也不会同步到应用。亮度和色温各按 16 档调节，生效可能需要一点时间。

## 准备

| 项目 | 要求 |
| --- | --- |
| 挂灯 | 配圆形 2.4 GHz 遥控器的第一代 MJGJD01YL；本项目不覆盖蓝牙型号。 |
| 无线桥接器 | 带 ATmega328P、nRF24L01 和 CH340 等 USB 串口的 RF-Nano；使用支持数据传输的 USB 线。 |
| 电脑 | 应用的构建目标为 macOS 13 或更新版本；目前在 Apple 芯片 Mac 上构建和测试，其他配置仍需验证。 |
| 构建工具 | 应用需要 Xcode Command Line Tools；固件需要 [PlatformIO Core](https://docs.platformio.org/en/stable/core/installation/index.html)。 |

应用会查找 `/dev/cu.usbserial*` 和 `/dev/cu.wchusbserial*` 设备。部分 RF-Nano 的 nRF24 CE 与 CSN 引脚顺序不同，可查看 [`firmware/src/main.cpp`](firmware/src/main.cpp)。

## 开始使用

运行下面的命令前，先克隆项目并进入目录：

```bash
git clone https://github.com/utopiafar/xiaomi-lightbar-mac.git
cd xiaomi-lightbar-mac
```

### 1. 烧录 RF-Nano 固件

如果设备已经运行本项目固件，可跳到第 2 步。烧录会替换现有固件；如需保留，请先自行备份。安装 PlatformIO Core，连接设备，用 `pio device list` 查找串口，然后执行：

```bash
cd firmware
pio run -e nanoatmega328new
pio run -e nanoatmega328new -t upload --upload-port /dev/cu.usbserial-XXXX
cd ..
```

将示例串口替换为实际串口。如果是旧版 Nano bootloader，在 `firmware/platformio.ini` 中将 `board = nanoatmega328new` 改成 `board = nanoatmega328`，环境名称可不变。若无线模块初始化失败，可能需要交换 CE 和 CSN 引脚。

### 2. 构建并打开 Mac 应用

克隆本仓库，按需安装 Xcode Command Line Tools，然后执行：

```bash
./mac/build-app.sh
open "build/小米挂灯控制.app"
```

脚本会按当前 Mac 的架构构建，并进行本地临时签名；它不是经过 Apple 公证的发行包。如需指定其他输出目录，可把目录作为脚本的第一个参数传入。

### 3. 读取遥控器编号并控制挂灯

1. 保持 RF-Nano 已连接并打开应用。若未找到设备，展开「设备与配对」，选择串口并点击「连接」。
2. 如果没有保存编号，应用会自动开始读取。将原遥控器靠近 RF-Nano，按压或转动遥控器；也可展开「设备与配对」，点击「读取遥控器」。没有读到时可停止后重试。
3. 编号保存成功、应用显示「已连接」后，即可使用电源按钮和滑块。编号保存在 RF-Nano 中，一般无需每次重读；原遥控器仍可使用同一个编号。

关闭启动时的小窗口后，应用仍留在菜单栏；点击面板里的「退出」可完全退出。如果使用了菜单栏图标管理工具，灯泡图标可能被收起。

### 备选：配对电脑

在「设备与配对」中选择「配对电脑」。将挂灯断电后重新接通，在 10 秒内点击「发送配对」；挂灯闪烁表示它接受了配对。此操作可能替换原遥控器的绑定。若要恢复，将挂灯断电重启，并在 20 秒内长按原遥控器，直到挂灯闪烁；之后电脑需要重新读取该遥控器编号或再次配对。

## 常见问题

- **找不到 USB 设备：** 检查数据线和串口驱动，重新插入后点击「连接」。同一时间只让一个程序占用串口。
- **读不到遥控器编号：** 将遥控器靠近、检查电池并重试；无线模块版本和干扰都可能影响接收，不能保证所有设备都能成功读取。
- **指令已发送但灯没有变化：** 确认挂灯型号、电源和保存的编号，把无线模块移近一些。无线协议没有指令确认回执。
- **原遥控器失效：** 可能是使用「配对电脑」时替换了绑定，可按上文重新配对原遥控器。

## 开发与测试

```bash
mkdir -p build
xcrun clang++ -std=c++11 mac/tests/SequenceCounterTest.cpp -o build/sequence-counter-test
./build/sequence-counter-test
xcrun swiftc -swift-version 5 mac/SerialBridge.swift mac/tests/SerialBridgeIntegration.swift -o build/serial-integration-test
python3 mac/tests/serial_simulator.py build/serial-integration-test scan
python3 mac/tests/serial_simulator.py build/serial-integration-test sliders
python3 mac/tests/serial_simulator.py build/serial-integration-test pair
go test ./...
```

串口模拟测试不会向真实挂灯发送指令；Go 检查需要 Go 1.22 或更新版本。可选的 Python 诊断脚本需要 `pyserial`。上游 Go 命令行工具和原始说明保留在 [README.upstream.md](README.upstream.md)。无线数据格式见 [docs/PROTOCOL.zh-CN.md](docs/PROTOCOL.zh-CN.md)（[English](docs/PROTOCOL.md)）。

## 版本与仓库标签

Git 标签 `v0.1.0` 表示首个实验版本，不代表已验证广泛的硬件兼容性。仓库中的 `macos`、`xiaomi`、`nrf24l01`、`swiftui` 等 topics 是方便检索的主题标签，不是版本号。

## 致谢与许可证

本项目基于 [alxndrchernov/auto-lamp](https://github.com/alxndrchernov/auto-lamp)、[lamperez/xiaomi-lightbar-nrf24](https://github.com/lamperez/xiaomi-lightbar-nrf24) 的协议研究，以及 [ebinf/lightbar2mqtt](https://github.com/ebinf/lightbar2mqtt) 的接收帧处理。项目代码采用 MIT 许可证，见 [LICENSE](LICENSE)；相关第三方许可证见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES/)。

项目中提及小米仅用于说明设备兼容性，本项目与小米无隶属或授权关系。应用图标为本项目生成，没有直接使用其官方标志；[候选图说明](assets/icon-candidates/README.md)记录了生成提示。
