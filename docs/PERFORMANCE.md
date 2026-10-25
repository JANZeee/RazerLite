# 性能测量方法

0.9.2 与 0.9.1 同机空闲对比、各条件 3×60 秒原始样本及限制见 [PERFORMANCE092.md](PERFORMANCE092.md)。状态栏菜单的真实交互与硬件查询成本仍待独立测量。

先运行 `./scripts/build-app.sh`，用 release `.app`，避免把 SwiftPM 编译进程、调试器或 XCTest 的资源计入应用。记录机器架构、系统版本、设备数、Synapse 是否运行、窗口是否显示、菜单是否打开、预热时间和采样区间。

## CPU 与 RSS

打开应用并等待启动活动结束。找到本应用 PID 后采样，例如：

```sh
pgrep -x RazerLite
/usr/bin/python3 scripts/measure-process.py <PID> --seconds 30 --output build/window-visible.csv
```

随后关闭主窗口，保持菜单栏运行，对同一个 PID 再采样，保存为 `build/window-closed.csv`。还可分别测连接/移除、打开菜单、空设备、系统睡眠唤醒之后的状态。

脚本只读取进程累计 CPU 时间与 RSS，每秒采样一次，CPU 百分比由累计 CPU 时间差除以实际墙钟时间差计算（100% 表示一个逻辑核心）。`ps time` 精度有限，短区间的零增量不证明零工作；脚本本身也有开销。RSS 单位 KiB，不是 physical footprint，也不包含完整的共享内存归属。保留 CSV 原始样本，不用单个瞬时数当性能保证。

需要准确的唤醒、堆分配和 physical footprint 时，用 Activity Monitor 的内存指标、Instruments Allocations / Time Profiler / Energy Log（如当前 Xcode 版本提供），或对自己有权限检查的进程使用 `vmmap -summary <PID>`。这些工具可能受调试权限与 Hardened Runtime 限制；不要为测量关闭 SIP。未安装完整 Xcode 的机器无需为运行 MVP 安装 Instruments。

## 启动耗时

```sh
/usr/bin/time -lp ./build/razerlite-probe > build/startup-snapshot.json
```

CLI stderr 的 `discoveryReady` 仅是创建发现对象到完成属性快照的时间；`time` 的 real 是整个 CLI 生命周期，还包括进程启动、编码和退出。两者都**不是 GUI 的窗口启动耗时**。本应用设置中也只标注“发现服务初始化”。

GUI 可在安装完整 Xcode 后用 Instruments App Launch 测从进程创建到首帧，分别记录冷启动、缓存后的启动，各至少 10 次，报告中位数和范围。若采用 `os_signpost` 埋点，应明确起终点，不能把发现服务的局部耗时当首帧耗时。当前不提供未经测量的启动指标。

## 实现层检查

观察空闲状态 CPU 和唤醒数是否稳定，不根据源码推定实际结果。空闲路径没有 Timer、循环 sleep、持续扫描或 input callback；只有系统插拔事件与用户手动刷新触发属性枚举。新增状态查询仅在点击/显式参数时运行：后台串行线程在发送后等待 35 ms，并在设备忙碌时有限等待重读；操作结束即关闭句柄，没有周期性查询。IOKit 单次同步传输超时由系统/驱动决定，不能把忙碌重试上限称为整个操作的硬超时。`--watch` 的有限等待仅用于诊断 CLI，期间使用 run loop 等待事件。

CI/源码审查可检索意外引入的轮询与控制路径：

```sh
rg 'Timer|scheduledTimer|IOHIDDeviceOpen|IOHIDManagerOpen|IOHIDDeviceSetReport|IOHIDDeviceGetReport|SeizeDevice|RegisterInput' Sources
```

命中注释需人工区分，不能把文本检索当成总线抓包证明。本次测得的数值和局限记录在 VALIDATION.md。

0.2.0 需分别测量启动后未查询、查询进行中、查询结束后空闲三种状态。此前 UI 版本的数值仅是历史记录，不作为本版本性能结论。

## 0.5.0 系统电量路径

蓝牙电量属性缺失时，只在显式读取操作中启动一次 system_profiler，输出最多 4 MiB，单次子进程时限 8 秒，串行执行。它不是常驻组件，也没有周期性扫描。应分别采样启动后、读取进行中、读取完成后以及主窗口关闭后的状态；瞬时子进程的成本不能仅靠主应用 PID 的 RSS/CPU 覆盖。测量系统快照成本时，应单独记录该操作的耗时和子进程峰值。

0.5.0 的初步短样本见 VALIDATION.md 和 build/system-battery-*-summary.json；不能将短样本里的零增量解释成绝对零 CPU，或代替长期唤醒/功耗测试。
