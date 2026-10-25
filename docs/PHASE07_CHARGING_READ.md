# 0.7：Viper V4 Pro 充电状态只读查询

日期：2026-10-19（UTC+8）。本轮按用户选择先完成代码与测试，没有连接目标设备进行查询验证。不能把公开抓包中的成功响应称为本机实测结果。

## 来源与精确语义

固定参考为 OpenMouse `54c68c69bbd0bcd750cf10a4e439148e634c02db` 的 [Viper V4 Pro 适配器](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/drivers/razer/viper-v4-pro-hid.ts)，第 69 行显式使用 `07/84`、size 2、参数 `[00,00]`，第 79 行用返回的第二个字节判断充电。这里只独立实现已核对的协议事实，没有移植该 AGPL 项目的代码或资产。

原始控制传输归档来自 [OpenRazer #2760](https://github.com/openrazer/openrazer/issues/2760#issuecomment-4933462400)。本地 `.research/viper-capture.zip` SHA-256 为 `746a881e02604cab1145ca6cbe1c7165720a102cb7bd62aad17b867dd9fc3411`，档案 README 说明固件为 `1.1.1.0`、Synapse 为 `4.0.662`。重新逐条检查 pcap 记录中的 90 字节报文与 XOR 校验，得到以下独立证据：

| 文件、记录号（从 1 开始） | 原始前 10 字节 | 含义 |
| --- | --- | --- |
| wired-polling，1 | `00 1A 00 00 00 02 07 84 00 00` | 充电查询请求，CRC `81`。 |
| wired-polling，4 | `02 1A 00 00 00 02 07 84 00 01` | 有线成功响应，充电标志 1，CRC `80`。 |
| wireless-config，1 | `00 1B 00 00 00 02 07 84 00 00` | `00E6` 无线接收器路径同形请求。 |
| wireless-config，4 | `02 1B 00 00 00 02 07 84 00 00` | 无线成功响应，充电标志 0，CRC `81`。 |
| wireless-dongle-indicators，1 / 4 / 6 | 请求 `00 1A…` / busy `01 1A…` / 成功 `02 1A…` | 无线状态查询可能先 busy，再成功；不需要重新发送请求。 |

文件名均有前缀 `viper-v4-pro-` 与后缀 `-control-only.pcap`。wired-polling 文件 SHA-256 `c08f4af9a2de7196fc2bc8dbcb45fa253381bc4c52f0578f6c35db8fff7dee05`；wireless-config 为 `74f3e67def9ccdc2dcb24266cee198e07dc779c8272f912d48dc9780ea479197`；wireless-dongle-indicators 为 `2275980dfc6d441958e9f89fe73aff290b392c18ddd51eb8a0ab66c8b745e25e`。

RazerLite 使用当前已有事务值 `1F`，标准请求为：

```text
00 1F 00 00 00 02 07 84 00 00 [00 × 78] 81 00
```

传输仍为 report ID 0、Feature Report 90 字节，CRC 是字节 2…87 XOR，位于 88。成功报文必须通过已有长度、CRC、保留头部、事务及命令匹配检查，再要求 payload **恰好 2 字节，首字节 00，第二字节只能为 00 或 01**。未知枚举、截断、失败与超时只生成错误，不生成默认状态。`00` 的显示为“未充电”，不能推断满电、放电、电缆连接或实时无线在线。

测试中的两个抓包样本独立于请求 builder 构造，只对齐事务字段以符合本客户端的回显检查；其他字段与 CRC 保留原值。事务字段不参与 CRC。

## 软件边界与生命周期

- 仍只允许 `1532:00E6`、USB、非虚拟、唯一匹配的 interface 3、Usage `0C/01`、Feature 90、Input/Output 0 的现有适配器。不会因协议形状相同而扩大到 `00E5`、蓝牙、键盘或目录中的其他 PID。
- 总览中的“读取充电状态”是独立操作；原有“读取状态”仍只查询电量与 DPI。无需电量成功或大于零才能读取充电标志。
- 与电量/DPI、回报率和 DPI 准备/写入互斥；全进程复用同一串行 HID 队列。请求仅发送一次，busy 只重读响应，最多 16 次；35 ms 等待与同步 IOKit 调用沿用现有客户端，不能据此承诺整体硬超时。
- 每次手动重读清掉旧充电结果；断连、接口指纹变化、睡眠和停止清理缓存与请求 token。迟到结果不写入新会话。已提交给系统的同步 I/O 无法撤回。
- UI 显示来源、时间、未知/失败与错误分类，菜单栏仅展示已取得的结果。schema 5 导出 `chargingReadouts` 与汇总状态；没有自动轮询或启动查询。

## 固件与键盘的独立审查

同一精确型号 OpenMouse 适配器第 91 行返回 `firmware: []`，没有建立可直接复用的固件解码依据。本轮保留固件为未实现，没有将 HID `VersionNumber` 或 `bcdDevice` 当成固件版本，没有套用其他鼠标的固件查询。

BlackWidow Low-profile TKL HyperSpeed `1532:02D2` 有不同的公开路径。固定 [OpenRazer PR #2912](https://github.com/openrazer/openrazer/pull/2912) head `54f9f686ba8c2162a1232c85f98486f4810a258e` 的补丁将无线型号加入 report/response index **2** 与事务 **9F** 的分支；有线 `02D4` 则是 index 3、事务 1F。补丁增加 `get_battery` / `is_charging` 能力，但其 fake-driver 样本的 255、1 和 v1.0 只是测试数据，不是本机读数。固定源码还在 probe 路径执行设备模式设置，不能将整段驱动初始化当成只读探测移植。

因此没有对 `02D2` 使用鼠标的 interface 3 / 1F 查询。下一步应在设备可用时先核对实际 interface 2 的 HID 描述、输入集合及共享打开条件，再把其独立请求/响应和初始化依赖审查完整；不能以普通键盘输入正常来证明私有协议可用，也不能默认执行模式设置。

## 运行与验证

```sh
./scripts/test.sh
./scripts/build-app.sh release
./build/razerlite-probe --help
./build/razerlite-probe                     # 被动枚举
./build/razerlite-probe --read-charging     # 设备连接后，单次只读查询
```

接多台匹配设备时添加 `--device-id`，使用本次枚举 ID。目标不存在时 CLI 退出 1，stderr 明确提示未找到唯一设备，不生成“未充电”假结果。读取后会再次枚举并精确比较设备身份，身份变化则不导出旧读数。

待硬件验收：`00E6` 真机成功与失败响应、USB 线充电时同一接收器路径是否仍可返回状态、满电时标志含义、断连与睡眠唤醒、与 Synapse 并发、本机 UI 充电面板及菜单栏。若改为直连 `00E5`，本版本应拒绝私有查询；需独立适配后才能验证。不得为制造“充电中”状态而自动改动板载参数。
