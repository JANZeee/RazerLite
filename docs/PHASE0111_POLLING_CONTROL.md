# 0.11.1：回报率配置设置

日期：2026-11-03。版本 0.11.1 / build 19。新增设置的软件流程已完成，真实设备写入、跨重启持久性与实际输入频率均未验证。本轮没有发送真实设置命令；完成离线开发后，对已接入且匹配的 Viper 做了一次已有回报率 GET 查询，结果见下文。

## 用户操作

在已适配 Viper 的“性能 → 回报率配置”中选择目标，点击“检查回报率变更…”，核对当前与目标值后明确确认。选择频率不会发送命令；检查阶段只查询配置。选项为 125、500、1000、2000、4000、8000 Hz；不提供没有依据的 250 Hz。

确认可能引起无线链路短暂重配，不承诺临时保存。计划在 60 秒后失效，提交前重新读取配置；如果配置变化则中止。设置只发送一次，busy 只继续接收响应，绝不重发设置；成功 ACK 后等待 150 ms，再读回配置。结果不一致或 I/O 出错显示未完成验证，不自动重试或回滚。这里的 Hz 是配置读回，不是输入频率测量。

只有 `1532:00E6` USB，唯一 interface 3 / Usage 0x0C:1 / I/O/F 0/0/90 可以进入该路径。不同 PID、接口、蓝牙和固件不自动继承兼容性。当前实际固件版本未知，界面明确标为试验性设置。

## 协议证据

固定核对 [OpenMouse 的 Viper V4 客户端](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/drivers/razer/viper-v4-pro-hid.ts)中的 `setPollingRate`，以及[该 revision 的 V4 定义](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/razer/v4.ts)。其精确型号实现使用 SET `00/40`、两字节参数 `[01, code]`、150 ms 重配等待、GET `00/C0` 读回。这是协议事实核对，本轮没有复制或执行上游代码。

同时复核 [OpenRazer #2760 的公开归档](https://github.com/openrazer/openrazer/issues/2760#issuecomment-4933462400)。本地 `.research/viper-capture.zip` SHA-256 仍为 `746a881e02604cab1145ca6cbe1c7165720a102cb7bd62aad17b867dd9fc3411`。归档说明固件为 1.1.1.0、Synapse 4.0.662，来自 Windows USBPcap；不是本机 macOS 写入记录。

用 Python 标准库读取 zip 和 PCAP 记录，检查最后 90 字节的 class/id、长度、CRC、payload 与填充。下列编号按文件中 PCAP 记录计数，不是 USB 包序号。

| 文件与 SHA-256 | SET / 响应 / GET 读回记录 | 观察 |
| --- | --- | --- |
| `viper-v4-pro-wired-polling-control-only.pcap`，`c08f4af9a2de7196fc2bc8dbcb45fa253381bc4c52f0578f6c35db8fff7dee05` | 21/24/28、33/36/40、45/48/52、57/60/64、69/72/76、81/84/88 | 六个 Hz 值对应 code `40/10/08/04/02/01`。成功设置响应 payload 精确回显 `[01, code]`。这是有线 `00E5` 抓包。 |
| `viper-v4-pro-wireless-config-control-only.pcap`，`74f3e67def9ccdc2dcb24266cee198e07dc779c8272f912d48dc9780ea479197` | 143/146/148/149/152/154 | `00E6` 设置 1000 Hz：SET → busy → success → GET → busy → 1000 Hz。无线抓包只在该变更直接证明设置 1000 Hz；其他值的依据包含上述有线样本和精确型号公开实现。 |

RazerLite 使用既有 transaction `1F`、report ID 0、90 字节报文；不同于抓包中变化的事务计数。参数长度为 2，selector 为 `01`。CRC 是字节 2…87 的 XOR，位置 88。以 2000 Hz 为例：

```text
SET: 00 1F 00 00 00 02 00 40 01 04 [00 × 78] 47 00
ACK: 02 1F 00 00 00 02 00 40 01 04 [00 × 78] 47 00
GET: 00 1F 00 00 00 02 00 C0 01 00 [00 × 78] C3 00
读回:02 1F 00 00 00 02 00 C0 01 04 [00 × 78] C7 00
```

响应必须通过通用长度、CRC、事务、命令及状态检查；ACK 还必须完整回显目标参数。保守拒绝未知响应格式，不把“发送成功”当作设置成功。[0.6 记录](PHASE06_PROTOCOL_REVIEW.md)中禁止设置的描述仅针对历史只读版本；原有读取服务和 CLI 默认行为没有变化。

## 业务与生命周期

- Transport 仍只传输；新协议编码器、新控制服务、DeviceManager 与 SwiftUI 各自负责对应层。复用现有串行 I/O 执行器和设备会话协调器。
- DPI 与回报率共用原有一次性许可机制，提取为 `DeviceWritePermit`；没有扩展原 DPI 授权范围。两种待确认操作与手动/自动读取互斥，不抢占同一物理接口。
- 取消、离开编辑页会撤销回报率确认；准备中的同步请求保留占用直到返回。关闭主窗口、睡眠、停止和断连撤销相关许可；已经发出的 USB 请求无法撤回，迟到结果不能恢复新会话的状态。
- 写入开始后旧电量、DPI、充电和回报率只保留为历史样本，不再作为当前读数。只有完整校验通过的回报率进入当前配置显示。
- 诊断升级 schema 10，增加可选 `pollingWriteResults`，保留历史 JSON 解码兼容性。尚未返回的设置操作即使跨睡眠或重启发现服务，也不会被误标成“从未发送设置”。适配清单将回报率设置标为“模拟协议通过”，不会因模拟成功升级为真机验证。
- 没有新增运行时依赖、定时器、网络或自动写入。150 ms 等待仅发生在用户确认的一次操作中，位于现有后台 I/O 队列，不阻塞 UI。

## 验证

195 项测试 / 36 个 suite 通过。新增 13 项测试覆盖六档完整设置帧、CRC、准备阶段 GET-only、busy 不重发、ACK 错误/截断/目标不一致、配置变化、取消和过期、I/O 中断、读回失败、双设备隔离、DPI/读取互斥、重复确认、睡眠/断连/停止/任务取消后的迟到结果丢弃及占用释放。现有 DPI 测试继续通过。

原生离线窗口实际操作了选择 2000 Hz、检查、取消、重新检查、确认模拟应用，取得 2000 Hz 配置显示且相同目标不可再次提交。随后将“设置结果”切为“模拟读回不一致”，尝试 4000 Hz；界面保持当前频率未知并显示不一致，手动读取后恢复为假设备的 2000 Hz。没有把 4000 Hz 目标冒充成功结果。辅助功能记录在 `build/ui0111/native/`；本轮截图工具输出缩略图，不能据此声称完成精细像素布局验收。

Debug 离线应用与 Release 构建、严格 ad hoc 签名检查通过；正式版重启后已实际检查两台设备的发现页面和 Viper 新设置入口，页面切换不自动读取或应用参数。构建记录为 `build/phase0111-scenarios-build.log`、`build/phase0111-release-build.log`，测试记录为 `build/phase0111-tests.log`。真实设备自动电量资格仍关闭；本轮没有性能重新采样、真实输入频率测量或公证发布。

```sh
./scripts/test.sh
./scripts/build-scenarios.sh
open -n build/RazerLite-Scenarios.app --args --scenario mouse

./scripts/build-app.sh release
open build/RazerLite.app
# 被动发现；不发送设备私有查询或设置命令
./build/razerlite-probe > build/phase0111-discovery.json
```

## 本轮真实连接的只读复验

最终被动枚举发现 2 个物理设备、9 个 HID 接口。系统名称分别为 `Razer Viper V4 Pro 1532:00E6` 和 `Razer Reclusa Mini 65% 1532:02F5`。后者本轮只有被动发现，不尝试套用 `02D2` 键盘协议。

对唯一匹配的 Viper 使用 `--read-polling-rate --device-id usb-4295987222` 执行一次既有 `00/C0` 查询，接口 ID `4295987237`，取得 **1000 Hz**，没有 issue。读数时间 `2026-11-03T12:01:29Z`，即新加坡时间 20:01:29。诊断 `build/phase0111-polling-read-live.json` 的 mode 为 `manual-status-queries; no setting commands`，SHA-256 `99979906675cdededc77ba54e0410e72336cee2f081f68109ba4cc94e39eeb03`。

这只复验了当前连接的既有 GET 路径，未验证新增 SET，也不测量实际输入频率。没有改变回报率、DPI 或键盘设置。

真实设置验收时，先重新只读确认身份和当前配置，再由用户明确同意具体目标进行一次设置与读回；观察输入与无线链路、重连、断电后的行为，并记录其他驱动是否运行。每次写入单独确认，不自动恢复原值，不自动停止 Synapse。下一步基础功能范围见 [开发计划](NEXT_DEVELOPMENT_PLAN.md)。
