# 数据格式总览（实测，样本：嬌声2 数据包）

除注明外，均为对实际数据文件的实测结论，参考实现见 `reference/python/`。

## GSecretFile 加密（*.dat / *.gax 等）

```
[00 00 00 01][16 字节随机密钥（明文存放）][加密正文]
正文[i] = 明文[i] XOR 密钥[i mod 16]
```

- 每处理满 16 字节，用刚解出的明文字节（块内偏移 14）的低 3 位选择 8 套加法
  搅动公式之一更新密钥（case 6 连带执行 case 7）。
- 参考实现：`anim_gsecret.py`（逐字节参考版）、`gsecret_fast.py`（块级版）。
- 校验：解密出的 PNG CRC 全过；与 SExtractor 的 ANIM 插件算法逐字节一致。
- 变体：某些汉化补丁版 exe 被 patch 跳过解密，其 sce/define 是「假头 + 明文」。

## GFilePack 打包（voice/*.pck、cg/psbpack.dat 共用）

```
[u32 文件数][×文件数 (u32 0, u32 偏移, u32 大小)][NUL 分隔文件名表][数据区]
```

## 资源文件

| 文件 | 格式 |
| --- | --- |
| `bgm/*.eog` | 8 字节 `CRM\0` 头 + 原样 Ogg Vorbis，剥头即播 |
| `voice/*.pck` | GFilePack，内含 `.eog` 语音与 E-mote 口型 `.csv` |
| `cg/*.gax` | GSecret 加密的 PNG（样本为 2048×2048 RGBA，实际画面在左上子矩形） |
| `cg/psbpack.dat` | GFilePack，内含 E-mote PSB 模型 |
| `movie/*.mpg` | 明文 MPEG-1 |
| `*_sce.dat` | GSecret 加密的脚本，格式见 `sce-format.md` |
| `*_define.dat` | GSecret 加密的定义数据，含 em 姿势表（下节）；其余部分未解析 |

## PSB（E-mote 模型）

- 样本 69 个模型均为 PSB v3。头部 9 个 u32 被 XorShift128 流加密：
  Key1/2/3 为 FreeMote 公开常量，Key4 = 0x473ab96d，由已知明文
  HeaderLength=44 逐位求解（69/69 文件头校验通过；值即 `psb_parse.py` 的常量）。
- 结构可全解析：名字 trie、字符串表、chunk 表、对象树。
  参考实现：`psb_parse.py`。
- 纹理：`source.tex`（或多页 `source.tex#NNN`）声明宽高 + `pixel: {$res: chunk}`，
  像素为原始 RGBA8；`source.tex.icon` 给出各部件的矩形与原点。
  批量导出器：`psb_export_all.py`（样本 69 模型 / 91 纹理页 / 9,589 部件，全量校验通过）。
- 评估模型（渲染器核心语义，`emote_render.py` 已验证）：
  - 图层可带 `parameterize`（所属 motion 的参数表下标），按变量当前值定位时间轴
    `t = (v − rangeBegin) × division / (rangeEnd − rangeBegin)`；
  - tween 关键帧对数值字段线性插值，离散字段取前帧；
  - `arm_type` / `face_type` 等选择器变量映射到 `fade_*`，选中项显示、其余隐藏；
  - 眨眼由 `face_eye_open` 轴驱动；口型由 `face_talk` + 语音 CSV 时间轴驱动（未实现动态版）。
  - 三个有符号存储怪癖（坐标 int16 回绕、角度/参数端点 (180,255] 字节回绕、
    图标原点条件回绕）均已由数据对称性证明，细节在 `emote_render.py` 注释中。
  - **角度有两种存储形态**（2026-10-28 定位 Mhide208a 头部 140° 假旋转时钉死）：
    整数存储时走 (180,255] 字节回绕（如 246 = −10°）；浮点存储时是 0..360
    度数形（如 350.0 = −10°），读入时归一到 (−180, 180]，tween 插值随之走短弧。
    两种形态混读会让脖子倾斜轴在关键帧间扫出 140° 的假旋转。
- 未实现：网格变形（mesh.bp）、遮罩/模板（图层带 `inheritMask` 位掩码、
  帧内容带 `mask` 字段，未实现的后果是被遮罩部件整块画出）、物理揺れ、色调字段。

## define.dat 的 em 姿势表

记录格式：`[u32 9][u32 flags]` + 标签 + `(变量名, ASCII 浮点)` 对，
以 `('', '0.0')` 终止。样本共 177 条（130 条全 18 变量姿势 + 若干偏置集），
24 个变量（head/body/face 系列 + `arm_type` + `fade_v~z`）。
提取器：`define_extract.py`。

**关键概念：em 标签是「一组 E-mote 变量预设（姿势）」，不是 PSB 内的时间轴名。**
sce 的 `0x52` 加载模型、`0x7C` 套用 em 标签；播放器维护当前变量状态，
全姿势替换、偏置集增量合并。
