# 0.8：BlackWidow Low-profile TKL 的独立只读试验适配

日期：2026-10-19（UTC+8）。本阶段目标是把 `1532:02D2` 的接口识别、电量/充电查询、错误处理与测试形成独立适配模块。当前目标设备不可用，**没有进行本机键盘 Feature Report 查询，也没有修改设备模式或配置**。试验入口不能视为已验证的硬件兼容性。

## 已核对的依据

固定参考是 [OpenRazer PR #2912](https://github.com/openrazer/openrazer/pull/2912) head `54f9f686ba8c2162a1232c85f98486f4810a258e`。本轮从该不可变提交下载并只读检查以下文件，没有运行其驱动、脚本或初始化逻辑，也没有移植 GPL 代码。适配器是依据报文字段和接口事实独立实现。

| 来源 | 本地 SHA-256 | 具体依据 |
| --- | --- | --- |
| [razerkbd_driver.c](https://github.com/openrazer/openrazer/blob/54f9f686ba8c2162a1232c85f98486f4810a258e/driver/razerkbd_driver.c) | `aacc295e5931db7d981356903952bc3ccbfa499fda73c1183dbbc0ba8b8291be` | 第 381 行所在分支选择 USB report/response index 2；第 702、752 行所在电量和充电分支选事务 `9F`。 |
| [razerchromacommon.c](https://github.com/openrazer/openrazer/blob/54f9f686ba8c2162a1232c85f98486f4810a258e/driver/razerchromacommon.c) | `3aeaf974d3ecd5b6b3fd405dc22a4383dc1951e1f3c64824f1bdcf4caf852829` | 第 1057–1069 行定义电量 `07/80`、充电 `07/84`、size 2；有效值位于参数第二字节。 |
| [razercommon.c](https://github.com/openrazer/openrazer/blob/54f9f686ba8c2162a1232c85f98486f4810a258e/driver/razercommon.c) | `984c3f95cba20710e84f3eed8a26b1e2eddf0f8b6e5fe8bca51a32166744509e` | report ID 0（USB wValue `0300`），90 字节结构，参数初始为零，CRC 为字节 2…87 XOR。 |

下载文件保存在 `.research/phase08-*.c`。公开补丁的 fake-driver 电量 255、充电 1 和固件 v1.0 只是测试数据，没有用作设备默认值或界面读数。也没有依赖该补丁是否已合并来推断 macOS 兼容性。

历史本机被动快照 `build/phase06-discovery-before.json` 的 `02D2` interface 2 属性为 Usage `01/02`，Input 8、Output 0、Feature 90；该接口存在 Razer DriverKit 绑定。interface 0/1 属于其他输入集合，3/4 的 Feature 大小为 51/64，不是上述控制路由。这个记录解释了为何不能使用 Viper 的 interface 3 / 无输入报告筛选，但不是当前在线证据。

## 允许的请求与严格解析

```text
电量：00 9F 00 00 00 02 07 80 00 00 [00 × 78] 85 00
充电：00 9F 00 00 00 02 07 84 00 00 [00 × 78] 81 00
```

以上是从固定源码字段构造出的规范请求，不是键盘实测抓包。成功响应必须长度 90、CRC 正确、保留头部正确、事务回显 `9F`、class/id 与所请求字段匹配，随后要求 payload 恰好 2 字节且首字节 `00`。公开读取路径只消费第二字节；首字节和精确长度采用保守检查，若真实设备不同应先审查响应，不能自动放宽。

电量按原始 0…255 缩放并四舍五入到整数百分比，0 是有效值。充电只接受 0/1，分别显示“未充电 / 充电中”，未知枚举和失败保持空值。未充电不能证明正在放电、已经充满或没有连接电缆。

电量和充电每次分别执行一个请求，不要求另一项先成功。busy 不当成有效读数，只继续接收；最多接收 16 次，不重发请求。每次查询前及 busy 间采用 35 ms 等待，属于保守软件时序，**不是该型号已经实测的等待保证**。底层同步 IOKit 调用的超时仍由系统/驱动决定，不能把接收次数当成整体硬截止时间。

## macOS 访问与边界

适配条件限定为非虚拟、USB、`1532:02D2`、存在 USB 父节点、唯一 interface 2、Usage `01/02`、Input 8 / Output 0 / Feature 90。PID 邻居 `02D4`、`02D5`、蓝牙、不同接口形状或多个候选均拒绝，不轮流尝试接口、事务或报告 ID。`VersionNumber` 与 `bcdDevice` 只作为会话指纹，不冒充固件版本。

接口也包含输入报告，所以复用传输层时只调用 `IOHIDDeviceOpen(device, 0)`，不使用独占选项。[Apple 的 IOHIDDeviceOpen 文档](https://developer.apple.com/documentation/iokit/1588670-iohiddeviceopen) 将 `kIOHIDOptionsTypeSeizeDevice` 定义为独占打开方式。查询只使用 Feature 类型的 [SetReport](https://developer.apple.com/documentation/iokit/1588656-iohiddevicesetreport) / [GetReport](https://developer.apple.com/documentation/iokit/1588659-iohiddevicegetreport)，没有输入回调、输入队列或键鼠事件处理。共享打开能否在当前 DriverKit/权限环境下完成仍须真机验证，不能由 API 选择推导“绝不会影响输入”。

固定 Linux 驱动在 probe 路径执行模式设置；本实现没有此步骤，也没有任意配置指令。公开源码不能证明模式设置是读取前提；若共享打开失败、命令失败或持续 busy，就报告失败并结束，不自动设置模式、卸载驱动、请求管理员权限或停止官方软件。本阶段也不自动申请输入监控权限。

通用 90 字节封装提取到 `RazerReportCodec`，会话指纹提取到 `HIDInterfaceSession`；它们不选择 PID 或授予查询能力。Viper 与键盘保留各自的接口规则、事务、字段解码和服务。全进程共用 HID 串行队列；同一键盘的两个字段互斥，不自动读取或周期扫描。

## UI、诊断与生命周期

总览提供两个独立试读按钮和试验标识，显示各字段自己的读取/尝试时间及失败类别。菜单栏只展示已取得的数据。界面对应能力仅在当前连接收到有效响应后标为已实现，其他功能仍保持原状态；一个电量响应不启用 RGB、宏、按键或固件查询。

schema 6 新增 `keyboardBatteryReadouts` 与 `keyboardChargingReadouts`，分别记录字段、接口、取得时间、值与错误，并参与读取摘要。重读某项只清除该项旧值，另一项保留自己的时间和状态。断连、睡眠、停止或完整接口指纹改变使缓存与请求 token 失效；迟到响应不能更新新会话。接口指纹含 registry ID、USB 父节点、VID/PID、transport、interface、usage、报告大小、系统版本属性、位置和 registry 类；不保存按键输入。

## 运行和下一次硬件验收

```sh
./scripts/test.sh
./scripts/build-app.sh release
./build/razerlite-probe --help
./build/razerlite-probe                            # 默认被动枚举
./build/razerlite-probe --read-keyboard-battery     # 手动单次试读
./build/razerlite-probe --read-keyboard-charging    # 另一独立字段
```

多台匹配设备使用 `--device-id`。每次只选一个读取选项，不能与 watch 组合。CLI 在导出前重新枚举并比较完整设备身份，变化时不导出旧读数。无匹配设备时退出 1，stderr 提示未找到唯一可试读设备，不生成默认电量 JSON。

设备可用后，先保留正常输入并被动导出接口快照；只对匹配的 `02D2` 路由手动试读电量，再独立试读充电，检查数值、错误和正常输入是否保持。随后验证断连/睡眠后的状态清理、Synapse 共存、菜单栏和原生窗口。若失败，依据具体 IO 返回码和严格响应检查继续调查，不通过切换设备模式来绕过。本阶段尚未完成这些硬件验收，也没有重新测量 CPU/内存或宣称兼容其他固件。
