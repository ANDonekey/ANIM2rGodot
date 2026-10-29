# ANIM2rGodot

为 ANIM.teamMM 自研引擎（E-mote 系 galgame）从零实现的 **Godot 播放器**：
把原版游戏的数据包放进来就能直接游玩——解释器模式，不做逐部游戏的转换移植
（思路同 ONScripter 之于 NScripter）。

## 目标与非目标

- ✅ 运行时直接读取原始数据包：` *_sce.dat` / `*_define.dat`（GSecret 加密）、
  `cg/*.gax`、`cg/psbpack.dat`（E-mote PSB）、`voice/*.pck`、`bgm/*.eog`、`movie/*.mpg`
- ✅ 实时渲染 E-mote 立绘（变量驱动的姿势/表情/眨眼/口型），而非预渲染烘焙
- ✅ 多平台并行：桌面（选本地游戏目录游玩）、Android 与 **Web 版**
  （在线数据包：游戏数据经一次性预处理打包后托管，浏览器按 HTTP Range
  按需加载，见下文）由 Godot 同一套代码导出
- ❌ 不包含任何游戏数据（版权与体积原因）；使用者自备原版数据包
- ❌ 不是 Ren'Py 转换器——早期的逐游戏转换路线已归档在 `reference/python/legacy-renpy/`

## 现状（2026-10-29）

逆向核心闭环完成，播放器已达可完整游玩状态，Web 版已上线。

**Web 版（在线包）**：<https://pub-365ac9662f154f5789d1fb6f083fe463.r2.dev/index.html>
（样本游戏数据包，打包格式 `anim-webpkg/2`：按剧本播放顺序重排语音包、
解密/裁边/通道交换等预处理在打包期完成、数据包索引内嵌于 manifest、
按剧本场景粒度预取；构建工具见 `reference/python/web_package_build.py`
与 `web_preprocess.py`）

| 模块 | 状态 |
| --- | --- |
| GSecretFile 加密 | 已完全攻破；GDScript 移植与 Python 参考字节一致（3 个真实文件 SHA256 对照） |
| sce 脚本格式（VM 规格） | 50,561 条记录全解析；GDScript 解析器记录链哈希与 Python 基准一致 |
| ScriptVM | 已实现并验证：独立 Python 模拟器与 GDScript VM 的 34,860 个规范事件流全等（一次完整通关：10,269 句对白 + 13,710 句旁白 + 44 次选项） |
| GFilePack 打包格式 | 已钉死；加载器只读包头索引、按需取数（1.1GB 的 psbpack 不整包载入） |
| PSB / E-mote 格式 | GDScript 解析 + 变量评估器已移植，177 条姿势的部件几何与 Python 评估器逐项一致；网格变形、遮罩（stencil）、物理揺れ均已实现 |
| define.dat | em 姿势表（177 条）与服装/回想/FLOW 等全部数据段已解码，GDScript 运行时直接解析原包 define |
| 音频语义 | BGM/台词语音/环境声已钉死；`0x8B` 经原版录音波形互相关实测为单发 SE 通道（播放器 4 路 SE 池）；`0x88` 为多通道循环（见缺口 2） |
| Godot 播放器 | 主线可从头播放；主菜单六屏按原版素材逐屏复刻（标题画面与原版逐像素一致、SAVE/LOAD 100 槽、CONFIG、VOLUME、EXTRA 五页签、FLOW 分支图 336 节点）；游戏内按钮条、B-LOG、用户 AUTO 齐全 |
| Web 性能 | 针对单线程 wasm 的系统优化：部件节点常驻复用、口型分档量化、姿势网格缓存、遮罩纹理缓存、缓存字节预算 LRU、驱动重绘成本自适应合并、开包零头部往返——同一段实测中渲染总耗时由 52.1s 降至 18.1s（设计与数据见 `docs/collect-cache-design.md` 与开发日志） |

构建与测试方法见 `player/README.md`。

实测样本：《壁の向こうの妻の嬌声2》（GPT 汉化版数据包），与同社《マッチョ留学生》
的主程序 RTTI 类表逐一相同（62 个类），确认为同一引擎；后者的数据文件尚未到手验证。

## 仓库结构

- `docs/` — 格式规格与播放器架构设计
  - `sce-format.md` — sce 脚本格式完整规格（实测）
  - `formats.md` — GSecret / GFilePack / PSB / define / 资源文件格式总览
  - `architecture.md` — 播放器模块设计与已知缺口
  - `collect-cache-design.md` — collect() 性能剖面与缓存方案（网格缓存已落地、子树缓存设计）
- `reference/python/` — 逆向阶段的 Python 参考实现（即规格的代码形态，移植时的对照基准），
  以及在线包工具链：`web_package_build.py`（打包）、`web_preprocess.py`（预处理）、
  `pck_reorder.py`（语音包按剧本顺序重排）
  - `legacy-renpy/` — 已弃用的 Ren'Py 转换路线，仅作 op 语义映射的旁证存档
- `memory/` — 开发记忆：持久结论 `MEMORY.md` + 逐日日志 `devlog/`，随里程碑同步更新
- `player/` — Godot 工程（工具链约 3GB，NDK 等电影解码阶段再装）

## 已知硬缺口

1. **原生电影解码**：Web 版已用转码 Ogg Theora 解决；桌面/Android 的原包
   MPEG-1 仍待 pl_mpeg（单文件 C 解码库）经 GDExtension 接入，
   同时解锁 EXTRA 动画鉴赏的完整体验。
2. **BGV 多通道**：原版至少 7 路并行的环境声/背景语音通道，
   播放器目前为单路 BGV，层叠感有差距。
3. **边角语义**：CG 鉴赏第 2–7 页的总数与组→变体映射未钉死；
   混合模式 `bm` 的语义已于 2026-10-30 逆向钉死（见 docs/emote-driver.md），
   播放器渲染接入待排；`0xAC` 参数轴义为近似实现。
4. **通用性验证**：第二款游戏的数据包尚未到手，多引擎重构按计划等第二个
   引擎样本出现后再议；Android 尚未在真机上跑过。

## 开发环境（Godot 路线，本地占盘）

- 编辑器约 200MB；导出模板约 1.3GB；出 Android 包另需 JDK 17 + Android SDK + Gradle ≈ 1.5GB
- NDK（约 2.5GB）仅 GDExtension 阶段需要
