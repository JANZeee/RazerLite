# 蓝牙系统电量 · 0.5.0

## 使用

启动 RazerLite，在蓝牙 Razer 的详情页点击“读取系统电量”。成功后总览显示百分比，状态卡显示来源、应用取得时间和系统缓存说明。菜单栏对应设备子菜单可以读取、查看电量及打开详情。刷新设备列表本身不查询电量。

CLI：

```sh
./build/razerlite-probe --read-system-battery > build/system-battery.json
# 多台蓝牙设备时，用本次枚举的 id 指定：
# ./build/razerlite-probe --read-system-battery --device-id hid-<ID>
```

默认枚举和 `--watch` 不启动系统快照。读取选项不能与 `--watch` 或 `--read-mouse` 组合。目标不唯一、读取期间身份改变或读取失败返回非零退出码。读取期间身份未改变时，即使电量不可用也会输出带 issue 的 JSON；未找到目标或身份改变时不导出旧快照。

## 读取与关联

1. DeviceReadRegistry 仅为非虚拟、已识别为 Razer、全部接口为 Bluetooth transport 的设备提供系统读取后端。USB Viper 仍要求原有完整查询接口指纹。
2. 通过每个 HID 接口的 registry ID 重新取得同一系统节点，并核对 VID/PID、产品名和 transport。不会打开输入接口。
3. 同一节点若发布有效 `BatteryPercent`，采用该值；缺失时读取该节点的 `DeviceAddress`，只在内存中归一化。
4. 按需执行 `/usr/sbin/system_profiler SPBluetoothDataType -json -detailLevel basic -timeout 6`。只解析 connected 设备，地址与 VID/PID 必须同时吻合且唯一；名称不参与匹配。无电量、身份不符、重复或无效百分比均显示未知。
5. 返回前再次核对 HID 身份与地址；DeviceManager 还检查连接请求 token 和完整接口属性。原始系统快照、其他蓝牙设备和蓝牙地址均不写日志或诊断。

系统快照进程使用独立串行 utility 队列，输出上限 4 MiB，单次运行时限 8 秒；超时、超限和任务取消只终止自己创建的子进程。没有定时扫描、常驻子进程或网络。多台设备的显式请求串行执行，排队时间不包含在单次进程时限内。

## 生命周期与状态含义

- 读取开始移除旧值；失败显示 issue，不保留旧百分比冒充本次成功。
- 断连或完整接口属性变化时清除电量；同 ID 断开重连也不接纳旧请求结果。
- 睡眠使读取请求和待确认 DPI 计划失效，清理读数；唤醒重新枚举，等待用户刷新状态。已提交的底层操作无法撤回；失效请求的迟到结果不会进入新会话。
- 系统缓存不等于设备实时测量。`acquiredAt` 是应用取得时间，没有声称知道 macOS 缓存或设备实际更新时间。
- 已成功取得当前连接电量后，对应能力显示已实现；此前标为待验证。失败不表示硬件没有电池。

## 已验证与范围

本机 BSK MOBILE（Bluetooth Low Energy，068E:00D5）没有在该 HID 节点发布 BatteryPercent；其 DeviceAddress 与系统蓝牙快照精确匹配。CLI 和 0.5.0 Release 原生窗口均取得 100%，来源为 macOSBluetoothSnapshot。见验证记录和 `build/system-battery-live.json`。

尚未验证其他型号、旧 macOS、Intel 和真实睡眠唤醒。HID 的 BatteryPercent/DeviceAddress 以及 system_profiler JSON 属于观察到的系统数据，结构可能随版本变化，缺失或改变会明确失败；没有使用 IOBluetooth 私有电量属性。当前未加入 CoreBluetooth 扫描、GATT Battery Service 或蓝牙 DPI/RGB 指令，也不请求输入监控或新的蓝牙权限。

相关调研：[外设读取调研](PERIPHERAL_READING_SURVEY.md)。下一步标准 GATT 后端需要先验证实际服务可见性和与 HID 的可靠关联，不能只按设备名称绑定。
