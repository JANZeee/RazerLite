# RazerLite

原生 SwiftUI 菜单栏应用，本地管理 macOS 上的雷蛇外设。当前为 **0.10.2：独立电量读取、可选低频调度与低电量提醒**。无需账号、云服务或第三方运行时。

| 范围 | 当前能力与验证边界 |
| --- | --- |
| 电量体验 | 独立手动电量读取不附带 DPI 查询；默认关闭自动刷新和提醒。调度含休眠暂停、退避及快照预算，目前仅离线应用开放，真实后端待真机和性能验收。提醒只处理新设备读数，不使用系统缓存；系统通知授权与投递待实测。 |
| 读取可靠性 | 断连、睡眠和取消使旧结果失效；底层返回前保留设备占用。失败后可查看单独标注时间和来源的上次成功值；不会将旧值当成当前读数。 |
| 适配与诊断 | 每项分别展示代码实现、历史验证和本次结果；接口匹配条件与适配清单共用。目录保留 273 条上游参考，并补充未收录的两款内置 USB 适配。工具栏和空设备页可打开“检查连接”，页面本身不查询设备。 |
| 设备发现 | 枚举系统可见的 Razer HID、聚合接口、监听热插拔；USB VID `1532`，蓝牙侧 `068E` 仅接受 Bluetooth/BLE transport。未知 PID 正常展示；273 条型号目录仅供参考，不代表私有功能已支持。 |
| Viper V4 Pro `1532:00E6` USB | 电量、X/Y DPI、全部 DPI 档位与配置回报率曾在本机读回；一次明确授权的第 3 档 2800/2800 写入已验证。当前充电查询已实现，待真机验收。不同固件与连接方式不自动继承兼容性。 |
| BlackWidow V4 Low-profile TKL `1532:02D2` USB | 电量和充电为独立试验适配，模拟协议测试通过，真实 macOS 查询待验证。 |
| 蓝牙系统电量 | 优先同节点 HID 属性，缺失时按地址、VID/PID 精确关联一次有时限的系统快照；`BSK MOBILE 068E:00D5` 曾读到 100%。显示系统缓存及应用取得时间，不保存地址或原始快照。 |
| 本地档案 | 无外设也能创建、编辑、复制、搜索、导入/导出 DPI 预设。当前目标仅 Viper `00E6` USB；载入只填编辑器，应用仍需逐次检查与明确确认。JSON schema 1，文件上限 1 MiB。 |
| 设置与菜单栏 | 跟随系统/浅色/深色，关闭主窗口后保留菜单栏或退出，恢复顶层页面和原生窗口位置/尺寸。默认保留菜单栏。设置不保存设备会话、读数、写入许可，也不自动恢复设备参数。 |
| 登录时启动 | macOS 13+ `SMAppService`，仅用户操作触发注册，界面读取实际系统状态。缓存构建禁止开启；提供稳定安装脚本。系统注册、注销后重新登录及 Developer ID 分发仍待验收。 |
| 尚未实现 | 设备 RGB、回报率设置、固件查询、按键映射、宏、板载档案和自动应用。键盘灯光页仅为本地预览。 |

默认启动、刷新和热插拔只读系统属性；菜单展开不查询设备。手动查询只打开白名单中的非输入接口，使用已审查的请求。参数修改另走检查、明确确认、单次许可和完整读回；不独占外设、不捕获输入、默认不自动轮询；生产后端自动电量尚未开放。

本轮没有新增硬件兼容性结论，175 项测试通过。变更与验收见 [0.10.2 记录](docs/PHASE0102_BATTERY.md)，读取生命周期见 [0.10.1 记录](docs/PHASE0101_READ_LIFECYCLE.md)，适配清单与连接诊断见 [0.10.0 记录](docs/PHASE010_CAPABILITIES.md)。性能仍参考 [0.9.2 记录](docs/PHASE092_PREFERENCES.md)，本版本未重测性能。历史协议和功能说明见 [功能演进](docs/FEATURE_HISTORY.md)、[验证记录](docs/VALIDATION.md)。下一阶段见 [更新开发计划](docs/NEXT_DEVELOPMENT_PLAN.md)，包含雷云及开源项目对照、优先级和验收条件。

没有外设时可运行 `./scripts/build-scenarios.sh`，打开 `build/RazerLite-Scenarios.app`。13 个场景替换所有设备服务（新增刷新失败与历史值场景），档案保存在临时目录；界面设置使用独立的 `local.RazerLite.Scenarios.Preferences` 域，不影响正式版。所有模拟界面与诊断均标注来源，Release 不含场景实现。说明见 [离线场景](docs/PHASE09_OFFLINE_SCENARIOS.md)。

## 环境与运行

需要 macOS、Apple Swift 6.2 或更新版本、macOS SDK。无需 Homebrew、第三方库或完整 Xcode。已在本机 macOS 27.2 arm64 / CLT Swift 6.4 实测。部署目标为 macOS 13，旧版本及 Intel 尚未真机验证；当前工具链附带的 Swift Testing 测试运行时要求 macOS 14+。

```sh
./scripts/test.sh
./scripts/build-app.sh
open build/RazerLite.app
```

默认关闭主窗口后菜单栏继续监听插拔；菜单栏可重开窗口、刷新或退出。可在设置中改变关闭行为与外观。关闭主窗口会使待确认的 DPI 计划失效。

脚本默认构建 Release；开发时可运行 `./scripts/build-app.sh debug`。使用现有 Apple SDK，不下载依赖。编译缓存存于 `$TMPDIR/RazerLite-build-<工作目录校验值>`，避免 Documents 文件提供程序给测试 bundle 附加 FinderInfo 而影响签名；可用 `RAZERLITE_BUILD_PATH` 指向其他**本地、非同步**缓存目录。产物仍在本项目 `build/`。

`test.sh` 使用自带 Swift Testing，显式加载当前 CLT 中存在的 Testing 宏插件；不使用缺失的 XCTest。SDK 27 的新 `@State` 宏插件在当前 CLT 中缺失，界面使用同样公开、稳定的 `StateObject` + `ObservableObject` 管理选择状态。

本地 `.app` 使用 ad hoc 签名及 Hardened Runtime，未经过 Developer ID 签名或公证，不是公开发布包。Documents 文件提供程序会重加 FinderInfo，因此 `build/RazerLite.app` 链接到 `~/Library/Caches/RazerLite/<工作目录校验值>/RazerLite.app`。缓存可被清理，重新构建即可恢复。脚本只处理自身产物，无需 sudo、SIP 修改或安装驱动。没有自动更新、网络请求或遥测。

需要稳定安装位置时，在 Release 构建后执行：

```sh
./scripts/install-local.sh
# 更新前退出已安装副本；旧包会保留在 Application Support/RazerLite/InstallBackups。
./scripts/install-local.sh --replace
```

安装到 `~/Applications/RazerLite.app`；脚本不启动应用、不注册登录项、不覆盖档案。随后从该位置打开，在设置中自行开启“登录时启动”。系统可能要求批准，注册失败会显示错误；代码签名检查成功不等于登录启动已验收。

## 诊断与调试

```sh
# 默认仅 Razer；stdout 为 JSON，stderr 为诊断耗时/事件。
./build/razerlite-probe > build/devices.json

# 枚举所有系统可见 HID 接口（不读取输入）。
./build/razerlite-probe --all > build/all-hid.json

# 监听插拔 30 秒；输出最终快照，不会轮询设备。
./build/razerlite-probe --watch 30 > build/after-hotplug.json

# 显式读取一个匹配的 Viper V4 Pro USB 接收器：电量 + DPI，绝不设置参数。
./build/razerlite-probe --read-mouse > build/mouse-status.json

# 按需读取一台蓝牙 Razer 的系统电量，不发送 HID Feature Report。
./build/razerlite-probe --read-system-battery > build/system-battery.json

# Viper V4 Pro 独立回报率配置读回，不改变频率，不测量输入事件。
./build/razerlite-probe --read-polling-rate > build/polling-rate.json

# 独立读取同一已适配接口的充电标志，不读取 DPI 或改变设置。
./build/razerlite-probe --read-charging > build/charging.json

# 02D2 USB 键盘试验查询，一次只选一项；硬件兼容性尚待验证。
./build/razerlite-probe --read-keyboard-battery > build/keyboard-battery.json
./build/razerlite-probe --read-keyboard-charging > build/keyboard-charging.json

# 多台匹配鼠标时，使用本次枚举的 ID 指定其中一台（ID 随重连变化）。
# ./build/razerlite-probe --read-mouse --device-id usb-<ID>

# 服务统一日志；应用内另保留最近 200 条日志。
log show --last 10m --info --predicate 'subsystem == "local.RazerLite"'
```

窗口工具栏“导出诊断”现使用应用内导出页：显示完整文件夹路径与文件名，默认 Downloads，可手动输入已有绝对目录或选择文件夹，点击“保存 JSON”后显示实际结果。采用排他创建，同名文件会明确拒绝，不会覆盖。Release 窗口已实际在 `/private/tmp` 保存并解析成功，也已验证重复保存不改变原文件。此前系统 NSSavePanel 的根因没有确认，当前流程已替代该失效入口；目录选择器和其他目标位置的系统权限仍需按环境验证。

当前 JSON schema 9 保留系统、设备接口及各项读数，adapterManifests、adapterAssessments 与 connectionCheck 分别记录内置适配依据、逐设备实现/证据/会话状态和排查建议。能力会话新增可选 value / previous，并区分等待旧操作结束、读取取消；新增独立 batteryReadouts，旧导出缺少此可选字段仍可解码。模拟模式有顶层 dataOrigin 标识；每个 assessment 也独立标识模拟来源，模拟成功不提升真机证据等级。失败分类区分超时、权限、无系统属性、设备拒绝、协议不匹配等。系统电量不导出蓝牙地址；configuredHertz 表明回报率是配置值。读取失败返回非零 CLI 退出码；设备在读取期间未变化时，仍输出错误和有效的部分值。默认不收集序列号或输入内容。USB 的 VersionNumber / bcdDevice 不当作真实固件版本。

如列表为空，先确认 USB 接收器或蓝牙连接，再手动刷新，并用 `--all`、`hidutil list` 和 `ioreg` 交叉核对。当前版本不以“授予全部隐私权限”作为排障方法。接收器存在不保证无线外设在线。Razer/Synapse 驱动被观察到时，界面会提示，程序不会停止或卸载它们。

## 工程结构

```text
Sources/RazerLite/          App / MenuBar / SwiftUI UI
Sources/RazerLiteCore/
  Core/DeviceManager/      业务状态、设备模型、有限日志
  Core/HIDTransport/       属性读取、非独占 Feature Report 传输
  Core/Protocol/           固定查询编码、响应与校验解析
  Core/Configuration/      可版本化的诊断 JSON
  Devices/DeviceAdapters/  精确 PID + transport 的证据目录
  Devices/Mouse/           Viper V4 Pro 接口白名单与身份检查
  Services/HotplugMonitor/ IOHIDManager 发现与移除事件
  Services/DeviceReadService/ 手动查询服务
  Services/DeviceControlService/ DPI 确认计划、单次许可与读回校验
Sources/RazerLiteProbe/    与 UI 共用核心的只读 CLI
Tests/RazerLiteCoreTests/  分组、能力、诊断、生命周期、模拟报文与查询竞态
Resources/Info.plist       原生 app 元数据
scripts/                   测试、打包、性能采样
docs/                      调研报告、实测结果和后续门槛
```

UI 仅依赖业务核心，不 import IOKit。Transport 只传输，Protocol 编解码，Adapter 匹配具体接口，Service 串行查询，DeviceManager 管理结果和生命周期。DeviceReadRegistry 为 USB 专属协议与通用蓝牙系统元数据分别选择读取后端；型号目录不启用查询。断连、接口身份变化和系统睡眠会清理状态、丢弃旧请求结果；唤醒只刷新枚举。`ProfileService` 独立处理本地 Codable JSON，不持有 Transport、写入计划或设备会话身份。任何实际参数或板载修改都按用户原始要求，先说明具体变更并取得明确确认。

0.6 同时修正菜单栏选档案后的性能页跳转，以及编辑器目标变动后的状态提示；重新载入档案只填本地值。2026-10-19 的 Release 窗口实际读到第 3 档 2846/2846，而本地预设仍为 2800/2800；没有自动恢复到预设，差异原因和板载持久性未作推断。

阅读：[技术可行性与架构](docs/FEASIBILITY.md)、[本地 DPI 档案](docs/LOCAL_PROFILES.md)、[性能测量](docs/PERFORMANCE.md)、[验证记录](docs/VALIDATION.md)、[研究来源 revision](docs/research-sources.json)。
