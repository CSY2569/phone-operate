# Phone Operate

基于 [scrcpy](https://github.com/Genymobile/scrcpy) 的 Noctalia 桌面壳插件：图形化启动、参数配置、多设备管理。

插件本身只做「启动管理 + 参数传递 + 状态展示」——视频解码/渲染全部在 scrcpy 自己的 SDL 窗口里，插件不碰视频流。

## 依赖

需在系统上安装：

- `scrcpy` — 投屏与控制
- `android-tools`（adb）— 设备发现、连接、配对

## 功能

- **任务栏状态图标**：绿 = 正在投屏，灰 = 未投屏。左键打开配置面板，右键用最近设备一键启动。
- **配置面板**：设备列表（含 inline 重命名）、分辨率/码率/帧率滑块、熄屏/录屏开关。运行中改参数自动重启 scrcpy 应用新参数。
- **多设备多开**：每台设备独立启动 scrcpy，互不干扰。
- **启动器**：在启动器输入 `ph` 前缀搜索设备，回车即启动。
- **无线配对/连接**：面板内输入配对码配对新设备，自动 connect 历史地址（带网络恢复重连 + 三次递增重试）。
- **录屏清理**：可设最大保留录屏数，超出自动删最旧文件。

## niri 窗口规则（重要）

若使用 niri 窗口管理器，请在 `rules.kdl` 加入以下规则，否则 scrcpy 窗口会套用全局透明度+模糊导致看不清画面：

```kdl
// scrcpy: 投屏窗口浮动 + 不透明无模糊
window-rule {
    match app-id="scrcpy"
    open-floating true
    opacity 1.0
    background-effect { blur false; }
    draw-border-with-background false
}
```

窗口尺寸/位置由 niri 管理（Mod+右键拖边缘缩放，Mod+左键拖动移动），插件不干预。

## 配对端口 vs 调试端口

无线调试有两个端口，易混淆：

- **配对端口**：一次性，`adb pair IP:端口` 用，需输入配对码。
- **调试端口**：长期连接，`adb connect IP:端口` 和 scrcpy 用，无需配对码。

面板的「配对新无线设备」用配对端口；之后的历史自动连接用调试端口。Android 11+ 无线调试若开启「随机端口」，手机重启后调试端口会变，需在手机查看新端口并重新连接。

## 参数说明

| 参数 | 作用 | 默认 |
|---|---|---|
| 最大分辨率 | 限制视频长边像素 | 1920 |
| 码率 (Mbps) | 视频流码率 | 8 |
| 最大帧率 | 帧率上限 | 60 |
| 熄屏投屏 | 投屏时关手机屏 | 关 |
| 录屏 | 录制到文件 | 关 |
| 最大录屏数 | 保留录屏文件上限 | 10 |
| 轮询间隔 (ms) | 扫描设备频率 | 3000 |

每台设备的参数独立记忆，未设置时回退到插件默认值。

## 已知限制

- scrcpy 参数不支持运行中热改：改参即重启，有短暂闪屏。
- 进程靠 `pkill` 匹配命令行管理，无精确 PID 句柄。
- `adb pair` 走 shell 管道喂配对码，仅配对码为纯数字时安全。
- 无 mDNS 自动发现（系统 adb 不支持），未知无线设备仍需手动配对/连接。

## 开发

```
noctalia msg plugins source add dev path /Data/phone-operate
noctalia msg plugins enable icefish/phone-operate
```

`.luau` 文件改动自动热重载；`plugin.toml` 改动由 Noctalia 自动检测重载。

测试 IPC：

```sh
noctalia msg plugin icefish/phone-operate:core all start '{"device_id":"cf56f01f"}'
```

日志：`noctalia.log(...)` 写入 Noctalia 日志面板。
