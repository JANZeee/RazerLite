# 0.11.0：已有 DPI 档位编辑

日期：2026-11-03；build 18。目标是补齐常用鼠标控制，不增加后台服务或运行时依赖。本轮没有连接外设，没有发送真实写入请求。

## 交付范围

- Viper V4 Pro `1532:00E6`、USB、唯一匹配的 interface 3 / Usage 0x0C:1 / I/O/F 0/0/90，沿用已有适配条件。其他 PID、蓝牙和不同接口不继承控制能力。
- 性能页保留当前档位快捷编辑；“编辑全部档位”默认折叠，载入最近读取的完整表，独立编辑任意已有档位 X/Y。仅变化行需符合 100–50,000、步进 50；未变化行原样保留，包括固件返回的非整步进值。
- 不改变当前档位和档位数量，不新增/删除档位。未实现 X/Y 联动或主动切档。现有 schema 1 本地档案仍是当前档位 X/Y 预设，不保存本轮多档草稿。
- 编辑器保留载入时的基线；重新读取不会静默覆盖草稿。发现基线变化时提示重新载入。准备阶段重新查询完整表并比对基线；确认页加粗实际修改行，列出所有提交值。
- 确认只授权一次写入，60 秒过期。写前再次读取并比较，未知布局、状态变化、取消、睡眠或断连会中止。写后检查 ACK 并读回整表；不一致显示“不确定”，不重试、不自动回滚。模拟成功明确标注“模拟读回”。

## 协议与参考

本轮复查 [FerrisPulse 固定提交](https://github.com/Ferris-echo/FerrisPulse/tree/e565b0d3e3cae2f87068651b1c0f7a8435d5a2f3)，只读研究，没有运行或复制其代码/资源。检查 `RazerDeviceHelper.cs`、`HardwareCommandBus.cs`、`DpiManagementDialog.cs` 及 `test_razer_dpi_protocol.ps1`。

- `ParseDpiStagesReport` 检查响应状态、04/86、档位数量和当前档位范围；其档位对话框支持分别编辑 X/Y。这些可以参考为用户流程和边界检查。
- 其设备级锁和统一命令入口值得保留为设计原则；RazerLite 已有串行 I/O 与设备操作协调器，本轮复用它们。
- 其 Windows SetupDi、CreateFile、HidD 通信和含 report-ID 前缀的缓冲区处理不能直接套用 IOHIDDevice。命令总线中驱动返回成功后更新本地状态，也不能代替本工具的完整读回。
- 上游型号清单和功能声明不等于 macOS 验收。FerrisPulse 对 Viper 型号/PID 的描述不改变本工具 `00E6` 的接口白名单。

[Synapse for Mac 官方页面](https://www.razer.com/synapse-4-mac)提供设备配置和按支持名单组织功能的参考。本轮采用“设备 → 性能 → 修改 → 确认”的简短路径，不扩展宏、云配置或复杂灯效。

编码仍使用已有审查的 [OpenMouse 实现 revision](https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/drivers/razer/viper-v4-pro-hid.ts)和 [DPI 写入记录](DPI_WRITE.md)：GET 04/86、SET 04/06、完整表、storage 1；GET 档位索引与 SET 索引的差异保持原实现。本轮扩展编辑范围，没有引入新的设备命令。可能保存到设备，不能宣称仅临时生效。

历史上只有一次当前第 3 档 2800/2800 真机写入与完整读回；多档修改、非当前档位修改、跨重连/断电持久性均待真机验证。适配清单保持历史证据与新功能的验证范围分开说明。

## 验证与运行

182 项测试 / 34 个 suite 通过。新增模拟协议覆盖：两个档位一次提交及完整读回、字节位置与 SET 索引、非当前档位修改、未编辑非整步进值保留、重复/非法/空/无变化请求在开接口前拒绝、旧基线或未知元数据拒绝、读回不一致不重试。真实 DeviceManager 配假服务验证同型号双设备隔离、重复确认只执行一次、旧草稿拒绝、睡眠使多档确认失效。

原生离线窗口已实际操作：展开五档、输入 1251 禁用提交、修改第 1/3 档的独立 X/Y、确认页核对全部五档、取消保留草稿、重新检查、确认模拟应用并显示读回值。成功后编辑器以读回表为基线，无变化再次禁用提交。截图/辅助功能记录在 `build/ui011/native/`，不属于真机证据。

```sh
./scripts/test.sh
./scripts/build-scenarios.sh
open -n build/RazerLite-Scenarios.app --args --scenario mouse

./scripts/build-app.sh release
open build/RazerLite.app
# 仅被动发现，不发送私有查询或设置命令
./build/razerlite-probe
```

本轮被动枚举为 0 个接口。Debug/Release 构建和严格 ad hoc 签名检查通过；没有进行 Developer ID 签名、公证或系统登录启动验收。日志为 `build/phase011-tests.log`、`build/phase011-scenarios-build.log`、`build/phase011-release-build.log`、`build/phase011-discovery.json`。本轮未重新测量性能，不将 0.10.3 数据冒充本版本指标；没有新增定时器、轮询或依赖。

调试时使用离线窗口的“DPI 结果”切换不确定/未发送结果；真实设备写入仍须每次明确确认。设备到位后的验证顺序为：只读原表 → 选择最小变更并确认 → 核对完整读回 → 手动重新读取 → 经同意再测重连/断电；记录固件已知情况及其他驱动状态，不自动停止 Synapse。

下一步按 [更新计划](NEXT_DEVELOPMENT_PLAN.md)推进精确型号的回报率设置，再做基础灯光和常用侧键映射。每项独立研究、测试和验收，不把未实现项显示成已应用。
