# 0.11.2：Reclusa 被动识别与型号来源

日期：2026-11-03。版本 0.11.2 / build 20。范围是设备识别修正，不是新增 RGB 控制。没有发送这把键盘的私有查询或设置命令。

## 已实现

- 本机系统枚举的 `Razer Reclusa Mini 65% / 1532:02F5 / USB`，此前因同时发布鼠标和键盘 Usage 而显示为通用外设；现在显示键盘类型、图标与示意图。
- 独立保存本机观察记录，不修改 OpenRazer 的 273 条固定版本目录。目录合并上游参考、两款内置 USB 适配和一条本机记录，并标注来源；收录不授予控制能力。
- 匹配要求所有接口的 VID、PID、USB transport 与产品名一致，且存在键盘 Usage。产品名仅忽略首尾空白与大小写；没有按名称子串或 PID 范围猜测。蓝牙、虚拟 HID、相近 PID、不同名称、混合身份均不继承这条记录。
- 设备信息与诊断导出的来源链接指向本记录，不再把本机观察误归给 OpenRazer。JSON 结构未变，schema 保持 10。
- 增加 Debug 离线场景“Reclusa · 仅识别”。不生成电量读数，不调用私有后端，不显示可应用的灯光或性能控件。

没有增加定时器、依赖、联网流程、权限或输入监听。新增逻辑只在现有属性投影中进行小表匹配。

## 本机观察及限制

macOS 27.2 / Apple Silicon 上，系统在本轮被动枚举中发布以下四个 HID 接口，共享同一 USB 父设备。该观察证明系统发布的身份和接口结构，不证明固件版本、蓝牙 PID、2.4 GHz 模式或私有协议兼容。

| USB interface | Primary Usage page / usage | Input / Output / Feature 最大长度 |
| --- | --- | --- |
| 0 | 0x01 / 0x02 | 8 / 0 / 0 |
| 1 | 0x01 / 0x06 | 48 / 2 / 1 |
| 2 | 0x01 / 0x06 | 8 / 1 / 0 |
| 3 | 0x0C / 0x01 | 0 / 0 / 90 |

90 字节 Feature Report 上限不是命令格式或权限证明，也不能说明它接受 Viper 或 BlackWidow 的命令。固件查询、RGB、电量、按键配置均保持未实现；不把未实现说成硬件不支持。

## 公开来源审查

1. [Razer 官方产品页](https://www.razer.com/gaming-keyboards/razer-reclusa-mini-65)确认 Reclusa Mini 65% 产品名称、RGB 和多模式连接能力，但没有给出 `02F5` 的 HID 控制协议。本文的 PID 关联来自本机系统属性，而非官网宣传。
2. OpenRazer 固定提交 `477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d` 的 [键盘 PID 定义](https://github.com/openrazer/openrazer/blob/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/driver/razerkbd_driver.h)与[键盘驱动](https://github.com/openrazer/openrazer/blob/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/driver/razerkbd_driver.c)均未找到 `02F5` 或 Reclusa 的精确条目。[issue #2932](https://github.com/openrazer/openrazer/issues/2932)讨论的是 **Reclusa X Mini 65% / 02E3**，不是当前设备；支持请求不能当作已验证驱动。
3. FerrisPulse 固定提交 `eccb3802eef1aef036d17e65bc57ce1621884461` 的 [RazerDeviceHelper.cs](https://github.com/Ferris-echo/FerrisPulse/blob/eccb3802eef1aef036d17e65bc57ce1621884461/src/Hardware/RazerDeviceHelper.cs)中未找到 `02F5` 或 Reclusa。其 `GetRazerDeviceCategory` 用名称关键词及 PID 范围分类；这可解释其界面分类思路，但不能证明某型号的灯光指令有效。RazerLite 仅借鉴身份展示与控制能力分离的设计，不移植宽泛分类为命令白名单。

这些结论仅针对上述审查范围，不表示互联网上不存在其他实现。本轮没有复制上游驱动代码。

## 验证与运行

```sh
./scripts/test.sh
./scripts/build-scenarios.sh
./scripts/build-app.sh release
./build/razerlite-probe > build/reclusa-passive-discovery.json
```

最后一条默认只枚举系统属性，不执行 Feature Report 查询或设置。诊断中的 `sourceURL` 应指向本记录，RGB 等能力应为 `notImplemented`，可用能力仅有 `discovery`。

新增测试覆盖复合键盘、相近 PID、名称不符、其他 VID/transport、虚拟设备、缺失键盘 Usage、空设备、混合接口身份、同型号双设备、诊断往返和离线场景无操作。测试通过不等于 RGB 真机验收。

实际结果：

- 200 项测试 / 37 个 suite 全部通过（6.393 秒为测试运行时间，不含编译）；Debug 离线包和 Release 构建、ad hoc 签名校验通过。CLT 链接器仍提示其 Developer/Library/Frameworks 路径不存在，但构建成功；这不是 Developer ID 公证验收。
- Release 默认探针再次枚举 2 台设备 / 9 个接口，Reclusa 的 4 个接口来源正确、可用能力仅 `discovery`。没有请求私有查询。原始文件 `build/phase0112-discovery-after.json` 的 SHA-256 为 `04105a6a8f15107eae7cb2263ca677e27b7e4572ca146f34663d0c421ca5e63c`（原始记录本地保留，不提交）。
- 原生离线应用验证了总览、型号来源链接、PID 搜索和“有 USB 适配”过滤；`02F5` 可搜索，但不出现在有适配的结果中，且无读取电量或应用设置入口。
- 真实 Release 界面确认键盘分类与示意图、两台设备分列、未知电量保持空值、设置尚未适配提示；深色总览截图已查看，无文字截断或重叠。AX 和截图记录在 `build/ui0112/`。本轮不宣称已完成所有尺寸、浅深色页面及长期资源测试。

## 下一步

优先验证已有 Viper 电量、充电与 DPI 读取的真实表现；已有设置流程的每次真机修改仍需确认具体目标值。Reclusa 灯光需要精确型号的公开实现，或在官方支持环境中采集单一亮度变化的控制报文并审查区域、事务、响应和持久化行为。在证据不足时不试发未知命令，也不新建常驻抓包服务或要求修改 SIP。
