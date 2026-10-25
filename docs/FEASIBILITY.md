# RazerLite 技术可行性与 MVP 方案

> 本文记录最初的 Phase 1 调研；2026-10-18 新增的 Viper V4 Pro 手动只读查询和真机结果见 [Phase 2 验证](READ_ONLY_PROTOCOL.md)。

调研日期：2026-10-17（Asia/Singapore）。这是本机只读观测与公开源码审查的结果，不是设备控制兼容认证。

## 结论与本机环境

**Phase 1 可行，直接使用 SwiftUI + IOKit，无需第三方运行时、内核扩展、管理员权限或完整 Xcode。** 控制功能有公开协议线索，但必须分别验证型号、连接模式、固件、接口及响应。本次只实现发现与诊断。

实测环境：Apple Silicon arm64，macOS 27.2（26B5091g），Apple Swift 6.4（swiftlang-6.4.0.34.1），开发目录 `/Library/Developer/CommandLineTools`，可用 macOS SDK；`xcodebuild -version` 明确报告需要完整 Xcode。因此使用 Swift Package Manager，并用脚本打包本地 `.app`；以后安装 Xcode 可直接打开 Package.swift。最低部署目标先设 macOS 13，当前只在上述系统实测。

| 实测设备 | VID:PID | 系统传输 | HID 接口 | 版本属性 | 连接模式证据 |
| --- | --- | --- | --- | --- | --- |
| Razer Viper V4 Pro | 1532:00E6 | USB | 5 | VersionNumber / bcdDevice = 0x0101 | 公开 PID 表标为无线接收器；系统只能直接确认 USB |
| Razer BlackWidow V4 Low-profile Tenkeyless HyperSpeed | 1532:02D2 | USB | 5 | VersionNumber / bcdDevice = 0x0100 | OpenRazer PR 标为 HyperSpeed 接收器；系统只能直接确认 USB |
| Razer DriverKit VirtualJoystic 0.0.3 | 1532:27DB | USB 属性 | 1 | VersionNumber = 0x0100 | 虚拟 HID，不能计作实物外设或据此判断真实传输 |

**以上版本字段不是已验证的固件版本。** 本次不读取厂商固件报文。蓝牙控制器开启，但没有观察到连接中的 Razer 蓝牙 HID。USB 名称和接口存在也不能证明接收器后的无线外设当前在线。

### HID 接口观测

表中的最大长度来自已发布的 HID 属性，不代表这些报文已经收发成功，也不能据长度推导命令。

| 设备 | USB interface | Primary usage page / usage | Max input / output / feature 字节 |
| --- | --- | --- | --- |
| Viper V4 Pro | 0 | 0x0001 / 0x0002 | 8 / 0 / 0 |
| Viper V4 Pro | 1 | 0x0001 / 0x0006 | 16 / 2 / 1 |
| Viper V4 Pro | 2 | 0x0001 / 0x0006 | 8 / 1 / 0 |
| Viper V4 Pro | 3 | 0x000C / 0x0001 | 0 / 0 / 90 |
| Viper V4 Pro | 4 | 0xFF13 / 0x0001 | 62 / 62 / 62 |
| BlackWidow | 0 | 0x0001 / 0x0006 | 8 / 1 / 0 |
| BlackWidow | 1 | 0x0001 / 0x0006 | 16 / 2 / 1 |
| BlackWidow | 2 | 0x0001 / 0x0002 | 8 / 0 / 90 |
| BlackWidow | 3 | 0x0059 / 0x0001 | 1 / 1 / 51 |
| BlackWidow | 4 | 0x0059 / 0x0001 | 1 / 1 / 64 |

本机同时运行 Razer.app、GameManagerService、Elevation Service；`systemextensionsctl list` 显示 `com.razer.appengine.driver` 0.0.14 与 `com.razer.appengine.virtual.driver` 0.0.13 均启用。它们可能占用接口、改写配置或产生虚拟设备。Phase 1 不停止这些进程、不卸载驱动。当前只验证共存时的发现；未来控制时应提示冲突，不能把进程存在当作必然控制失败的证据。

## macOS 通信机制

- IOKit 的 IORegistry 发布设备、接口、usage、连接类型等属性。`IOHIDManagerSetDeviceMatching` + `IOHIDManagerCopyDevices` 可发现设备；matching/removal callbacks 提供事件驱动热插拔。已用本机探针验证，在从未调用 manager/device open 的情况下仍获得 11 个接口和初始 matching 通知。[Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- 创建 manager 时使用 SDK 中的 `IOHIDManagerOptions.independentDevices`。本地 `IOHIDManager.h` 明确说明这使 manager 的 open、schedule 等调用不传播到设备；本项目进一步完全不调用 open。只为 manager 调度主 run loop，读取 `IOHIDDeviceGetProperty`，不注册输入报文或输入值回调。
- 后续 HID transport 可用 `IOHIDDeviceGetReport` / `IOHIDDeviceSetReport` 对已精确选定的接口收发 feature reports。USB HID 的 GET_REPORT/SET_REPORT 是标准传输机制，承载的数据可以是厂商私有协议。OpenRazer 的 Linux USB control transfer 不能直接照搬成 macOS API：接口索引、report ID、长度和独占/访问限制要单独核对。[Apple IOHIDDevice 头文件文档](https://developer.apple.com/documentation/iokit/iohiddevice_h)
- 某些厂商“查询”本身需要先 SET_REPORT 写入查询命令，再 GET_REPORT 取响应。**语义只读不等于总线上无写入**。Phase 1 连查询报文都不发送；下一阶段把经审查的查询与持久写入分别列入允许清单。
- 2.4GHz 接收器在主机侧通常表现为 USB HID；无线链路内部仍可能有不同 transaction/device ID 和唤醒语义。蓝牙 HID 只有在 macOS 发布对应 HID 服务及 feature 能力时才考虑 IOHID 路径；不能假定 USB 的 PID、接口、协议原样适用。CoreBluetooth 仅适合已知 GATT 服务，不是通用蓝牙 HID 替代通道。[Apple CoreBluetooth](https://developer.apple.com/documentation/corebluetooth)
- 新系统还有 CoreHID，可后续另建 transport，但当前为了 macOS 13 基线与已有 SDK API，采用 IOKit。[Apple HIDDeviceManager](https://developer.apple.com/documentation/corehid/hiddevicemanager)

## 标准 HID 与私有能力

| 功能 | 路径 | 本阶段状态 / 后续约束 |
| --- | --- | --- |
| 标准鼠标、键盘输入 | 系统 HID 驱动处理 | 保留系统行为；本应用不捕获输入 |
| VID/PID、usage、最大报文长度、传输属性 | 系统已发布属性 | 已可读取；缺失字段显示未知 |
| 固件、DPI、DPI 档位、polling、厂商电池 | 型号特定私有协议 | 待验证；不能用指针速度或 USB descriptor 冒充 |
| RGB 亮度、静态/呼吸/波浪 | 型号特定私有协议 | 键盘有公开实现线索；效果集合须按型号验证 |
| 硬件按键映射、Fn、板载配置 | 私有协议与板载支持 | 尚未实现；现有材料不足以宣称完整支持 |
| macOS 按键映射、全局宏 | 系统事件监听与注入 | 独立可选模块；需权限，可能遇到 Secure Input 等限制 |
| JSON 配置导入导出、菜单切换 | 本地服务 | Phase 2/3；导入不得隐式写设备 |
| 自动恢复设备设置 | 热插拔/唤醒事件后应用 | Phase 3；先确认设备身份与已授权配置，避免定时写入 |
| 固件更新、接收器配对、未知板载写入 | 高风险/资料不足 | 排除 MVP；不发送未知命令 |

## 开源项目审查与具体型号

以下为本次固定 revision，避免把日后主分支变化混入当前结论。源码仅存于忽略提交的 `.research/`；Phase 1 不复制或链接这些实现，不依赖其守护进程。

| 项目 | 审查 revision | 可借鉴内容与边界 |
| --- | --- | --- |
| OpenRazer | `477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d` | driver 中的型号分支、请求响应校验与协议线索；Linux kernel/sysfs/DBus 架构不能直接作为 macOS 后端。该快照未包含本机两个 PID。文件标注 GPL-2.0-or-later。 |
| libratbag | `8235b5bb6032dea15901ab58a8218956f4494d08` | 设备数据库、能力抽象、profile 与协议分离；该树没有 Razer 专用驱动/设备条目，不是本机设备现成适配层。COPYING 为 MIT。 |
| Polychromatic | `736774f5d0b7aee56cc02729e271802f6fd00e87` | OpenRazer 前端与能力呈现可参考；没有独立可直接移植的 macOS HID 后端。LICENSE 为 GPL v3。 |
| 1kc/razer-macos | `27f8a770611c4d68d0387a980e55b79711a343f3` | Electron UI + `librazermacos` 子模块，历史 macOS 实现可供审查；没有本机新型号覆盖证据，不作为依赖。仓库 LICENSE 为 GPL v2 文本，具体文件/子模块另查。 |
| OpenMouse mouse-protocol | `54c68c69bbd0bcd750cf10a4e439148e634c02db` | 精确 Viper V4 Pro 型号协议线索，尚未在本机运行。仓库 LICENSE 为 AGPL v3 文本，不复制其实现。 |

来源：[OpenRazer driver](https://github.com/openrazer/openrazer/tree/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/driver)、[libratbag](https://github.com/libratbag/libratbag/tree/8235b5bb6032dea15901ab58a8218956f4494d08)、[Polychromatic](https://github.com/polychromatic/polychromatic/tree/736774f5d0b7aee56cc02729e271802f6fd00e87)、[razer-macos](https://github.com/1kc/razer-macos/tree/27f8a770611c4d68d0387a980e55b79711a343f3)。后续若复制或改编第三方代码，先逐文件记录来源与许可证，保留声明并落实分发条件；当前不替项目擅自选择开源许可证。

### Viper V4 Pro 1532:00E6

独立实现的 [PID/codec 表](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/razer/v4.ts) 将 `00E5` 标为有线、`00E6` 标为无线；其 [型号适配器](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/drivers/razer/viper-v4-pro-hid.ts) 包含 DPI、档位、polling、电池及响应校验。它采用 90 字节报告与型号特定 polling 编码，不能套用旧鼠标 rate 表。这里只把它记作“公开实现存在、本机未验证”；尤其是 response/report ID、接口 3 的 macOS 访问、固件差异与 Synapse 共存仍待测。

### BlackWidow 1532:02D2

[OpenRazer PR #2912](https://github.com/openrazer/openrazer/pull/2912) 精确列出 `02D2` 接收器、`02D4` 有线，并描述接收器 interface 2 / transaction 0x9F、有线 interface 3 / 0x1F。作者报告过亮度、效果、电池等真机测试，但平台为 Linux，**不构成本机 macOS 验证**。另有 [PR #2943](https://github.com/openrazer/openrazer/pull/2943)；提交状态及 revision 见 `research-sources.json`。不能拿全尺寸的 `02C9/02CC` 或非 Low-profile 的 `02D5/02D7` 当成本机键盘。

下一阶段建议先为此 PID 审查一个亮度查询的完整请求响应流程，先离线 fixtures、再用户确认后的真机查询，最后才考虑用户确认的临时亮度修改；不在启动时复用上游 probe 中的 set_device_mode 或其他写配置行为。

## 权限、签名与分发

Phase 1 不申请 Input Monitoring、Accessibility 或蓝牙扫描权限；也不调用监听/注入 API。权限应由所需功能决定，不能为了枚举要求用户全部授权。以后系统级重映射应在用户启用功能时解释并申请输入监控/辅助功能；权限拒绝必须可恢复。[Apple 输入监控设置](https://support.apple.com/guide/mac-help/mchl4cedafb6/mac)

本地开发先用非沙盒 `.app` 与 ad hoc 签名。沙盒 USB/蓝牙 entitlement 与 TCC 是不同机制，不能凭一个 entitlement 推断可访问所有 HID；若考虑商店分发，需重新实测访问路径。[Apple USB entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb)

公开分发阶段使用 Developer ID Application、Hardened Runtime、时间戳、notarytool 提交及 stapler 验证。当前未使用开发者证书、未公证，不宣称可直接公开发布。无需 kext/DriverKit；若未来普通用户态 API 被驱动阻挡，先报告并验证替代接口，不要求关闭 SIP。[Apple 分发签名](https://developer.apple.com/developer-id/)、[Apple 公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 建议架构与 Phase 1 边界

```text
SwiftUI App / MenuBar / UI
          ↓
DeviceManager（业务状态、分组、诊断、能力摘要）
          ↓
HIDDiscovery（只读属性和热插拔）
          ↓
IOHIDManager / IORegistry

Phase 2 才增加：
DeviceControlService → 精确型号 Adapter → Protocol codec → HIDTransport
ProfileService → Codable JSON（独立设备身份与 schema version）
```

Core 为独立 Swift library，可供 UI、命令行探针与测试共同使用。UI 不 import IOKit。通过 USB 父设备 registry ID 聚合同一设备的多接口，保留每个 interface 的 registry ID；相同 PID 的两台设备不互相覆盖。虚拟设备单独标注。没有可靠父节点时宁可保留独立接口，不凭名称或全零序列号合并。重连后的 session registry ID 不作为未来持久 profile 的唯一身份。

Phase 1 交付：真实设备列表、接口详情、明确的“待验证/未实现”能力状态、插拔通知、手动刷新、菜单栏入口、有限内存日志、JSON 诊断导出、只读 CLI、测试、构建运行与性能测量说明。完全没有设备控制传输实现，避免误触写操作。协议和配置层先以文档定义契约，直到下一阶段需要时再添加代码。

## 0.4.0 本地档案边界

本地档案已作为独立 `ProfileService` 落地：版本化 Codable JSON、原子写、严格导入校验和菜单栏选择。它只保存经审查 Viper V4 Pro USB 适配器的 X/Y DPI 目标；不持有 HID Transport、会话 registry ID、写入许可或自动恢复任务。该分离沿用 libratbag 的“能力模型与后端协议分开”思想，但没有复用源码。有关保存格式、匹配边界和验证见 [本地 DPI 档案](LOCAL_PROFILES.md)。

这不是板载 profile 支持：尚未有可靠证据表明可安全切换完整板载 profile、活动档位、RGB、按键、宏或自动按应用切换。档案载入只能预填 UI；只有既有的逐次确认 DPI 流程可以写设备。

性能策略：仅设备匹配/移除和手动刷新触发状态更新；不注册输入回调、不轮询、不持续扫描进程；内存日志有固定上限。CPU、RSS、physical footprint、启动时间必须在 release 构建分别实测，记录窗口/菜单状态、样本区间、系统版本与样本方法；不能将 RSS 当成总内存或用一次采样宣称零 CPU。

后续阶段的门槛：Phase 2 完成逐型号 report fixture、异常响应、访问权限与用户确认的真机验证；Phase 3 才做 profile 自动加载与登录项；Phase 4 包括睡眠唤醒、物理插拔、接收器在线/离线、Synapse 冲突、签名公证。物理拔插与睡眠验证需要实际操作，自动化模型测试不能替代。
