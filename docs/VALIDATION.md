# Phase 1 验证记录

当前版本 0.10.2 的电量读取、调度、提醒及验证边界见 [PHASE0102_BATTERY.md](PHASE0102_BATTERY.md)；0.10.1 读取任务、连接生命周期与历史读数验收见 [PHASE0101_READ_LIFECYCLE.md](PHASE0101_READ_LIFECYCLE.md)；适配证据、能力状态和连接诊断见 [0.10.0](PHASE010_CAPABILITIES.md)。设置与性能历史基线见 [0.9.2](PHASE092_PREFERENCES.md)，本地档案与离线场景分别见 [0.9.1](PHASE091_LOCAL_LIBRARY.md) 和 [0.9.0](PHASE09_OFFLINE_SCENARIOS.md)。下文保留历史验证记录，不能把早期设备和指标直接当作当前状态。

日期：2026-10-17，Asia/Singapore。机器：Apple M2 Pro / 16 GiB / arm64，macOS 27.2（26B5091g），CLT Apple Swift 6.4。测试时保留了现有 Razer.app、相关服务及 DriverKit 扩展。

## 已完成

| 检查 | 实际结果 |
| --- | --- |
| `./scripts/test.sh` | 2 个 suite、10 项 Swift Testing 测试通过；最新输出见 `build/tests.log` |
| Debug / Release 构建 | 均成功；最终为 Release，见 `build/release-build.log` |
| 原生 GUI 启动 | Debug 测试确认真实可见的 RazerLite window 创建，且业务核心导出真实设备；最终 Release 也已启动并保持运行 |
| 本机枚举 | Razer 11 个 HID 接口 = 两款实物设备各 5 个 + 虚拟摇杆 1 个；`--all` 枚举到共 30 个系统可见接口 |
| 系统交叉核对 | VID/PID、usage、USB interface、最大 feature 长度与 IORegistry / hidutil 结果一致 |
| 通知路径 | 初始 matching callbacks 已在只读探针验证；`--watch 1` 能等待后正常退出。设备移除/重连业务状态使用模拟事件测试通过 |
| 数据输出 | CLI 与 GUI 业务导出均为可解析 JSON；包含 schema，不收集序列号或输入内容 |
| 能力状态 | 仅 discovery 标记已实现；精确型号公开实现标记待验证；其他标记未实现，不宣称硬件不支持 |
| 本地签名 | `codesign --verify --strict build/RazerLite.app` 通过；ad hoc + runtime，没有 Developer ID / 公证 |
| 依赖检查 | Release `otool -L` 仅列系统框架/运行库；没有 Testing、Electron、WebView 或第三方运行时依赖 |
| 资源与脚本 | Info.plist 校验、shell 语法、性能脚本语法通过 |
| 控制路径审查 | Sources 无 device/manager open、GetReport/SetReport、独占、input callback、Timer 或网络请求调用 |

10 项测试覆盖：USB 多接口聚合；同型号不同父节点不合并；零 location/缺失身份及虚拟设备不误合并；能力不虚报成功；按连接方式匹配；键鼠与相邻 PID 隔离；诊断 JSON round-trip；服务 start/stop/refresh；错误反馈与 200 条日志上限；弱回调释放；模拟分接口移除、整机断开与新 session 重连。其中部分场景在同一项测试中验证。

浅色/深色的**真实功能内容组件**通过 SwiftUI ImageRenderer 渲染并人工检查，内容清晰，无重叠。产物在 `build/smoke-final/light.png`、`dark.png`，真实快照和成功标记在同一目录。NSView 缓存截图无法可靠捕获 SDK 27 的部分 AppKit 控件，已改为渲染窗口所共用的内容组件；**这不算完整窗口、原生 TabView、菜单或保存面板的交互验收**。

当前文件提供程序会给 `.app` 目录自动附加 FinderInfo，因此已验证的应用本体生成于 `~/Library/Caches/RazerLite/1327264307/RazerLite.app`，工作区 `build/RazerLite.app` 为链接。编译缓存另存临时目录。未修改系统签名策略、驱动或保护机制。

## 实测性能（初版界面，初步样本）

以下是界面改版前的 Release GUI 历史样本，PID 49278，主窗口显示、菜单未展开，2 款实物设备与 1 个虚拟 HID，现有 Razer 软件继续运行。窗口启动后再采样；不是严格控制的冷启动或长期能耗测试。新版界面的记录见 [UI_DESIGN.md](UI_DESIGN.md)，不能将本节数值直接作为新版性能。

| 指标 | 实测值 / 方法 |
| --- | --- |
| 区间 | 15.2767 秒，16 个 ps 样本 |
| CPU | 累计 CPU 时间无可测增量；计算平均值为 0.0%，受 ps 计时精度限制，不保证持续零 CPU |
| RSS | 全部样本 131,888 KiB，约 128.8 MiB；包含共享页的驻留口径 |
| Physical footprint | 采样后 `vmmap -summary` 报告 44.9M，peak 45.6M；与 RSS 的口径不同 |
| Release GUI executable | `du -h` 780K（磁盘占用口径，不是运行内存） |
| Release CLI executable | `du -h` 396K |
| CLI 发现初始化 | 单次缓存后样本 11.53 ms，仅从创建发现对象到属性快照 |
| CLI 整个生命周期 | 同一次 `/usr/bin/time -lp` real 0.02 s；不能当 GUI 启动时间 |
| GUI 启动到首帧 | 尚未测量，已有可复测方法，不提供估算 |
| 窗口关闭后的菜单栏状态 | 实现保留服务；该状态的性能尚需按方法另测 |

原始证据：`build/release-visible.csv`、`build/release-visible-summary.json`、`build/release-vmmap.txt`、`build/startup-time.log`。方法与误差见 [PERFORMANCE.md](PERFORMANCE.md)。这些数值是本次机器上的小样本，不是性能承诺。

## 仍需真机或人工验证

1. 运行 `./build/razerlite-probe --watch 30` 后，逐个物理拔插两个接收器，确认全部接口收敛，重复同 PID 的两台设备不互相覆盖。当前模拟事件不能替代这个测试。
2. 在接收器保留连接时开关无线外设：列表只能显示 USB 接收器，不能把它当无线端在线状态。
3. 睡眠唤醒、USB hub 断电、蓝牙连接及重连；目前没有连接中的 Razer 蓝牙设备可供验证。
4. 原生界面选择设备、切换三个标签、菜单重开窗口、关闭窗口后持续运行、设置、保存面板取消/写入失败等交互；业务 JSON 和错误状态已有自动测试。
5. 无 Razer 软件/驱动环境下重新验证发现；本次只验证了与现有驱动共存时的属性枚举，尚未验证控制共存。
6. macOS 13–26、Intel 兼容性；最低部署目标不是已经覆盖这些真机。
7. DPI/RGB/电池等设备控制、硬件映射、profile、宏、板载存储和任何报文 codec/fixture 均属后续阶段，未发送报文、未验证，不能作为已支持功能宣传。
8. Developer ID 签名、公证、分发与升级流程属于 Phase 4；当前本地签名不是公开发布验收。

## 下一阶段建议

先审查键盘 `1532:02D2` 的 interface 2 查询协议，以公开 PR 的固定 revision 为依据建立离线报文测试；验证 response 长度、状态、transaction、class/id、校验、busy/timeout/断连处理。确认查询不会执行上游 probe 的设备模式切换后，再给出一项具体、可审查的真机验证操作。任何亮度修改、板载保存或其他可能改变设备行为的操作均需用户明确确认。

## 2026-10-18 增量验证

0.2.0 已完成 26 项 Swift Testing、6 项 CLI 检查、Release 构建和 ad hoc 签名验证。Viper V4 Pro 的电量、当前 X/Y DPI 与全部 DPI 档位已由 CLI、GUI 共用服务及 Release 原生窗口点击分别完成真机读取。初次时序问题、实际返回值、并发限制和未完成项目详见 [只读协议与真机记录](READ_ONLY_PROTOCOL.md)。此前的 Phase 1 结果不作为当前版本新增查询或性能指标的证明。

## 0.3.0 增量验证

39 项自动测试通过，新增 DPI 变更检查、逐次确认、单次许可与完整表读回校验。此次未向实物发送设置命令；真机写入与持久性仍待验证。操作边界和后续验证步骤见 [DPI 变更说明](DPI_WRITE.md)。

0.3.0 Release 原生窗口完成了输入校验、真实档位表准备、前后对照和取消路径验证；候选值 2800/2800 只用于预览，未写入实物。公开抓包确认的 GET 一基 / SET 零基索引差异已加入回归测试。

## 2026-10-18 13:30（UTC+8）授权真机写入

用户明确同意第 3 档改为 X/Y 2800 后，Release 0.3.0 原生窗口完成单次提交与全部五档读回校验；独立 CLI 于 13:31:21 再次确认当前第 3 档 X/Y 2800，其他四档 400、800、6073、49999 保持不变。前后 JSON 和比较摘要保存在 build/dpi-write-before.json、build/dpi-write-after.json、build/dpi-write-validation.json。此次成功取代此前“尚未发送真实设置”的阶段状态，历史记录保留。未进行重启持久性验证。GUI NSSavePanel Save 禁用问题已记录，本轮未验证 GUI 文件导出成功，使用 CLI 保存实际诊断。详情见 [DPI 真机记录](DPI_WRITE.md)。

## 0.4.0 本地 DPI 档案

- `./scripts/test.sh`：45 项 Swift Testing、8 个 suite 通过；新增的档案测试覆盖稳定 VID/PID/transport 匹配、非法值、原子本地保存/重载、选择/删除、导入导出去重和 ID 冲突，以及损坏本地 JSON 不被覆盖。
- Debug `.app` 构建、ad hoc 签名检查和被动启动通过。启动、档案选择和本地 JSON 操作没有调用 HID Transport；自动测试也没有将档案服务接到 `MouseDPIControlling`。
- 原生窗口人工路径：手动读取现有 Viper V4 Pro 的状态后，从读取到的 X/Y 2800/2800 创建了一个本地预设；点击“载入编辑器”后，性能页只显示预填的 X/Y 2800。没有点击“检查变更…”或“确认写入设备”，因而没有新增 HID 设置请求。
- SwiftUI ImageRenderer 输出了档案页的浅色/深色共享内容；真实窗口的无障碍树确认文本框、保存按钮、预设行和“载入编辑器”状态。渲染器不可靠地绘制禁用原生控件，因此视觉结论以实际原生窗口为准。
- 导入/导出 JSON 的编码、解码、去重与冲突处理由临时文件单元测试覆盖。macOS 原生文件选择/保存面板仍须另行人工验收；此前诊断 NSSavePanel 的 Save 禁用问题没有被当作已修复。

## 多设备发现与 FerrisPulse 参考

新增 273 项独立型号识别数据、可搜索设备目录、通用基本信息刷新和设备类型展示；私有命令白名单不扩大。48 项测试、9 个 suite 通过（`build/catalog-tests.log`），Release 构建及 ad hoc 签名校验通过（`build/catalog-release-build.log`）。原生 Release 窗口已实际验证目录入口与搜索 PID `00A6`，结果为 Viper V2 Pro Wireless、匹配 1 项；来源与待适配状态显示正确。

本轮现场枚举仅发现 Razer 虚拟 HID，没有实物接收器，因此未进行新增设备私有状态查询或设置。被动 CLI 快照在 `build/catalog-discovery.json`。目录数据和模拟测试不能代替 273 款设备的硬件兼容测试。FerrisPulse 的 PID 冲突、平台差异与协议约束见 [审查记录](FERRISPULSE_REVIEW.md)。

同时再次复现诊断 NSSavePanel 的 Save 按钮禁用，切换到 `/private/tmp` 后仍禁用；已取消操作，未生成导出文件。原因仍未知，不能再将其归因于同步目录。档案 GUI 导入/导出保持未完整验收状态。

## 0.4.1 蓝牙发现漏检修复

用户指出实际连接蓝牙鼠标后，`--all` 发现 `BSK MOBILE`，Bluetooth Low Energy，VID `068E` / PID `00D5`，厂商属性 Razer。原来 IOHIDManager 只匹配 USB VID `1532`，漏掉了蓝牙侧身份。此前“没有实物设备”的结论只反映错误过滤后的列表，并不表示系统没有连接设备。

发现改为多 vendor 匹配，再按 transport 过滤：`1532` 保持原行为；`068E` 仅在 Bluetooth / Bluetooth Low Energy 接受，USB 同值拒绝。依据 [Bluetooth SIG assigned numbers](https://www.bluetooth.com/specifications/assigned-numbers/) 的 Razer Inc. 标识；本机 VendorIDSource 属性原样观测为 2，不依此单一字段推断命名空间。保留原始 VID/PID，不转为 USB VID，不复用同 PID 的 USB 名称/协议。BLE 鼠标可附带键盘 usage，分类优先使用一致的 primary usage。

50 项测试、10 组通过（`build/bluetooth-tests.log`）。Release 构建和签名校验通过。默认 CLI 已发现 BSK MOBILE 和原有虚拟 HID，快照为 `build/bluetooth-fixed.json`；原生窗口实际显示“我的设备 1”、BSK MOBILE、Bluetooth Low Energy、1 个接口与“刷新基本信息”。未请求输入权限，未打开输入接口，未发送私有状态或设置命令。系统蓝牙工具发布的电量没有被冒充成本应用已经实现的实时电池查询。

## 0.5.0 蓝牙系统电量与读取后端

- 新增 DeviceReadRegistry，分别选择 macOS 蓝牙系统电量和 Viper V4 USB 专属协议后端；型号目录与后端启用继续分离。蓝牙同 PID 不启用 USB 私有查询或写入。
- BSK MOBILE（BLE，068E:00D5）的 HID 节点未发布 BatteryPercent。该节点的 DeviceAddress 与 macOS 蓝牙 connected 快照精确对应，VID/PID 同时吻合。原始地址没有保存到设备模型、日志或导出 JSON。
- 调试 CLI 首次验收时系统暂未枚举到 Razer HID，也没有连接中的 Razer 蓝牙项；用户确认保持连接后，鼠标以新的 registry ID 出现。随后 Debug CLI、最终 Release CLI 和两次 Release 窗口按钮读取均取得 100%，来源 macOSBluetoothSnapshot。最终 Release CLI 记录于 2026-10-18T12:22:53Z，见 `build/system-battery-live.json`、`build/system-battery-live.log`。
- 原生 Release 窗口确认“读取系统电量”按钮、100% 百分比、macOS 蓝牙系统快照来源、应用取得时间以及“系统缓存 / 不自动轮询”说明。标准蓝牙 GATT 与蓝牙 DPI/RGB 仍未实现，没有把本次系统缓存读数声明为直接设备测量。
- 最终 `./scripts/test.sh`：63 项测试、13 个 suite 通过，见 `build/system-battery-tests.log`。覆盖精确地址与 VID/PID 关联、同名不同设备、忽略未连接条目、重复记录、非法/缺失电量、有效零电量、源优先级、导出不包含地址、显式读取去重、失败清除旧值、同 ID 重连/身份变化/睡眠/停止后的迟到结果隔离。使用自己启动的 sleep/yes/false 子进程验证超时、输出限额、取消及非零退出处理，没有对真机执行这些测试命令。
- 最终 Release 构建及 ad hoc 签名验证通过，见 `build/system-battery-release-build.log`。本轮没有新的硬件设置请求；已有 Viper 协议测试使用模拟传输。

本机 M2 Pro / macOS 27.2 arm64，1 台 BLE Razer，Razer 后台服务仍运行。读取完成后的窗口可见短样本约 15.15 秒，平均 CPU 0.99%，RSS 114000–132464 KiB；关闭主窗口后进程保留，约 30.37 秒样本平均 CPU 0.20%，RSS 中位数 93024 KiB（约 90.8 MiB），范围 92400–130144 KiB。原始 CSV 和摘要为 `build/system-battery-idle*`、`build/system-battery-window-closed*`。关闭窗口样本期间曾独立运行一次短 CLI 读取；这些数字仅计主应用 PID，不包含该 CLI 或系统快照子进程，不能代表整次读取操作的总成本。RSS 不是 physical footprint；样本短、包含系统回收/界面状态过渡，不是性能保证或绝对零 CPU 证明。

模拟生命周期测试不能替代真实睡眠唤醒、长时间断连重连、其他型号、旧 macOS 或 Intel 验证。菜单栏子菜单的电量与刷新逻辑已接入，但本轮未完成原生菜单逐项点击验收；原有 GUI 文件保存面板问题仍待解决。读取机制、时限及运行方法见 [SYSTEM_BATTERY.md](SYSTEM_BATTERY.md)。历史阶段的未实现描述按其当时状态保留。

## 0.6.0 · 2026-10-19（UTC+8）

### 构建与自动测试

`./scripts/test.sh`：82 项测试、18 个 suite 全部通过，见 `build/phase06-tests.log`。新增覆盖：回报率精确请求、严格负载/枚举、busy 不重发、非目标接口不打开、共享队列串行、timeout/unsupported/设备拒绝与平台错误分类；系统缓存不声称设备曾响应；同 ID 断连/睡眠/停止后的迟到结果；完整接口指纹变化后旧查询与旧 DPI 写入结果清理；导出路径校验、排他创建和同名保护。模拟 DPI 写入测试没有连接真实硬件。

最终 Release 构建、ad hoc Hardened Runtime 签名及 strict 验证通过，见 `build/phase06-release-build.log`。未新增依赖、网络、权限申请、自动查询或设备设置入口。

### 设备与真实只读查询

当前物理 HID：Viper V4 Pro `1532:00E6` USB 与 BlackWidow V4 Low-profile Tenkeyless HyperSpeed `1532:02D2` USB，各 5 接口。初始被动快照见 `build/phase06-discovery-before.json`。后者仍只有系统信息与本地预览，未套用鼠标协议。

在公开精确型号源码与固定原始抓包核对后，Debug CLI 于 00:30:32 显式单次读取 `00/C0`，读回回报率配置 **1000 Hz**。请求 size 2、selector `01`，成功响应恰好 `[01,code]`；没有发送 `00/40`。Release 窗口于 00:31:28 点击独立“读取回报率”，同样读回 1000 Hz；界面写明配置读回与实测输入频率的区别。详见 [协议审查](PHASE06_PROTOCOL_REVIEW.md)。

00:33:08 在同一 Release 窗口点击原有“读取状态”，电量/DPI 查询完成，当前活动第 3 档 X/Y 返回 **2846/2846**，五档为 400、800、2846、6073、49999。该观察与前一天明确授权写入后独立确认的 2800 不同，不能据此推断原因；重连、板载持久性和其他控制软件影响仍需独立验证。应用未将本地 2800 预设自动写回，没有点击“检查变更”或“确认写入”。当前记录不否定历史上那次成功读回，只说明此时设备返回了不同状态。

### 诊断导出与本地编辑

Release 原生窗口工具栏打开应用自有导出页，默认 Downloads 路径、时间戳文件名及完整目标可见。本轮改成 `/private/tmp` 与 `RazerLite-phase06-ui-20261019.json` 后点击“保存 JSON”，实际成功并显示保存位置（URL 标准化显示 `/tmp/...`）。已从磁盘读回、解析 schema 4，确认含两台设备、回报率 1000 和状态摘要；项目复核副本为 `build/phase06-ui-diagnostics.json`。

再次打开导出页，用相同目录与文件名保存，界面明确提示已有同名文件，原文件逐字节不变，SHA-256 仍为 `c8fb5a40d13da160c5a90499a467f0750f30c0e31fa178c0361f10f4db8c4f0a`。该流程替代此前失败的 NSSavePanel，并未宣称解决其系统根因。Downloads 的实际写入权限、目录选择器与 Finder 跳转本轮未逐项验收。

性能页把本地预设的 X 目标从 2800 改成 2850，界面随即显示“目标已修改”；点击“重新载入”后恢复 2800 与“编辑器目标一致”。两步只改本地编辑器。菜单栏选择档案后跳转性能页的代码已接入，原生菜单逐项点击仍未验收。

### 范围与待验证项

HID 发现回调改到 main run loop 的 common modes，以便菜单跟踪期间也能处理移除；没有增加合并刷新计时器或周期扫描。接口移除与睡眠仍立即使请求和写入计划失效。真实睡眠唤醒、多台同型号、拔插时菜单打开、不同固件、旧 macOS 与 Intel 尚未覆盖。本轮没有重新测性能，0.5 的短样本不是 0.6 的性能结论。

## 0.7.0 · 2026-10-19（UTC+8）

按用户明确选择，本轮先完成代码和测试，目标硬件暂不可用。被动枚举初始快照 `build/phase07-discovery-before.json` 与 Release 快照 `build/phase07-discovery-release.json` 的 devices 均为空；这只表示这些时刻系统没有枚举到匹配 HID，不能推断其原因。未将历史 0.6 的硬件结果算作 0.7 新功能验证。

`./scripts/test.sh` 最终 **91 项测试、20 个 suite 全部通过**，日志为 `build/phase07-tests.log`。新增充电状态覆盖：精确请求与 CRC、独立原始抓包响应、0/1 严格枚举、未知值与错误不生成默认状态、busy 不重发、失败关闭句柄、非目标 PID 不打开传输、状态汇总与诊断编码、显式调用/去重/互斥、同 ID 重连/睡眠/停止后的迟到响应丢弃，以及相同 registry ID 下接口指纹改变后清理已成功缓存。

`./scripts/build-app.sh release` 最终成功，Info.plist 为 0.7.0（build 8），ad hoc Hardened Runtime 签名及 strict 验证通过；日志为 `build/phase07-release-build.log`。仍有当前 CLT 缺失 Developer 搜索目录的已知链接警告，未阻止构建。没有新增依赖、网络、权限申请或设备设置命令。

Release CLI `--help` 包含 `--read-charging`。无目标设备时，该选项退出 1，stderr 明确提示未找到唯一可读取充电状态的设备，stdout 为空；见 `build/phase07-charging-unavailable.log` 与 `.stdout`，没有生成假“未充电”。互斥读取参数、与 watch 组合、孤立 device-id 四组输入均在启动发现前拒绝，结果见 `build/phase07-cli-argument-checks.json`。

总览充电卡片、菜单栏读数、诊断 schema 5 及错误状态已接入并编译通过。**本轮未进行原生窗口交互验收，也没有完成本机充电状态的真实 Feature Report 查询。** USB 线充电/满电语义、睡眠唤醒、硬件重连、Synapse 并发与性能测量均待硬件可用后验证。固件与键盘私有查询继续关闭，原因和独立适配方向见 [0.7 协议说明](PHASE07_CHARGING_READ.md)。

## 0.8.0 · 2026-10-19（UTC+8）

本轮目标：将 BlackWidow V4 Low-profile TKL HyperSpeed `1532:02D2` 从发现和预览推进到独立、显式的电源状态试读，并清楚保留硬件验证边界。

重新检查固定 PR head `54f9f686ba8c2162a1232c85f98486f4810a258e` 的原始 C 文件，核对 `07/80` 电量、`07/84` 充电、事务 `9F`、USB report index 2 和 report ID 0；结合历史本机 interface 2 的系统属性建立独立适配条件。本轮没有把 fake-driver 数据当作硬件读数，没有使用鼠标的事务或接口，也没有执行 Linux probe 中的模式设置。来源文件 SHA-256、Apple API 依据和剩余疑点见 [0.8 协议说明](PHASE08_KEYBOARD_POWER.md)。

最终 `./scripts/test.sh`：**102 项测试、22 个 suite 全部通过**，见 `build/phase08-tests.log`。新增 11 项测试覆盖精确请求、接口/PID/连接方式与歧义拒绝、0% 有效读数、两字段独立、busy 接收上限与不重发、无效/不匹配/失败响应、打开/发送/接收失败关闭句柄、并发会话串行、显式触发与去重、部分结果保留、分字段重读、schema 6、错误字段拒绝、断连/睡眠/停止后的迟到结果和相同 registry ID 下指纹变化清理。所有新报文均为明确标注的合成测试数据，不是键盘抓包。原有鼠标 DPI 写入测试只使用模拟传输，没有操作设备。

最终 Release 构建与 ad hoc Hardened Runtime 签名、strict 验证通过，Info.plist 为 0.8.0（build 9），见 `build/phase08-release-build.log`。仍有当前 CLT 缺失 Developer 搜索目录的已知链接警告，构建成功。公共报文封装和会话指纹抽到独立模块，原有 Viper 回归测试全部通过。没有新增依赖、后台轮询、网络行为或权限申请。

初始被动快照 `build/phase08-discovery-before.json`、Release 快照 `build/phase08-discovery-release.json` 均没有匹配设备。Release 新增两项键盘 CLI 各自运行时均退出 1、stderr 提示无唯一目标、stdout 为空，没有生成假读数；两项键盘同时读取、与鼠标读取组合、与 watch 组合均在启动发现前拒绝。五项检查见 `build/phase08-cli-checks.json`。

总览试读卡片、菜单栏与能力状态、schema 6 导出已接入并编译通过。**当前没有完成键盘在 macOS 的真实共享打开与查询、输入保持、原生窗口/菜单交互、真实断连/睡眠唤醒和 Synapse 共存验收。** 不应把 102 项测试或 Release 成功写成上述硬件能力已验证。用户此前选择暂不连接设备，本轮没有再次要求连接，也没有发出键盘硬件命令。性能未重新测量，不提供新的 CPU/内存结论。

## 0.8.1 · 2026-10-19（UTC+8）

本轮仅精简 UI 文案、视觉和导航入口，修复设置版本显示，诊断版本标识更新为 `0.8.1-interface-polish`，schema 仍为 6。没有调整硬件适配与读写流程。

现有 **102 项测试 / 22 suites 通过**，见 `build/phase081-tests.log`；最终 Release 构建、ad hoc Hardened Runtime 签名及 strict 验证通过，Info.plist 0.8.1 / build 10，见 `build/phase081-release-build.log`。当前 CLT 的已知 Developer 搜索路径警告仍存在。被动 CLI 快照 `build/phase081-passive.json` 的 devices 为空、mode 为 discovery-only，没有发送 Feature 查询。

使用 Computer Use 在实际 Release 原生窗口验收：新无设备页点击目录、无结果搜索提示、已收录 PID `010D` 匹配 1 项、清除按钮恢复 273 项、设置版本 0.8.1、更多菜单的导出入口及取消。没有保存/覆盖任何用户文件、改变系统外观或执行设备操作。导出面板的独立截图存在工具捕获异常，不能作为视觉验收证据；设置折叠项展开、浅色与紧凑窗口仍未完成验证。

可复核截图位于 `build/ui081/empty.jpg`、`catalog.jpg`、`no-results.jpg`、`settings.jpg`。设备详情、性能、档案与灯光的文案精简已编译通过，但本轮没有连接设备逐页验收。未新增 UI 单元测试来断言文案，也未重新测量性能。
