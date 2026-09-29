# Matte（衬色）

> 全屏时，用衬托画面的颜色填满黑边。

在 MacBook 上全屏时，app 内容以外、系统或播放器画出来的纯黑区域，会换成一种跟当前画面协调、低饱和、偏深的颜色。Matte 在电影里指遮幅黑边，在装裱里指画作四周的衬纸。

处理的区域有两类：

1. **刘海两侧的黑带**（camera housing band）；
2. **视频的上下 / 左右黑边**（letterbox / pillarbox）：播放器画的，以及直接编码在视频文件里的，都算。

默认只在 MacBook 自带屏上生效，外接显示器上一切照旧；也可以随时切换成所有屏幕都生效（见「显示器开关」）。最初的灵感来自一块磕伤的屏幕：纯黑背景下，屏幕角落会漏光。

## 原则

- **从源头换色，不盖层挖洞**：黑色背后如果有颜色设定，就直接改那个设定。IINA 就是这样做的：mpv 画黑边用的是 `background`，Matte 直接改它。弹窗、OSD、字幕本来就画在它上面，不需要挖洞，所以不会露出黑色。
- **第一帧颜色就到位**：进入全屏时，颜色和几何参数都已经事先算好，没有先黑后变，也没有淡入淡出。
- **即插即用**：不改系统文件，不注入任何进程；卸载后一切恢复原样。

## 组成

| 部分 | 作用 |
|---|---|
| `src/main.swift` → `~/Applications/Matte.app` | 常驻后台（LSUIElement，不抢焦点，不接收点击）。① 判断目标屏是否在全屏；② 用 ScreenCaptureKit 低分辨率采样画面，在 OKLab 空间算出配色；③ 刘海带：用一条纯色带盖住菜单栏画的黑色；④ 分析 IINA 插件送来的截图，测出编码在视频里的黑边；⑤ 其他 app 的黑边：退而求其次，用覆盖层上色；⑥ 把每块屏的颜色写到 `~/Library/Caches/matte-fill/state.json`。 |
| `iina-plugin/matte-fill.iinaplugin` | IINA 里的源头处理。mpv `background` 设成 Matte 的颜色；编码在视频里的黑边在全屏时用 mpv 的画面几何参数（`video-margin-ratio-*` + `video-zoom` + `video-pan-*`）推到可视区域外，空出来的位置由 `background` 填上。**不加滤镜、不动硬件解码。** |
| `launchd/agent.plist.template` | LaunchAgent `io.github.matte-fill`：登录时启动，崩溃后自动拉起。 |
| `build.sh` | 编译 → 签名 → 重载 LaunchAgent → 安装 IINA 插件。 |

## 显示器开关

```bash
matte-fill --displays builtin   # 默认：只在 MacBook 自带屏上生效
matte-fill --displays all       # 所有屏幕都生效（外接显示器、合盖接外接屏也算）
```

这条命令改的是 `~/.config/matte-fill/config.json` 里的 `displays` 字段，常驻程序 1 秒内就会生效，不用重启。直接编辑这个文件也一样。

## 工作方式

### 全屏判定

对每块目标屏分别判断：该屏当前的 Space 是原生全屏 Space（`CGSCopyManagedDisplaySpaces` 返回的 type 为 4）；或者有窗口正好盖满这块屏的全屏区域，这样 IINA 的「传统全屏」这类非原生全屏也能识别。全屏 Space 数量一增加（缩放动画刚开始时），就先把刘海带显示出来。

### 配色

- 在 OKLab 空间对黑边以内的画面做加权平均：画面最上方 1/4 的权重乘 3，色相取按彩度加权的平均值，纯黑像素不参与计算。
- 映射成 OKLCH：亮度 `L = 0.26 + 0.45 × 画面平均亮度`，限制在 `0.34–0.56`；彩度不超过 `0.05`。画面接近无彩色时，退回暖石墨色。
- 颜色按指数曲线平滑（时间常数 1.2 秒）。刚进全屏时直接取第一帧的颜色；IINA 的话，直接从最近一张截图算出的颜色起步。

### IINA：编码在视频里的黑边

1. 打开文件后，插件在实际播放满 0.2 / 1.5 / 4 / 8 / 15 秒时各截一帧（从中途续播也能马上测出来），之后播放位置每过 30 秒再截一帧，每个文件最多 40 帧。用的是 `no-osd async screenshot-to-file … video`，在 mpv 的工作线程上编码，只截视频本身，不带字幕。截图存到插件的数据目录。
2. 常驻程序分析截图：从边缘往里数「几乎全黑」的行 / 列，得出四边黑边的比例，同时算出这一帧的配色，结果写回同名的 `.json`。
3. 只有「画面在某个方向上横贯边到边」的帧才算有效帧：黑底上的片头 logo、暗场里孤零零的一个亮点都不参与判断。每一边取所有有效帧的最小值，所以暗场只可能让黑边变小，不会越判越大。对称的黑边 1 帧有效帧就生效；上下或左右不对称的结果，需要 3 帧。
4. margin 圈出内容区，zoom 把内容放大到填满，pan 负责对中。**这是窗口的常态，不是全屏时的临时反应**：IINA 在整个全屏动画期间都暂停 mpv 渲染（`videoLayer.suspend()`），直接拉伸窗口模式的最后一帧，所以这一帧本身必须已经换好颜色。IINA 在窗口模式下会关掉 mpv 的 `keepaspect`（关着的时候这些几何参数都不起作用），插件在窗口位于目标屏时把它打开。黑边结果按文件保存，同一个文件再次打开时，第一帧就是最终状态。窗口在全屏动画里宽高比会变，margin 始终按动画区间里「不会露黑」的那一端来算，并且额外多放大约 3 像素，盖住取整误差。这套公式已经对照 mpv 0.35 的 `video/out/aspect.c` 做过离线验证：模拟 21 万个动画中间帧，没有一帧露出黑边。

### 全屏 Space 的黑底：从创建时替换

原生全屏会新建一个 Space；Space 里没有窗口的地方，合成器显示的就是纯黑。常驻程序每秒 30 次读取 Space 列表，新的全屏 Space 一出现，就用 SkyLight 的 `SLSAddWindowsToSpaces` 把自己的配色底板（层级在普通窗口之下）和刘海色带**加进这个 Space**，所以合成器从它的第一帧（包括滑入动画）起画的就是配色。只设「出现在所有 Space」是不够的：系统要等动画结束才把这类窗口挪进新 Space。底板平时不在任何桌面 Space 里（桌面上没有它的窗口，不会影响桌面小组件），全屏 Space 消失就撤掉。

### 其他 app：覆盖层（兜底）

没有源头设定可改的 app，由常驻程序检测黑边（交界行 ≥85% 纯黑，且上下 / 左右两侧都能找到），再用覆盖层上色。只采样该 app 自己的窗口，所以系统 HUD 不会触发挖洞；但 app 自己在黑边里弹出的控件仍然会挖出一个洞。长期方向是逐个找各 app 的源头设定。

## 配置

`~/.config/matte-fill/config.json`，所有字段都可以省略，改完 1 秒内生效：

```json
{ "displays": "builtin", "fallbackColor": "#3A3733", "adaptive": true, "coverBars": true,
  "minLightness": 0.34, "maxLightness": 0.56, "maxChroma": 0.05, "smoothingSeconds": 1.2, "sampleFPS": 10 }
```

## 安装 / 更新 / 卸载

```bash
./build.sh     # 编译、签名、装 LaunchAgent、装 IINA 插件（IINA 要重启才会加载插件）
# 第一次运行：系统设置 → 隐私与安全性 → 屏幕与系统录音 → 打开 Matte
~/Applications/Matte.app/Contents/MacOS/matte-fill --status   # 目标屏、是否全屏、IINA 插件是否在运行、有没有采样权限
launchctl bootout gui/$(id -u)/io.github.matte-fill && rm ~/Library/LaunchAgents/io.github.matte-fill.plist   # 卸载
```

`build.sh` 会打开 IINA 默认关闭的插件系统（`iinaEnablePluginSystem`），并启用本插件。

## 调试

| 看什么 | 在哪 |
|---|---|
| 常驻程序：每次显示 / 隐藏、首帧颜色、配置重载 | `/tmp/matte-fill.log` |
| 逐帧判定过程，第 25 帧存成图片 | 创建 `~/.config/matte-fill/debug` 文件 |
| IINA 插件：是否命中目标屏、背景色、黑边、几何参数、报错 | `~/Library/Application Support/com.colliderli.iina/plugins/.data/io.github.matte-fill/status.json`（每秒更新） |
| 离线跑黑边 + 配色（覆盖层路径） | `matte-fill --analyze 截图.png` |
| 离线跑截图分析（IINA 路径） | `matte-fill --analyze-shot 帧.jpg` |
| 在屏幕上看几何位置 | `matte-fill --preview`：画 2 秒红色色带和一个测试块 |

## 踩过的坑

- **IINA 插件「只写了一次状态就没动静」**：IINA 1.3.5 的 `file.write` 不允许覆盖已存在的文件，只有 `@tmp/` 和 `@data/` 下的文件可以覆盖。第二次写就抛异常，被 `catch` 吞掉了。插件要写的东西一律放 `@data/`。
- **不要在插件里加 mpv 滤镜**：插件的定时器跑在 IINA 主线程上，`mpv.command` 是同步调用。硬解码（videotoolbox）下插软件滤镜，IINA 自己都会先弹窗让用户选择关掉硬解。IINA 自带的 mpv 0.35 也没有 `video-crop`。所以裁黑边用 VO 几何参数，测黑边用异步截图。
- **「出现在所有 Space」的窗口不会出现在正在滑入的新全屏 Space 里**：要在 Space 创建时用 `SLSAddWindowsToSpaces` 显式加入。底板也不能预先挂在桌面上，哪怕透明度为 0，桌面小组件也会切换成「被窗口遮挡」的淡化样式。
- **全屏动画里的黑，先分清是谁画的**：录屏（`screencapture -V`）逐帧统计纯黑像素，再做对照组（关掉插件和后台程序）。本项目里就曾把 IINA 自己的随机黑帧误判成是我们引起的。
- **IINA 插件系统默认关闭**：`defaults write com.colliderli.iina iinaEnablePluginSystem -bool true`。插件只在 IINA 启动时加载。
- **全屏状态**：IINA 的 `core.window.fullscreen` 在全屏动画**开始时**就变成 true，而 `iina.window-fs.changed` 事件要等动画**结束后**才发出，所以插件用 30ms 轮询。
- **刘海带在全屏时不上色**：原生全屏下，那条黑带是菜单栏窗口（layer 24）自己画的。色带要放在 layer 25；鼠标移到顶端时色带让开，菜单栏照常可用。
- **色带跑到菜单栏下面**：要重写 `constrainFrameRect`，原样返回传入的 frame。
- **色带画到了屏幕底部**：layer-hosting 视图已经按 `isFlipped` 翻转过，不能再给子 layer 设 `isGeometryFlipped`。
- **黑边上色后又消失、来回闪**：ScreenCaptureKit 用 `excludingApplications` 排除自己不生效，必须用 `excludingWindows` 按窗口 ID 排除；跟当前色带颜色一致的像素也按黑色处理。
- **每次重新编译，屏幕录制权限就失效**：ad-hoc 签名默认的 designated requirement 是 cdhash。`build.sh` 改成只认 bundle ID。
- **不走弹窗直接授权**（SIP 关闭的机器，需要 sudo）：
  ```bash
  echo 'identifier "io.github.matte-fill"' | csreq -r- -b /tmp/csreq.bin
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "update access set auth_value=2, auth_reason=3, csreq=X'$(xxd -p /tmp/csreq.bin | tr -d '\n')' where service='kTCCServiceScreenCapture' and client='io.github.matte-fill'"
  sudo killall tccd; launchctl kickstart -k gui/$(id -u)/io.github.matte-fill
  ```
  这一行记录要先存在（程序请求过一次权限就会有）。日志里出现 `started (capture access: true)` 就说明授权成功了。

## 已知限制

- 只在全屏时生效；普通窗口模式下不处理。
- 非 IINA 的 app 走覆盖层兜底：app 自己在黑边里弹出的控件会挖洞，而且新出现的字幕最多会被盖住约 0.1 秒才挖开。
- IINA：新文件的黑边要在实际播放约 0.5 秒后才测得出来；在那之前窗口里仍是原样的黑边。
- **IINA 原生全屏的切换动画（约 0.35 秒）**：IINA 暂停渲染期间，视频层还是窗口模式时的大小，放大后的窗口上下会露出 IINA 写死的黑色窗口背景（`window.backgroundColor = .black`，约 45pt）。这是 IINA 自己画的，插件接口改不了。
- IINA 的「传统全屏」不会新建 Space，但 IINA 自己的 OpenGL 视频层在动画中有约 1/3 的概率整块画成黑色、持续约 0.7 秒；不装 Matte 时也一样（已对照验证），所以不推荐改用它。
