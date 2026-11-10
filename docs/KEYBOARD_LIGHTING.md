# Reclusa 键盘亮度适配

研究日期：2026-11-10。范围为本机识别到的 **Reclusa Mini 65%，1532:02F5，USB 接收器**。USB 是接收器的系统传输类型，不应写成键盘已通过线缆直连。

## 证据与边界

当前公开开源项目的支持表不能直接证明该设备的灯光兼容性。重新核查后，找到雷蛇官方设备模块中的完整静态调用链：产品映射 → 接收器连接类型 → DualLink → 灯区和亮度命令。

| 来源 | 核查结果 |
| --- | --- |
| [FerrisPulse 37616f8](https://github.com/Ferris-echo/FerrisPulse/blob/37616f806c5a50740b93c82569d1646d56fb61f7/src/Hardware/LightingHelper.cs) | 灯光入口只接受 Basilisk Ultimate 0086/0088，不能授权键盘通信。 |
| [MacRazer 78f011d](https://github.com/SorcRR/MacRazer/blob/78f011d9d75427ea1b30435bc70c27a5aa905bd5/Sources/MacRazer/RazerAccessories.swift) | Cynosa 022A 有部分灯效和亮度真机注释；无 02F5。可参考按需读取、串行通信、灯效与亮度独立提交。 |
| [OpenRazer 477f4d6](https://github.com/openrazer/openrazer/blob/477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d/driver/razerkbd_driver.h) | 核查的 PID 表没有 02F5。Reclusa X 的 02E3 不是本机型号。 |
| [OpenSynapse dd82dfe](https://github.com/A1mAssist/OpenSynapse/blob/dd82dfeb9aefacf0cf37836f45b8839015742663/CHROMA_SUPPORTED_DEVICES.md) | 包含 02F5 别名，但相关灯效尚待真机写入验证；其 Legacy 服务不提供亮度，不能据此判定硬件不支持。 |

官方资源只作静态阅读，没有执行下载的 JavaScript，也没有复制其实现到项目。独立 Swift 编解码依据下列协议事实。

### 官方资源指纹

| 文件 | SHA-256 |
| --- | --- |
| [main.4ac4b05541bb1859fa0e.js](https://apps.razer.com/synapse/products/756/mw/main.4ac4b05541bb1859fa0e.js) | `5e7adbd276b0da6a4a4f06c6dbc7d7b07400b3fd7fd17eb8eea54a7948b4923d` |
| [6737.90f8e2e80827f3801f8e.js](https://apps.razer.com/synapse/products/756/mw/6737.90f8e2e80827f3801f8e.js) | `a8486d90275407cfc1c9e7b21b2017cc74a5720a5c7b6aa330c51bb3cd8d46db` |
| [rzDevice25.40fe6f559bba152076d4.js](https://apps.razer.com/synapse/products/756/mw/rzDevice25.40fe6f559bba152076d4.js) | `9788a6b975de1b2eb771d167318b74f0d45359a6b0039ff7582af011e9632de3` |
| [rzDevice25DualLinkKeyboard.3b347518a00a88ca9641.js](https://apps.razer.com/synapse/products/756/mw/rzDevice25DualLinkKeyboard.3b347518a00a88ca9641.js) | `c0df14003004b0cd128aef0932667851c61e0f6bda7bdb4da77fddeadb33b1e8` |

产品定义分别使用 02F4（有线）、02F5（接收器）、02F6（蓝牙），VID 1532，控制接口 3。工厂为接收器选择 DualLinkKeyboard。本轮只允许本机已观察到的 **02F5 USB / interface 3 / Usage 0C:01 / I/O/F 0/0/90**，不因此开放 02F4、02F6 或相近型号。

DualLink 对这些命令使用 `0x80 | sequence`，序号 0…30。90 字节逻辑报文使用 report ID 0；响应必须匹配 transaction、class、command、长度、保留字段、校验和。只有 status 02 是成功；BUSY 仅有界接收，不重发查询。

| 操作 | Class / ID | 长度 | 参数或响应 |
| --- | --- | --- | --- |
| 查询灯区 | 0F / 80 | 请求 80 | 零参数；响应为五字节记录 `[region, updateRate, dataType, width, height]`，无计数前缀 |
| 查询亮度 | 0F / 84 | 3 | `[profile, region, 0]`；响应 `[profile, region, raw]` |
| 设置亮度（协议依据） | 0F / 04 | 3 | `[profile, region, floor(percent × 255 / 100)]` |

官方普通调光入口使用 profile 1、AllRegion 0；GET 时会先查询实际灯区。RazerLite 初始试读仅接受**唯一非零灯区**，拒绝空、多个或不完整记录，不复制官方失败后猜测 region 1 的回退。显示百分比为 `ceil(raw × 100 / 255)`，保留原始值。

profile 1 是协议配置通道。没有证据保证它在所有板载槽/运行模式下等于眼前发光强度；不得将读回值标成光学测量，也不得把它声称为仅易失存储。官方另外存在同步多个板载槽的流程，本工具不隐式执行。

## 最小验收顺序

1. 固定报文与模拟传输测试：身份拒绝、CRC/ACK/回显错误、超时、BUSY、异常关闭、不猜灯区。
2. 手动运行 `build/razerlite-probe --read-keyboard-brightness`。默认无参数仍只枚举；该选项仅查询灯区及 profile 1 亮度，不改变模式或配置槽。失败保留未知，不继续试发其他型号命令。
3. 只读成功后再接入单次亮度设置：读取基线、呈现具体变更、确认、重新检查基线、一次 SET、ACK、独立 GET。设置可能保存到设备，真机写入需明确同意。
4. 配置读回一致与灯光实际变化分开记录。没有灯效读取/实际验证前，不开放单色、呼吸、波浪或自动恢复。

不需要安装雷云作为运行依赖；不新增驻留进程、定时灯效刷新或网络连接。

## 本机只读记录

2026-11-10 22:01:59（Asia/Singapore），Release CLI 对当前接收器执行一次两命令查询：

| 字段 | 结果 |
| --- | --- |
| 设备 | Reclusa Mini 65%，1532:02F5 USB |
| 灯区 | 5（唯一灯区） |
| 配置通道 | 1 |
| 原始亮度 | 255 |
| 换算配置值 | 100% |
| 响应检查 | 长度、校验和、事务/命令、成功状态及 profile/region 回显通过 |

当时只读阶段 232 项 Swift 测试通过，Release 构建及 CLI 被动/拒绝路径检查通过。原始诊断保留在忽略的 `build/keyboard-lighting-read.json`，不进入仓库。这个结果只验证该次连接的查询；未查询真实固件版本，不证明其他连接方式、长期稳定性、跨重启保存或实际灯光变化。
