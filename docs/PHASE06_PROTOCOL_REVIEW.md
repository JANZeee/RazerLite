# Phase 0.6：Viper V4 Pro 回报率配置只读协议审查

日期：2026-10-19。范围仅限实际接收器型号 `1532:00E6` 的 USB interface 3 / Feature Report 90 字节路径。本文审查本地固定的公开源码和原始抓包；**本次审查没有打开 HID 接口、没有发送设备命令，也没有改变设备配置。**

结论：`00/C0` 可以作为一个独立、显式触发的“设备回报率配置读回”功能。它不能测量鼠标实际发出的输入报告频率，也不能证明当前无线链路实际运行在该频率。0.6 不发送 `00/40`，不提供设置入口。

## 固定证据

| 证据 | 固定版本与定位 | 用途 |
| --- | --- | --- |
| 控制传输归档 | `.research/viper-capture.zip` SHA-256 `746a881e02604cab1145ca6cbe1c7165720a102cb7bd62aad17b867dd9fc3411` | 14 个归档成员均与归档内 `SHA256SUMS.txt` 匹配。README 第 3、23、28、35–38 行说明了设备、传输、命令和无线状态。 |
| 有线回报率抓包 | `viper-v4-pro-wired-polling-control-only.pcap` SHA-256 `c08f4af9a2de7196fc2bc8dbcb45fa253381bc4c52f0578f6c35db8fff7dee05`（`SHA256SUMS.txt:3`） | 验证 GET 请求和全部六个编码。 |
| `00E6` 无线配置抓包 | `viper-v4-pro-wireless-config-control-only.pcap` SHA-256 `74f3e67def9ccdc2dcb24266cee198e07dc779c8272f912d48dc9780ea479197`（`SHA256SUMS.txt:7`） | 验证无线 `busy` 后的成功读回。 |
| `00E6` 重连抓包 | `viper-v4-pro-wireless-reconnect-control-only.pcap` SHA-256 `57edbb53b22b095a8ecc99dcf5eff8fc581e8805c1fde9e0be6e28e5c8920a71`（`SHA256SUMS.txt:13`） | 验证鼠标断电而接收器仍枚举时的 status `04`。 |
| 精确型号适配器 | OpenMouse `54c68c69bbd0bcd750cf10a4e439148e634c02db`（`.research/mouse-protocol-commit.json:1`） | [V4 报文定义](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/razer/v4.ts) 第 1–34 行和 [Viper V4 Pro 适配器](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/drivers/razer/viper-v4-pro-hid.ts) 第 62–71、106–114、154–171 行。 |
| 状态码定义 | OpenRazer `477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d`（`.research/openrazer-commit.json:1`） | [`driver_razercommon.h:79–83`](https://github.com/openrazer/openrazer/blob/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/driver/razercommon.h#L79-L83) 定义 `01` busy、`02` successful、`03` failure、`04` timeout、`05` not supported。 |

抓包来自固件 `1.1.1.0` 和 Synapse `4.0.662`（归档 `README.md:3`）。本机的 `VersionNumber`/`bcdDevice` 不是经过协议验证的固件版本，因此不能把该抓包扩展为所有 V4 固件、所有 Razer PID 或蓝牙路径的保证。

## 经核对的 `00/C0` 报文

90 字节 Razer Feature Report 的 CRC 是字节 2…87 的 XOR，放在字节 88；report ID 为 0（归档 `README.md:23`；OpenMouse `src_razer_v4.ts:1–2,13–16`）。对于回报率查询，字段如下。

| 字节 | 请求 | 成功响应 | 含义 |
| --- | --- | --- | --- |
| 0 | `00` | `02` | 请求 / 成功状态；不是 payload 的一部分。 |
| 1 | 当前事务值 | 回显该事务值 | 抓包中的事务计数随连接变化；RazerLite 已有查询实现使用固定 `1F`，不得因另一台抓包的计数器替换它。 |
| 2…4、89 | `00` | `00` | 已捕获的保留字段。 |
| 5 | `02` | **`02`** | payload 长度；GET 不是 1 字节请求或可变长成功响应。 |
| 6 / 7 | `00 / C0` | `00 / C0` | 回报率 GET。 |
| 8 / 9 | **`01 / 00`** | **`01 / code`** | `01` 是经抓包确认的 selector/回显；`code` 是下表中的严格枚举。 |
| 10…87 | `00` | `00` | 所有本次相关样本均为零填充。 |

因此，在当前 `transaction = 1F` 实现中，规范请求是：

```text
00 1F 00 00 00 02 00 C0 01 00 [00 × 78] C3 00
```

例如 2000 Hz 的规范成功响应是：

```text
02 1F 00 00 00 02 00 C0 01 04 [00 × 78] C7 00
```

`C3` 和 `C7` 分别是上述字段按 CRC 规则得到的值。OpenMouse 在其 GET 调用中传入 `new Uint8Array([1])`，但该项目的 builder 会先创建零填充 90 字节数组、声明 `dataSize = 2`，再从字节 8 写入参数（`src_razer_v4.ts:25–33`）。它实际构造的第二个参数字节因此仍是 `00`；不能将源码表面上的一元素数组误解为 1 字节请求。

原始 pcap 的直接样本也消除了这个歧义：

| 文件 / PCAP 记录 | 帧的字节 0…9 | 含义 |
| --- | --- | --- |
| 有线 polling，17 | `00 1E 00 00 00 02 00 C0 01 00` | GET 请求。 |
| 有线 polling，20 | `02 1E 00 00 00 02 00 C0 01 04` | 2000 Hz 成功响应。 |
| 有线 polling，25 / 28 | `00 01 … 01 00` / `02 01 … 01 40` | 125 Hz 成功读回。 |
| 无线 config，89 / 92 / 94 | `00 02 … 01 00` / `01 02 … 01 00` / `02 02 … 01 04` | `00E6` 的请求、busy、2000 Hz 成功响应。 |
| 无线 reconnect，1 / 4 | `00 00 … 01 00` / `04 00 … 01 00` | 鼠标链路未确认时的请求与 timeout 响应。 |

这里的“PCAP 记录”按该 `.pcap` 的 16 字节文件记录顺序计数；每个表项的完整 90 字节报文均通过归档所述 CRC 规则。它们是固定归档中的可复核位置，不是本机实时读取结果。

## 严格枚举和解码边界

| `code` | 配置读回值 |
| --- | --- |
| `40` | 125 Hz |
| `10` | 500 Hz |
| `08` | 1000 Hz |
| `04` | 2000 Hz |
| `02` | 4000 Hz |
| `01` | 8000 Hz |

映射由归档 `README.md:28` 和 OpenMouse `src_razer_v4.ts:8–10,51–55` 一致给出。解码必须要求 **payload 恰好 2 字节且第一个字节为 `01`**，然后只接受上表六个 code。不能按 `8000 / code` 推导未知值，不能补齐截断 payload，也不能把 `00`、`03`、`FF` 显示为有效频率。

`00/40` 是设置命令，参数为 `[01, code]`（OpenMouse 适配器第 106–114 行）。它不属于 0.6，代码、CLI 和 UI 均不应调用它。即使设备语义是“只读查询”，Feature Report 查询本身仍通过 SET_REPORT 发送已知 GET 请求；这与改变回报率的 `00/40` 不同。

## 时序与无线离线状态

抓包只提供样本，不提供厂商最短响应时限。可直接观察到：

- 有线记录 17 → 20 的请求至成功响应约为 13.111 ms。
- `00E6` 无线记录 89 → 92 约为 11.683 ms（busy），89 → 94 约为 19.679 ms（成功）。另一组 137 → 140 / 142 分别约为 12.284 / 21.284 ms。
- OpenMouse 的精确型号实现采用 16 次接收机会和 35 ms busy 间隔（`src_drivers_razer_viper-v4-pro-hid.ts:18–19,154–171`）。RazerLite 的 `ViperV4ControlClient` 保持一次发送、随后只读取响应的模式，不能因 busy 重发 `00/C0`。
- 150 ms 的额外等待只出现在公开实现的**设置**回报率后（同文件第 106–114 行），用于 RF 链路重配；不应加到 0.6 的只读 GET 上。

归档 `README.md:36,38` 和上述重连样本表明：当鼠标关机时，`00E6` 接收器仍可能保留在 USB 列表中，而本次查询返回 status `04`。OpenRazer 的通用名称是 `timeout`，因此可以将其呈现为“设备未确认 / 查询超时”。它不是 USB 拔出、不是已证实的睡眠状态，也不应据此从设备列表移除或声称鼠标必然离线。其他失败状态仍应保留其准确代码和失败上下文；不重试设置命令。

## 与当前 Swift 实现的审查结果

截至本审查，以下路径与证据相符：

- `Sources/RazerLiteCore/Core/Protocol/ViperV4ReadProtocol.swift:5–17,81–90` 将 `.pollingRate` 限定为 `00/C0`、size 2、selector `01`，并生成 `C3` 请求校验。
- 同文件第 123–136 行严格验证 `[01, code]` 和六个枚举；未知数据返回错误，而非显示猜测数值。
- `Sources/RazerLiteCore/Devices/Mouse/ViperV4ControlClient.swift:14–17,24–37` 对一次查询只发送一次，busy 时只执行有限的接收重试。它不含 `00/40`。
- `Sources/RazerLiteCore/Services/DeviceReadService/PollingRateReadService.swift:16–43` 是独立的显式读取服务，不把该 GET 混入既有电量/DPI 的“读取状态”动作。它通过现有严格 `1532:00E6` / interface 3 / usage `000C:0001` / Feature 90 白名单选择接口。
- `Sources/RazerLiteCore/Services/DeviceReadService/ReadFailureKind.swift:87–102` 将设备 status `04` 分类为 `timeout`、`05` 分类为 `unsupported`，其他拒绝状态为 `deviceRejected`；分类不会把接收器从发现列表移除。
- `Tests/RazerLiteCoreTests/PollingRateReadServiceTests.swift` 以独立模拟 transport 覆盖精确请求、busy 不重发、无效 code/selector/长度、非目标 PID 不打开接口、失败后的关闭和与既有鼠标读取共享串行队列。测试帧是离线合成帧或上述公开抓包的字段摘录，不能代替真机结论。

`04` 的具体 UI 分类应保持“timeout/未确认”的窄语义；不要把它升级为“已断开”“已休眠”或删除接收器。由于它来自公开的特定固件/链路状态，未来若出现不同状态字段或固件行为，应保存原始状态码并停止自动推断。

## 配置读回与真实报告率是两件事

`00/C0` 只说明设备返回的配置代码。例如读回 `8000 Hz` 可以用于显示“设备配置读回为 8000 Hz”，却不能证明：

- macOS 收到了每秒 8000 个输入报告；
- 无线链路、接收器、系统节能或应用负载没有降频、合并或丢弃输入；
- 该频率对所有按键、传感器运动和连接方式均相同。

真实报告率验证需要另一项明确标记为“测量”的功能：在用户授权的输入监测条件下记录输入时间戳，说明采样窗口、计数、抖动和 macOS 事件合并限制；或使用外部硬件/总线测量。那不是本次配置查询的一部分，也不应为了读配置而申请 Input Monitoring 权限。

## 0.6 真机验证边界

在离线测试通过后，唯一可执行的硬件步骤是用户显式触发一次独立“读取回报率”按钮或 `--read-polling-rate`。它只发送上文的 `00/C0` GET 请求并读回；无论成功或失败，都不发送 `00/40`，不改变 DPI、板载配置或 RF 设置。结果必须显示为本次连接、当前时刻的“配置读回”，并保留失败状态而非展示旧缓存值。

## 2026-10-19（UTC+8）真机读回

Debug CLI 在实际连接的 `1532:00E6` 接收器上执行了一次显式 `--read-polling-rate`。诊断文件 [`build/phase06-polling-live.json`](../build/phase06-polling-live.json) 的 SHA-256 为 `ec71b26cc822cfe099104cbdcbb33b6830162ab8952ae5265fe7c1d88ff6b288`；其中记录时间为 `2026-10-18T16:30:32Z`（新加坡时间 10 月 19 日 00:30:32），精确查询接口为 `4295591616`（USB interface 3、usage `000C:0001`、Feature 90），设备读回配置为 **1000 Hz**，无 `issue`。诊断 `mode` 是 `manual-status-queries; no setting commands`。

最终 Release 0.6 原生窗口随后在 00:31:28 点击“读取回报率”，独立读回 1000 Hz；界面明确显示“设备配置读回，不是实测输入频率”。通过新导出页保存的 [`build/phase06-ui-diagnostics.json`](../build/phase06-ui-diagnostics.json) 包含该结果和 schema 4 状态。其原始 UI 导出位于 `/private/tmp/RazerLite-phase06-ui-20261019.json`（URL 标准化后界面显示 `/tmp/...`）；复制到项目供复核，没有借此再发送硬件请求。

这证明本次设备与当前连接接受并成功响应了 `00/C0` 的只读路径；它仍不证明真实输入报告率、固件持久性、睡眠/重连行为、其他频率或其他固件版本。本文前文所述的抓包审查本身没有发送硬件命令；该单次操作是审查完成后的独立、显式真机验证。
