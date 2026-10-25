# FerrisPulse 参考审查与多设备方向

审查时间：2026-10-18。参考仓库 [Ferris-echo/FerrisPulse](https://github.com/Ferris-echo/FerrisPulse)，固定 revision `57315c5d9c328518839aef140b3c4d894b85129e`。只读取源码，没有运行其构建脚本、程序或设备操作。该项目 LICENSE 为 GPL v3；本轮未移植它的代码或界面资源。

## 可以借鉴的结构

它是 Windows C# / Win32 原生程序，Hardware 下分品牌 helper，由设备管理层汇总设备状态，支持多设备显示。可以参考“发现与设备能力分层”的思路；SetupAPI、HidD_*、注册表和 Windows 蓝牙属性不能直接成为 macOS 后端。

## 必须保留的差异

`RazerDeviceHelper.cs` 的查询会在 Feature 长度至少 90 时尝试多种 transaction ID，并对不同时代设备尝试档位查询/旧 DPI 查询。长度相同不能证明厂商协议相同；RazerLite 不把这种尝试路径启用于任意 PID。

其 PID 名称/归一化表与 OpenRazer 存在冲突：

| PID | FerrisPulse 此 revision 的部分映射 | OpenRazer 固定 revision 的设备表 |
| --- | --- | --- |
| 00A6 | Cobra Pro / 归一到 00A5 | Viper V2 Pro Wireless |
| 007A / 007B | Basilisk Ultimate | Viper Ultimate |
| 00A3 | DeathAdder V2 Pro 的归一化分支 | Cobra |

对照来源：[FerrisPulse RazerDeviceHelper.cs](https://github.com/Ferris-echo/FerrisPulse/blob/57315c5d9c328518839aef140b3c4d894b85129e/src/Hardware/RazerDeviceHelper.cs)、[OpenRazer 设备列表](https://github.com/openrazer/openrazer/blob/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/README.md#device-support)。名称映射冲突说明需要交叉核对，不能推断硬件故障或把全部 PID 共享一个协议。

其 `CreateFallbackDeviceInfo` 在没有可靠状态时可使用 50% 电量、800 DPI 或 1000 Hz；`GenericHidHelper` 也有按报文字节范围寻找可能电量的启发式逻辑。RazerLite 保持缺失值为未知，不把缓存/默认值当作本次设备响应，不从不明字节猜电量。

## 本轮实现

- 原有 IOHIDManager 发现本身只按 VID `1532` 匹配，没有“两款设备白名单”；所有 macOS 可见的该 VID HID 接口均可读名称、VID/PID、传输、usage、报文长度、USB 父节点和系统版本属性。
- 加入 273 条型号/PID 参考事实，来自已审查 OpenRazer revision 的设备列表，附来源链接；这是型号识别数据，不是 macOS 控制兼容性承诺。
- 新增可搜索设备目录，无设备时也可查看；未知 PID 不会被过滤。
- 非专属适配型号显示“刷新基本信息”，只读取系统属性。未知设备保持通用外设，音频/配件不再默认显示鼠标示意或鼠标控制标签。
- 通用枚举不请求输入权限、不打开 HID 句柄、不发送 Feature Report。已有 Viper 私有读取和写入白名单不扩大。
- 回归测试覆盖目录 PID 唯一性、冲突映射、未知 PID、其他品牌同 PID、音频/键盘分类与“型号识别不授予命令能力”。48 项测试、9 组通过。

## 覆盖范围的准确含义

“所有雷蛇设备可读取”首先指 macOS 发布为 Razer VID 的 HID 基本属性。未发布为 HID 的音频/摄像头/USB 设备，需要另加相应系统发现通道；蓝牙设备也可能不发布同样的 VID/PID。当前不能保证所有 Razer 产品都被枚举，更不能保证每款都能返回电量、DPI、固件和 RGB。

下一步应为各协议家族逐步增加只读适配器，记录型号/PID、transport、接口指纹、transaction、命令、响应校验与真机状态。OpenRazer、FerrisPulse 的表格只提供候选证据。没有真机响应的型号必须显示“待验证”，不能通过将产品 ID 强行归一化来宣称支持。通用发现、只读查询、设备写入三者保持独立授权边界。

## 2026-10-18 进一步源码审查

本次通过 GitHub API 查询到的新提交为 `49c92f22aacd5fe83fd91ca680e4ca422cfd41a4`（2026-10-18T12:59:26Z，`feat(valkyrie): complete driver and polling rate / dpi integration`）。只 fetch 对象并用 git show/diff 阅读，参考目录的 checkout 保持先前 revision，没有运行其程序、测试、脚本或硬件操作。

对照旧 revision，新提交增加 Valkyrie 后端、Windows 界面缩放调整、原始输入唤醒处理及雷蛇缓存锁等。BluetoothDeviceHelper、RazerDeviceHardwareState 和 LICENSE 在两次 revision 间没有变化。下述函数与行号均以新提交为准；静态分析发现不等于跨型号实测结论。

### 1. 蓝牙电量并非通用 HID 私有查询

`BluetoothDeviceHelper.QueryByMac`（257 行起）先结合 Windows Classic Bluetooth 状态和 SetupAPI PnP 连接属性，再从 BTHLE/BTHENUM 节点读取 BatteryLevel 与 BatteryTimestamp，择取缓存时间较新的候选。该文件开头提到 GATT，但这个实际读取路径没有直接进行通用 GATT 服务发现和特征值读取，不能仅凭注释当成蓝牙私有协议已实现。

该路径允许地址或 FriendlyName/名称前缀匹配（478 行），并可读取离线缓存后单独返回连接状态。可以借鉴“连接状态、缓存电量、缓存时间分开处理”；RazerLite 继续要求地址与 VID/PID 精确关联，不按同名设备合并，应用取得时间不充当系统缓存实际更新时间。Windows 属性 API 不能直接移植为 macOS 后端。0.5.0 已实现与此方向相近的 macOS 系统数据读取，没有因此获得蓝牙 DPI/RGB 支持。

### 2. 雷蛇覆盖广度依赖多种尝试与回退

`QueryAllRazerDevices`（867 行起）枚举 Windows HID，匹配 vid_1532，在 FeatureReportByteLength >= 90 的接口上尝试 transaction 1F/3F/FF。91 字节路径额外考虑 Windows 报告 ID 前缀。这些是 Windows HID 缓冲区和具体协议的处理条件，不能把“91 字节”直接当作 macOS 设备报告长度要求，也不能以长度作为协议白名单。

主查询链为电量、充电、档位、必要时当前 DPI、回报率。一个重要限制是后续读取在电量查询成功且 rawBatt > 0 的分支内；无电量或原始值为 0 时，这条路径可能不再查询 DPI/回报率。它另外提供 FastQueryDpi 路径，但这不消除主快照路径的依赖。RazerLite 后续应按字段定义读取计划：确认某项不支持时不必阻断其他已知安全字段；传输失败、身份不符或报文校验失败时仍停止后续命令。

新的具体候选线索包括：充电查询 07/84、旧式当前 DPI 04/85、某类高速回报率查询 00/C0。这些只是公开源码中的命令候选，本次没有发送。OpenRazer 的 `razer_attr_read_poll_rate` 对型号分组选择 get_polling_rate/get_polling_rate2、不同 transaction 和解析规则，不能把 FerrisPulse 的单组 8K 映射套到全部型号。下一次硬件读取必须先落实到具体 PID、连接方式、接口和对应实现证据。

另一个静态可见细节：主查询中的 successfulTid 初始化为 1F（957 行），保存到状态（1094 行），该路径没有把实际成功的 tid 赋给它。因此这一缓存字段不能当成已正确协商 transaction 的证明；RazerLite 不依赖它自动选择协议参数。

### 3. 型号身份与实物身份必须分开

雷蛇主查询以 `Razer:1532:<normalized PID>` 构造 normId（941 行），再按 normId 汇总状态。这有助于合并同型号的接口，但键中没有区分同型号的两台实物，也会把部分 wired/dongle PID 归一。静态推断：同型号多台设备存在合并/覆盖风险，不能照搬为 RazerLite 的会话身份。

我们已有 USB 父设备分组、HID registry 会话 ID 和独立 profile 型号匹配，三者应继续分离。USB 与蓝牙也不能因为名称相同就宣称是同一台实物。将来提供用户昵称、主设备和离线历史时，必须先增加可靠的实例标识或由用户明确建立关联，不能直接用 PID 绑定。

此前 PID 名称冲突仍存在；GetDpiCapability（1684 行起）也会按 PID、产品名关键字及默认项推断 DPI 上限/步进。可以参考“每型号单独定义约束”的设计，不导入这些推断值作为已验证能力。

### 4. 状态模型和调度值得参考，但要适应轻量目标

`MouseBatteryInfo` 分开记录 IsConnected、IsSleeping、IsDonglePresent、LastUpdated；`RazerDeviceHardwareState` 记录每设备路径、失败计数和最后成功通信。新提交还把 stateCacheLock 与 hidLock 分开，减少字典读取直接争用通信锁的机会。不过返回的状态对象仍是可变对象，不能只看到两把锁就断言所有状态访问均已安全。

适合我们的改进是区分：系统发现接口、协议通信已验证、通信未确认、读数过期。接收器仍存在不代表鼠标在线；超时也不直接证明休眠。可保留带明确来源和时间的历史值，但不把历史值显示为当前连接的成功读取。

`MainForm.Events` 在设备变更后安排 250ms 和 1000ms 两次刷新，以应对接口陆续出现。可借鉴有界、可取消的事件合并；RazerLite 的请求/写入许可失效必须在原始移除事件时立即处理，不能为了减少 UI 刷新而延迟安全检查。无需照搬固定两次全量扫描。

该版本通过 WM_INPUT/Raw Input 观察鼠标活动辅助唤醒；DPI OSD 工作线程在活跃时查询后 sleep 50ms、休眠时 sleep 250ms，关闭 OSD 时 sleep 800ms。普通电量刷新默认 60 秒且可配置。这些源码间隔不等于实测资源开销。RazerLite 当前保持手动读取，不默认引入输入监听或高频 DPI 轮询；若以后需要 OSD，先验证设备通知能力，再评估显式开启的采样模式。

### 5. 写入流程与未知值不应直接移植

`TrySetRazerDpiStageByHandle`（1640 行起）读取档位 payload，修改 active stage 后提交 04/06，并用 ACK 返回成功；该函数没有完成完整档位表独立读回。我们已经验证过 Viper V4 GET 与 SET 档位索引存在差异，不能复用这段 payload 复制逻辑。已有的逐次确认、一次写入许可、整表读回以及不自动重试/回滚应继续保留。

默认 50% 电量、800 DPI、1000Hz 以及未知字节猜电量的回退依旧不采用。未知、有效 0%、未发布、不支持、查询失败、历史缓存要分别表达，不能让 UI 值的完整程度代替硬件证据。

新增 Valkyrie 测试包含源码存在/编码/名称检查以及 PowerShell 中独立计算的模拟字段，不直接证明 C# 后端执行路径和全型号真机兼容性。本次没有运行这些测试，也未验证其“全系”覆盖；可作为测试设计线索，不能当成兼容性认证。

### 对 RazerLite 的具体开发顺序

1. **0.6 的状态与诊断**：增加每字段来源、取得时间、结果类型和通信状态；故障原因区分无系统属性、未适配、明确不支持、超时、协议不符。保留导出路径，先解决 GUI 保存面板问题，方便积累真机证据。
2. **事件合并与真机生命周期验收**：对 UI 枚举更新做短时合并，移除即时清理；测试两台同型号、USB hub、鼠标重连、睡眠唤醒，不增加周期扫描。
3. **更多只读状态**：从已验证 Viper USB 适配器和公开证据匹配的候选型号开始，逐项研究充电/固件/回报率；先离线报文测试，再单次真机读取。当前 BSK MOBILE 的蓝牙 DPI 没有因本次审查获得可用协议。
4. **再增加体验功能**：修复菜单栏档案到性能页的跳转、目标值编辑后的状态文案，再考虑设备昵称、主设备、低电量提醒和可选刷新。持久身份可靠之前不自动合并多连接或多实物。

本次交付为研究结论和下一轮方案，没有修改 RazerLite 可执行代码、扩大设备命令白名单或发送任何新报文，因此不重复构建已有 0.5.0。以后若复用源码，需要按具体文件许可证处理；本次没有复制第三方实现到应用。

### 固定 revision 来源

- [雷蛇发现、查询与写入](https://github.com/Ferris-echo/FerrisPulse/blob/49c92f22aacd5fe83fd91ca680e4ca422cfd41a4/src/Hardware/RazerDeviceHelper.cs)
- [Windows 蓝牙系统属性读取](https://github.com/Ferris-echo/FerrisPulse/blob/49c92f22aacd5fe83fd91ca680e4ca422cfd41a4/src/Hardware/BluetoothDeviceHelper.cs)
- [设备汇总与去重](https://github.com/Ferris-echo/FerrisPulse/blob/49c92f22aacd5fe83fd91ca680e4ca422cfd41a4/src/Hardware/DeviceManager.cs)
- [通用 HID 启发式读取](https://github.com/Ferris-echo/FerrisPulse/blob/49c92f22aacd5fe83fd91ca680e4ca422cfd41a4/src/Hardware/GenericHidHelper.cs)
- [设备消息和唤醒处理](https://github.com/Ferris-echo/FerrisPulse/blob/49c92f22aacd5fe83fd91ca680e4ca422cfd41a4/src/UI/Forms/MainForm.Events.cs)
- [后台刷新与 DPI OSD](https://github.com/Ferris-echo/FerrisPulse/blob/49c92f22aacd5fe83fd91ca680e4ca422cfd41a4/src/UI/Forms/MainForm.Hardware.cs)
- [状态对象](https://github.com/Ferris-echo/FerrisPulse/blob/49c92f22aacd5fe83fd91ca680e4ca422cfd41a4/src/Models/RazerDeviceHardwareState.cs)
- [新增模拟/静态检查示例](https://github.com/Ferris-echo/FerrisPulse/blob/49c92f22aacd5fe83fd91ca680e4ca422cfd41a4/tests/test_valkyrie_integration.ps1)
- [OpenRazer 回报率分型号路径](https://github.com/openrazer/openrazer/blob/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/driver/razermouse_driver.c)
