# ANIM2rGodot

为 ANIM.teamMM 自研引擎（E-mote 系 galgame）从零实现的 **Godot 播放器**：
把原版游戏的数据包放进来就能直接游玩——解释器模式，不做逐部游戏的转换移植
（思路同 ONScripter 之于 NScripter）。

## 目标与非目标

- ✅ 运行时直接读取原始数据包：` *_sce.dat` / `*_define.dat`（GSecret 加密）、
  `cg/*.gax`、`cg/psbpack.dat`（E-mote PSB）、`voice/*.pck`、`bgm/*.eog`、`movie/*.mpg`
- ✅ 实时渲染 E-mote 立绘（变量驱动的姿势/表情/眨眼/口型），而非预渲染烘焙
- ✅ 多平台：Android 为首要目标，桌面 / Web 由 Godot 同一套代码导出
- ❌ 不包含任何游戏数据（版权与体积原因）；使用者自备原版数据包
- ❌ 不是 Ren'Py 转换器——早期的逐游戏转换路线已归档在 `reference/python/legacy-renpy/`

## 现状（2026-10-28）

逆向部分已完成核心闭环，播放器本体尚未动工：

| 模块 | 状态 |
| --- | --- |
| GSecretFile 加密 | 已完全攻破，Python 参考实现与格式说明齐备 |
| sce 脚本格式（VM 规格） | 50,561 条记录全解析；对白/选项/标志/BGM/电影/E-mote 指令语义已钉死，见 `docs/sce-format.md` |
| GFilePack 打包格式 | 已钉死（voice `.pck` 与 `psbpack.dat` 共用） |
| PSB / E-mote 格式 | 头部加密已解（Key4 已求解）；图层树、变量评估、关键帧插值均已在 Python 评估器中验证 |
| define.dat 的 em 姿势表 | 已解析（177 条记录、24 个变量；sce 用到的姿势 100% 覆盖） |
| Godot 播放器 | 待开发，设计见 `docs/architecture.md` |

实测样本：《壁の向こうの妻の嬌声2》（GPT 汉化版数据包），与同社《マッチョ留学生》
的主程序 RTTI 类表逐一相同（62 个类），确认为同一引擎；后者的数据文件尚未到手验证。

## 仓库结构

- `docs/` — 格式规格与播放器架构设计
  - `sce-format.md` — sce 脚本格式完整规格（实测）
  - `formats.md` — GSecret / GFilePack / PSB / define / 资源文件格式总览
  - `architecture.md` — 播放器模块设计、MVP 范围与已知缺口
- `reference/python/` — 逆向阶段的 Python 参考实现（即规格的代码形态，移植时的对照基准）
  - `legacy-renpy/` — 已弃用的 Ren'Py 转换路线，仅作 op 语义映射的旁证存档
- `player/` — Godot 工程（待建，工具链约 3GB，NDK 等电影解码阶段再装）

## 已知硬缺口

1. **电影**：原包电影为 MPEG-1，Godot 无原生支持。计划用 pl_mpeg（单文件 C 解码库）
   经 GDExtension 接入；MVP 可先跳过电影占位。
2. **VM 边角语义**：存档快照（op `0x16` 的 500 槽）、画廊解锁、系统标签主循环、
   `0xAC` 参数轴义等，需在开发播放器时逐个钉死。
3. **E-mote 进阶渲染**：网格变形（mesh.bp）、遮罩、物理揺れ尚未在评估器中实现，
   FreeMote 的 C# 源码是主要参考。

## 开发环境（Godot 路线，本地占盘）

- 编辑器约 200MB；导出模板约 1.3GB；出 Android 包另需 JDK 17 + Android SDK + Gradle ≈ 1.5GB
- NDK（约 2.5GB）仅 GDExtension 阶段需要
