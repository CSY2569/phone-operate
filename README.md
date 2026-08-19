# Phone Operate

> A [Noctalia](https://github.com/noctalia-dev/noctalia) desktop-shell plugin that unifies Android device control: **scrcpy casting** (wired / wireless, per-device presets) and **KDE Connect** (battery, ring, ping, clipboard, SMS, media) on one device card.

一个 Noctalia 桌面壳插件，把 Android 设备的投屏与远程控制统一到同一张设备卡：scrcpy 投屏（有线 / 无线，支持每设备参数预设）+ KDE Connect（电量、响铃、Ping、剪贴板、短信、媒体控制）。

插件本身只做「启动管理 + 参数传递 + 状态展示」——视频解码 / 渲染全部在 scrcpy 自己的 SDL 窗口里，插件不碰视频流。

## 依赖

需在系统上安装：

- `scrcpy` — 投屏与控制
- `android-tools`（adb）— 设备发现、连接、配对
- `kdeconnect`（kdeconnectd / kdeconnect-cli / gdbus）— KDE Connect 设备接入
- `sshfs` — 浏览设备文件（SFTP 挂载）

## 功能

### 统一设备模型

- **KDE Connect 设备**（响铃、Ping、剪贴板、分享、短信、媒体控制）与 **adb 设备**（投屏）按设备合并成一张卡，不再按来源分开。
- **局域网 IP 匹配**：service 层通过 IP 判断 adb 设备与 KDE 设备是否为同一台（USB 直连也能取到设备的 Wi-Fi IP 参与匹配），匹配到的 adb 设备不再显示独立卡，投屏 / 停止统一在 KDE 设备卡上操作。
- 每台设备独立记忆：参数、自定义名称、头像、SMS 草稿、滑块拖动状态。

### 投屏（scrcpy）

- **两步流程**：点「投屏」→ 左栏展开参数面板（含「开始投屏」），不再误触即投。
- **有线直投**：USB 连接时选好参数点「开始投屏」即投。
- **无线首次配对**：面板内填「配对端口 + 调试端口 + 配对码」，一键完成 `adb pair → connect → scrcpy`。已配对设备二次投屏自动跳过配对。
- **参数预设**：高清 / 性能 / 省电 / 自定义四档。自定义档独立保留，点预设不覆盖它；滑块值恰好命中预设时高亮自动跟随。
- **参数面板**：分辨率（最高 4K）、码率（最高 30Mbps）、帧率（最高 240Hz）、熄屏投屏、录屏开关。投屏中改参数自动重启 scrcpy 应用新值。
- **多设备多开**：每台设备独立启动 scrcpy，互不干扰（进程按 `-s <serial>` 精确管理）。

### 设备卡操作（KDE Connect）

- 响铃、Ping、浏览文件（SFTP）、发送剪贴板、分享文件、配对 / 取消配对
- 正在播放（封面 / 标题 / 艺术家）+ 播放控制（上一首 / 播放暂停 / 下一首 / 停止）+ 进度拖动 + 音量
- 短信发送（目的地 + 内容）
- 设备卡内联改名、点头像换图

### 其它

- **任务栏部件**：设备图标 + 可选名称 + 电池（图标 / 百分比 / 隐藏可选，充电高亮，低电红色），点击开面板，右键开设置。
- **控制中心磁贴**：连接数或选中设备电量。
- **启动器**：输入 `ph` 前缀搜索设备，回车即投屏。
- **录屏清理**：可设最大保留录屏数，超出自动删最旧文件。

## 无线调试：配对端口 vs 调试端口

无线调试有两个端口，易混淆：

- **配对端口**：一次性，`adb pair IP:端口` 用，配合 6 位配对码。
- **调试端口**：长期连接，`adb connect IP:端口` 和 scrcpy 用，无需配对码。

面板配对流程：

1. 手机开启「无线调试」，点「使用配对码配对设备」→ 记下**配对端口**和 6 位码；
2. 看无线调试主界面「IP 地址和端口」→ 记下**调试端口**（随机，非 5555）；
3. 面板填：配对端口、调试端口、配对码 → 开始投屏。

配对成功后插件自动 `connect IP:调试端口` 并投屏；之后再次投屏直接连接，无需重新配对。若手机重启或重新开启无线调试，调试端口可能变化，需用新端口重新配对。

## 参数说明

| 参数 | 作用 | 默认 |
|---|---|---|
| 最大分辨率 | 限制视频长边像素（最高 3840） | 1920 |
| 码率 (Mbps) | 视频流码率（最高 30） | 8 |
| 最大帧率 | 帧率上限（最高 240） | 60 |
| 熄屏投屏 | 投屏时关手机屏 | 关 |
| 录屏 | 录制到文件 | 关 |
| 最大录屏数 | 保留录屏文件上限 | 10 |
| 轮询间隔 (ms) | 扫描设备频率 | 3000 |

每台设备的参数独立记忆，未设置时回退到插件默认值。

## niri 窗口规则（重要）

若使用 niri 窗口管理器，请在 `rules.kdl` 加入以下规则，否则 scrcpy 窗口会套用全局透明度 + 模糊导致看不清画面：

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

窗口尺寸 / 位置由 niri 管理（Mod+右键拖边缘缩放，Mod+左键拖动移动），插件不干预。

## 已知限制

- scrcpy 参数不支持运行中热改：改参即重启，有短暂闪屏。
- 进程靠 `pkill` 匹配命令行管理，无精确 PID 句柄。
- 无 mDNS 自动发现（系统 adb 不支持），未知无线设备仍需手动配对 / 连接。
- 设备离线（offline）时无线投屏会提示保持手机亮屏 / 检查 Wi-Fi——这是 Android 无线调试在锁屏后的常见行为，非插件缺陷。

## 开发

```sh
noctalia msg plugins source add dev path /Data/phone-operate
noctalia msg plugins enable icefish/phone-operate
```

`.luau` 文件改动自动热重载；`plugin.toml` 改动由 Noctalia 自动检测重载。

测试 IPC：

```sh
noctalia msg plugin icefish/phone-operate:core all start '{"device_id":"cf56f01f"}'
```

日志：`noctalia.log(...)` 写入 Noctalia 日志面板。
