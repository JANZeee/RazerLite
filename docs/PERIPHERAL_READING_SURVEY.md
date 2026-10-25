# 外设读取机制简要调研

调研日期：2026-10-18。范围为公开文档和源码阅读，未安装、运行第三方驱动，也未向设备发送新指令。本报告区分已经看到的实现和对 RazerLite 的设计建议；这些参考不构成新型号的真机兼容性验证。

## 项目与可借鉴之处

| 项目 | 已查阅的读取机制 | 对 RazerLite 的参考价值与限制 |
| --- | --- | --- |
| OpenRazer | Linux 内核 HID 驱动、用户态守护进程、D-Bus/Python 接口；`razercommon.c` 使用 USB HID SET_REPORT/GET_REPORT 控制传输发出查询、取得响应。型号驱动决定命令和接口等差异。 | 雷蛇私有协议的主要证据来源。参考编解码、校验、时序和型号差异；Linux 内核与 D-Bus 层不直接移植。USB 实现不能自动覆盖蓝牙。 |
| razer-macos / librazermacos | Electron 前端配合 C 后端；后端通过 IOKit 枚举 USB 服务，创建 IOUSBDeviceInterface，按产品类型/PID 筛选并打开设备。 | 能参考 macOS USB 通信路径和旧型号实现。该后端路径以 USB 为中心，不解决当前 BLE 电量问题；RazerLite 保留 SwiftUI 和自身 IOHID 后端。 |
| libratbag / Piper | Piper 经 D-Bus 调用 ratbagd，再进入硬件后端与厂商 HID 协议；设备数据库把设备匹配到指定后端。`.device` 示例明确使用 `bus:vid:pid`，区分 USB 与 Bluetooth。 | 最值得借鉴设备注册表：型号身份、连接方式、协议家族和后端分别维护。共享协议需证据，新增名称条目本身不证明能够读取或控制。 |
| Solaar | Linux udev/hidapi 发现 Logitech HID++ 设备；分别维护接收器与设备对象；区分查询响应和主动通知，缓存状态，利用热插拔/连接/电量通知更新界面。HID++ 2.0 支持查询设备功能表。 | 参考接收器与外设的关系、状态缓存和通知处理。接收器存在不代表鼠标在线。HID++ 是罗技协议，不能把功能表查询或报文用于雷蛇。 |
| OpenRGB | DetectionManager 的 HID 检测器按 VID/PID、interface、usage page、usage 匹配；hidapi 包装提供 Feature Report 传输，并有可选热插拔回调。 | 参考接口级匹配、适配器注册和 RGB 能力抽象；不能按 VID 或报文长度给所有设备启用同一组命令。 |
| Polychromatic | 官方 README 明确其为依赖 OpenRazer 的前端，硬件通信由 OpenRazer 提供。 | 参考功能展示、托盘入口和故障排查；它没有提供另一个独立的通用读取驱动。 |
| Hammerspoon 电池模块 | `otherBatteryInfo` 读取 IORegistry 的 BatteryPercent 等属性；单独的 `privateBluetoothBatteryInfo` 调用 IOBluetooth 私有属性，源码明确提示跨系统版本可能失效。 | 很适合解释“系统有电量、公开 API 却未必有”的差异。优先验证系统发布的数据；不把私有蓝牙属性作为默认依赖，也不把属性缺失解释为设备没有电池。 |

FerrisPulse 已单独审查，详见 [FERRISPULSE_REVIEW.md](FERRISPULSE_REVIEW.md)。可以参考分品牌后端和多设备组织；其中猜测未知报文字节、默认电量/DPI、批量尝试协议参数的路径不适合作为可靠的通用探测机制。

## 机制上的共同点

1. **发现与查询是两件事。** 系统可提供名称、标识、连接方式和 HID 描述信息；DPI、灯效、固件、电量未必都在这些属性中。查询通常还需要标准服务或已知厂商协议。
2. **HID 是传输和报告框架，不提供统一的游戏鼠标设置协议。** 即使都是 Feature Report，不同型号仍可能有不同命令、长度、接口、transaction 和响应语义。逻辑上的“只读查询”也可能需要先 SET_REPORT 提交查询请求。
3. **连接方式属于兼容性条件。** 同一产品的 USB、有接收器无线、蓝牙路径要分别记录；接收器还可能代理另一台设备的状态。
4. **能力动态查询并非所有品牌都有。** Solaar 的 HID++ 2.0 功能发现机制可借鉴设计，不能据此假定 Razer 设备存在相同机制。对没有已知能力查询的设备，使用证据明确的静态规则加真机结果。

## 蓝牙电量：标准路径与 macOS 限制

Bluetooth SIG 定义了 Battery Service `0x180F` 和 Battery Level `0x2A19`。Apple CoreBluetooth 提供特征值读取以及通知订阅 API。这是一条标准读取路径，但前提是目标设备公开该服务、应用可以访问，并且能够可靠地把 CoreBluetooth 外设与当前 HID 设备对应起来。不能只靠名称关联，也不能保证所有已经由 macOS 接管的蓝牙鼠标都对应用暴露该服务。

IORegistry/IOPowerSources 是另外的系统数据来源；公开枚举 API 不代表所有设备都发布了电量字段，也不保证 IORegistry 属性键跨系统版本稳定。`system_profiler` 可作为手动诊断和交叉验证工具，不宜以高频子进程扫描作为常驻刷新方案。

对当前 `BSK MOBILE / BLE / 068E:00D5`：此前系统诊断能显示电量，RazerLite 尚未接入。建议先验证同一设备的系统电量来源及匹配关系；系统来源不适用时，再验证标准 GATT。尚未确认它对应用暴露 Battery Service，也未确认其蓝牙 DPI 私有协议。USB 型号表和 USB 查询不能直接用于这个 BLE 标识。

## 建议落地到 RazerLite

- 保留现有 IOHIDManager 发现与热插拔；按需增加系统电量、标准 GATT、已验证厂商协议三个独立读取后端。
- 建立显式设备规则：transport、VID/PID、接口指纹、协议家族、支持的操作、上游证据、真机验证状态。型号目录继续仅负责身份参考。
- 状态值记录来源、应用取得时间、连接会话和错误；系统缓存的取得时间不冒充设备实际测量时间。断连清除本次会话状态，迟到响应不得更新新连接。
- 优先连接/状态通知与用户刷新；后台读取有需要时再增加有界、低频、可暂停的策略。没有设备通知机制的型号不能宣称完全靠事件取得变化。
- 下一轮先实现 BSK MOBILE 的系统电量验证与读取，再完善重连和菜单栏。DPI/RGB 扩展独立进行，遵循已有型号证据和写入确认规则。

## 来源

- [OpenRazer 架构与设备范围](https://github.com/openrazer/openrazer)、[USB 查询实现](https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c)
- [razer-macos](https://github.com/1kc/razer-macos)、[librazermacos USB 枚举实现](https://github.com/1kc/librazermacos/blob/master/src/lib/razerdevice.c)
- [libratbag 架构](https://github.com/libratbag/libratbag)、[设备匹配格式](https://github.com/libratbag/libratbag/blob/master/data/devices/device.example)
- [Solaar 实现文档](https://github.com/pwr-Solaar/Solaar/blob/master/docs/implementation.md)
- [OpenRGB DetectionManager](https://github.com/CalcProgrammer1/OpenRGB/blob/master/DetectionManager.cpp)
- [Polychromatic README](https://github.com/polychromatic/polychromatic)
- [Hammerspoon 电池模块及私有 API 说明](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/battery/libbattery.m)
- [Bluetooth SIG Battery Service](https://www.bluetooth.com/specifications/specs/battery-service/)、[Assigned Numbers](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/index-en.html)
- [Apple CoreBluetooth readValue](https://developer.apple.com/documentation/corebluetooth/cbperipheral/readvalue(for:)-6u2kr)、[setNotifyValue](https://developer.apple.com/documentation/corebluetooth/cbperipheral/setnotifyvalue(_:for:))、[IOPowerSources](https://developer.apple.com/documentation/iokit/iopowersources_h)

本轮仅借鉴机制并写入调研文档，没有移植第三方源码。以后引入代码时逐文件检查许可证；libratbag README 声明 MIT，其他项目及其子模块不能因此视为同样许可。
