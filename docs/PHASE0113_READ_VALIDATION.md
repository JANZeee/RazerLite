# 0.11.3：已有读取的真机复验与诊断修复

日期：2026-11-03，版本 0.11.3 / build 21。保持轻量，不增加协议、后台轮询、依赖或设备写入。此次只向已审查的 Viper `1532:00E6 USB` 控制接口发送现有状态查询；Reclusa `02F5` 仍仅枚举系统属性。

## 真实结果与适用范围

环境为本机 macOS 27.2 / Apple Silicon；系统枚举 2 台物理设备、9 个 HID 接口。Viper 控制接口满足 interface 3、Usage 0x0C:1、I/O/F 0/0/90。实际固件版本仍未知。

| 操作 | 本次响应 | 新加坡时间（UTC+8） |
| --- | --- | --- |
| 独立充电查询 | `notCharging`，无 issue | 20:34:57 |
| 电量与 DPI 查询 | 86%；当前第 3 档；X/Y 均为 2846 | 20:35:04 |
| 回报率配置查询 | 1000 Hz，无 issue | 20:35:04 |
| 新独立电量 CLI，Debug | 86%，无 issue；无 DPI 或充电结果 | 20:37:07 |
| 新独立电量 CLI，Release | 86%，无 issue | 20:38:46 |
| 加入连接复核后的电量/DPI，Release | 86%；五档和当前档位与先前相同，无 issue | 20:38:46 |

五档 X/Y 分别为 400、800、2846、6073、49999，当前第 3 档。只显示设备真实返回值，没有按常见整数修正，也没有重新应用历史授权的 2800/2800。该历史设置的跨重启持久性仍无结论。

充电能力的证据等级更新为“有指定环境真机记录”，范围严格限定为本次取得的“未充电”响应。不证明已测试充电中、状态切换、接收器离线或电缆状态。没有物理切换连接、睡眠、重连或输入共存验收；没有测量实际输入频率。

系统还发布 `RazerGenericHIDDriverKit` 与 `com.razer.appengine.driver` 绑定；没有停止其他软件。此次查询成功不等于 Synapse 并发操作或独占访问已通过共存测试。

## 修复与新增入口

1. **CLI 电量/DPI 查询也复核连接。** 以前此路径直接导出结果，缺少其他查询已有的结束前属性刷新。现在必须在重新枚举后找到相同设备及完整接口属性，否则退出失败，不导出旧读数。仍不能证明一个短时断开并以完全相同系统身份恢复的无线端没有发生变化；接口存在不等于外设持续在线。
2. **独立电量诊断的模式正确。** `DiagnosticSnapshot` 以前仅凭其他读数或显式请求标志判断通信，单独传入 `batteryReadouts` 时会落到 discovery-only。现在按后端判断：Viper/BlackWidow 电量为设备状态查询，蓝牙电量为系统属性读取；失败也保留尝试类型。模拟、写入与自动刷新模式维持原优先级，JSON schema 仍为 10。
3. **`--read-battery`。** 仅调用现有 `ViperBatteryReadService`，不查询 DPI、充电，不设置设备。仅接受唯一、精确适配的 Viper USB，多个目标需要 `--device-id`；与其他读取选项、`--watch` 互斥。真实应用原有“读取电量”已使用此服务，本轮未增加新 UI 按钮。

独立电量已有少量手动真机记录，但没有完成长时间重复读取、睡眠唤醒或资源测量。真实自动电量资格保持关闭；模拟场景才允许调度。

## 运行与验证

```sh
./scripts/test.sh
./scripts/build-app.sh release
python3 scripts/test-probe.py

# 默认仅系统属性；先从 devices 找到本次连接 ID
./build/razerlite-probe > build/discovery.json
# 用上一步 ID 替换下方占位符；只有这条会请求独立电量
./build/razerlite-probe --read-battery --device-id '<本次 Viper 设备 ID>'
```

202 项测试 / 37 个 suite 通过，6.401 秒为测试执行时间，不含编译。新增回归覆盖三种电量后端的成功与失败、零电量、JSON 往返、混合后端、模拟/写入/自动模式优先级与空诊断默认值。已有电量报文测试继续保证只发送一个已审查电量 GET、不查询 DPI/充电，并关闭 transport。

CLI 检查通过：帮助包含新选项；互斥参数在枚举前拒绝；不存在的设备 ID 不会进入服务；默认只发现设备。脚本只做这些被动/拒绝路径检查，不会主动读取设备状态。CLI 读取期间实际拔线的行为尚未真机验证，不能将普通成功读取当作断连测试。

Release 构建和严格 ad hoc 签名校验通过。CLT 仍有缺失 Developer 库搜索目录的链接警告；未做 Developer ID 公证。界面自动化连接连续两次超时，因此本轮未完成新版 GUI 操作验收或自动重启；代码变更不涉及 UI 布局，重新启动本地构建后可加载更新的适配证据。

本地原始记录与摘要（不提交设备诊断文件）：

| `build/` 下文件 | SHA-256 |
| --- | --- |
| `phase0113-charging-live.json` | `c91d24ef93edd6bf2c30da2b33282e3b40ccd8162f64110a414868af5eb5feb1` |
| `phase0113-mouse-live.json` | `29e47fdb4f44605e2ce46df494fc251a131f868002b264f34b1ea09f969a1413` |
| `phase0113-polling-live.json` | `33612a928c17c4762e9da4aa2d1042b9936cade0055a78eefa4c6b5d9ff09ff5` |
| `phase0113-battery-live.json` | `daa84575a686e4d46375887b7405e54672435dd8335cfcbd3614e89d3475a9bd` |
| `phase0113-release-battery-live.json` | `bba4e6050112d0820d2f63908c6c15bd2f55920721e7867f445ac9301b026980` |
| `phase0113-release-mouse-live.json` | `bd98520689ce8bad88db49868ab021f57fe27728b0518f9b271e73dc3a9da7e5` |

测试、CLI 与构建日志为 `build/phase0113-tests.log`、`build/phase0113-cli-tests.log`、`build/phase0113-release.log`。本轮没有新增性能指标。

## 后续优先级

先验证接收器仍在而鼠标离线、睡眠唤醒、重新连接时旧结果是否清除，再做开启自动电量前的低频读取和整体资源验收。真实设置仍逐次确认目标值；不为了测试擅自改变 DPI、回报率或板载配置。Reclusa 灯光等待精确协议证据，宏和复杂 RGB 编辑器继续后置。
