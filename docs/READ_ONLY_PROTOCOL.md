# Phase 2：Viper V4 Pro 状态查询

> 本文记录 0.2.0 的只读路径；0.3.0 新增的独立确认写入路径见 [DPI 变更说明](DPI_WRITE.md)。原有读取操作仍不设置设备。

2026-10-18。第一批目标为实际连接的 `1532:00E6` USB 接收器，仅提供电量与 DPI 档位查询。不是通用 Razer 报文入口，不支持设置参数、切换模式、板载保存或固件更新。

公开依据：[型号适配器](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/drivers/razer/viper-v4-pro-hid.ts)、[报文与 DPI 格式](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/razer/v4.ts)。Swift 代码根据所审查的协议事实编写，未加入该项目为依赖；合成测试报文明确不作为真机抓包。研究来源与许可证信息继续保留在 FEASIBILITY.md。

| 查询 | class / command | size | 请求参数 |
| --- | --- | --- | --- |
| 电量 | 07 / 80 | 2 | 全零 |
| DPI 档位 | 04 / 86 | 80 | 全零 |

报文长度 90，report ID 0，transaction 1F；校验为字节 2 到 87 的 XOR。电量按返回的第二个参数从 0–255 转为百分比。DPI 含一基当前档位、档位数及每档独立 X/Y 值；未知范围/不完整数据均报错，不钳位伪造数值。

这里的“只读”是设备语义：先通过 SET_REPORT 发送已知查询，再用 GET_REPORT 读取响应，因此总线上确实存在出站请求。它与设置 DPI 的 `04/06`、其他写入命令不同；本项目没有这些设置入口，也不自动执行公开实现中的 mode/probe 初始化写入。

打开接口时只使用普通非独占选项。仅允许精确 VID/PID、USB、非虚拟、interface 3、usage 000C/0001、feature 上限 90 的接口；打开前重新检查 registry identity，重连后不复用旧句柄。不会打开键盘/鼠标标准输入接口，不注册输入回调、不改变输入映射。

一次操作串行完成请求与响应，防止本进程交叉配对。响应需要长度、header、校验、transaction 与 class/command 匹配；忙碌重试有上限。其他程序仍可能并发使用同一端点，检测到不匹配时终止，不篡改响应校验以强行成功。驱动拒绝、断开、超时等保留具体错误，不要求关闭 SIP，也不自动停止官方软件。

仅在用户手动点击或显式 CLI 参数时查询；发现/热插拔/应用启动本身不发 report，无后台轮询。离线测试、真机结果和已知限制见下文。

## 2026-10-18 真机结果

实测环境：macOS 27.2 arm64、M2 Pro；Viper V4 Pro USB 接收器 `1532:00E6`，USB interface 3，usage `000C/0001`，Feature 90 字节、Input/Output 0；VersionNumber 和 bcdDevice 均为 `0101`。这些版本属性不是经协议确认的固件版本。键盘 `1532:02D2` 没有发送控制查询。

初版立即 GET_REPORT 时，第一次只验证了电量 5%，DPI 返回不匹配；第二次返回了事务 `12` 的电量响应而非请求的 `1F`，整次失败。两次均按校验规则停止，没有把错误响应当成功。可能原因包括接收器尚未准备好当前响应，以及现有官方软件并发访问；未通过抓包区分具体原因。

随后在每次发送后加入 **35 ms 后台等待**再第一次接收；保留原有忙碌间隔及最多 16 次接收，不重发请求、不忽略事务或命令不匹配。35 ms 是以已审查 OpenMouse 的忙碌间隔为起点的本机时序调整，**不是厂商公布的 V4 最短等待保证**。OpenRazer 的 [通用传输](https://github.com/openrazer/openrazer/blob/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/driver/razercommon.c) 与 [各型号等待常量](https://github.com/openrazer/openrazer/blob/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/driver/razermouse_driver.h) 也说明等待属于型号相关的传输处理，不能把其他型号常量当成 V4 协议。

改动后 CLI（12:59:36，UTC+8）和 GUI 共用服务（12:59:43）均完整成功；返回值如下：

| 项目 | 设备返回值 |
| --- | --- |
| 电量 | 15% |
| 当前 DPI | X 2846 / Y 2846 |
| 当前档位 | 第 3 档 |
| 全部档位 X/Y | 400/400、800/800、2846/2846、6073/6073、49999/49999 |
| 错误 | 无 |

保留实际返回的非整百数值，不对 DPI 做 50 步进取整。原始本机诊断位于 `build/viper-hardware-read-settle.json` 与 `build/read-ui-preview-final/devices.json`，属于带时间的样本，不是当前实时值或跨固件兼容性证明。官方 Razer.app、GameManagerService 和 DriverKit 均保持运行。两次完整读取不证明并发访问永远可靠；其他程序仍可能覆盖响应，遇到不匹配会显示错误并停止。也未测量总线时序或验证电池计量精度。

本版本使用同步 IOHIDDeviceSetReport/GetReport，单次调用超时由系统/驱动决定；最多 16 次忙碌接收不构成整个操作的硬截止时间。UI 不被 I/O 阻塞，但驱动异常时一次操作可能等待较久。

## 运行与验证

```sh
./scripts/test.sh
./scripts/build-app.sh
open build/RazerLite.app
# 在左侧选 Viper V4 Pro，点击右上角“读取状态”；总览显示电量，性能页显示 DPI。

# 同一核心路径的单次命令行查询；失败/部分成功时退出码为 1，JSON 仍包含错误。
./build/razerlite-probe --read-mouse > build/mouse-status.json
```

26 项离线测试覆盖固定查询帧、CRC/长度/头部、独立 X/Y、非法档位 JSON、有限忙碌处理、不匹配即停、非独占打开失败、部分结果、串行请求、句柄关闭、显式触发与重复点击、断连/停止后的迟到响应丢弃。6 项 CLI 检查覆盖默认枚举、全部 HID、有限事件监听和参数拒绝。测试报文为合成数据；真机记录与自动测试分别保存。

界面使用真实 HID 枚举数据与读取结果；浅色/深色及紧凑宽度通过共享 SwiftUI 内容的 ImageRenderer 检查。该渲染不包含原生窗口外框，不替代实际鼠标点击、拔插、睡眠唤醒测试。随后已在签名的 Release 0.2.0 原生窗口实际点击鼠标、“读取状态”和“性能”：13:02:19 显示读取完成、电量 16%、X/Y 2846、第 3 档及相同的五个档位。此为第三次完整成功读取；该点击验证不等于已完成拔插或睡眠测试。停止/断连后不会把旧查询结果用于新的连接；重读开始时清除旧值，失败显示明确状态，不沿用旧成功值。

尚未验证：拔插/睡眠唤醒中的实际 USB 传输、接收器保留但无线鼠标离线、不同固件、其他 Viper PID、其他 CPU/macOS、长时间与 Synapse 共存。尚未实现：轮询率/固件查询、任何 DPI/RGB/板载写入、键盘控制、配置文件。下一步建议先做用户确认后的一个临时 DPI 变更与读回验证，再逐步添加配置持久化；不能直接把读取成功视为写入安全。
