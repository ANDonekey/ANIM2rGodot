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
- 纹理：`source.tex`（或多页 `source.tex#NNN`）声明宽高 + `pixel: {$res: chunk}`；
  `texture.type` 标称 "RGBA8"，但**字节序实测为 B,G,R,A**（按 RGBA 直读
  肤色发蓝，与游戏 CG 原画对照后交换 R/B 才正确，2026-10-28 钉死）；
  `source.tex.icon` 给出各部件的矩形与原点。
  批量导出器：`psb_export_all.py`（样本 69 模型 / 91 纹理页 / 9,589 部件，全量校验通过）。
- 评估模型（渲染器核心语义，`emote_render.py` 已验证）：
  - 图层可带 `parameterize`（所属 motion 的参数表下标），按变量当前值定位时间轴
    `t = (v − rangeBegin) × division / (rangeEnd − rangeBegin)`；
  - tween 关键帧对数值字段线性插值，离散字段取前帧；
  - `arm_type` / `face_type` 等选择器变量映射到 `fade_*`，选中项显示、其余隐藏；
  - 眨眼由 `face_eye_open` 轴驱动；口型由 `face_talk` 驱动（播放器侧动态驱动已实现：语音总线电平 → face_talk，见 architecture.md 第四轮）。
  - 三个有符号存储怪癖（坐标 int16 回绕、角度/参数端点 (180,255] 字节回绕、
    图标原点条件回绕）均已由数据对称性证明，细节在 `emote_render.py` 注释中。
- 进阶渲染语义（2026-10-28 第四轮，全部由样本数据实测/推断，FreeMote 的
  静态绘制器不处理这些字段）：
  - 帧内容 `mask` 是**字段存在位掩码**（实测：值是内容键集合的确定函数：
    coord=0x2、color=0x200、opa=0x400、bm=0x20000、motion=0x80000、
    mesh=0x2000000），不是模板 id；缺字段走默认值的旧读法等价。
  - 网格变形：帧内容 `mesh.bp` 为 32 个浮点 = 图标归一空间 4×4 控制点
    （恒等 = 均匀网格，值可越出 [0,1]），cc 恒为 null。本项目按**三次
    Bezier 曲面**求值（「bp = Bezier points」为推断，与图层
    meshDivision 细分密度字段相容）；变形作用于携带图层自身的图标
    及其整个子树（blank 载体层即靠此扭曲虹膜子 motion）；tween 时
    bp 逐分量插值、缺失侧按恒等网格。两实现细分 WARP_SEG=5。
  - `src = "blank"` 是程序化矩形：图标名 `"W:H:OX:OY"`，本身不可见，
    只作变换载体与遮罩几何。
  - 模板：带 `stencilCompositeMaskLayerList` 的图层（stencilType 5，
    样本 612 个）把**其子树**裁剪到「同一 motion 实例内、指定标签
    图层下发出的部件」的 alpha 并集（由眼睛 motion 实证：虹膜被裁到
    shirome + add_mask）；遮罩取部件的**原始贴图 alpha**——トリミング枠
    部件帧 opa=0（永不绘制）仍须以全强度作遮罩，否则整个人物消失
    （实测）。stencilType 6（136 个）的遮罩源在本样本内不存在、子树
    不可见，作无操作。
  - 元数据 `metadata` 以 `E-mote追加パーツ，<名称>,<序号>,<ID>` 标记的
    图层子树是「追加パーツ」（样本 1,698 个：衣服、吐息、落ち影、腹
    等），原引擎在运行时开关，默认全开。
  - **角度有两种存储形态**（2026-10-28 定位 Mhide208a 头部 140° 假旋转时钉死）：
    整数存储时走 (180,255] 字节回绕（如 246 = −10°）；浮点存储时是 0..360
    度数形（如 350.0 = −10°），读入时归一到 (−180, 180]，tween 插值随之走短弧。
    两种形态混读会让脖子倾斜轴在关键帧间扫出 140° 的假旋转。
- `bm` 混合模式已解（2026-10-30，emotedriver.dll 逆向）：存部件 +0x20，渲染按 6 条 (BLENDOP, SRCBLEND, DESTBLEND) 三元组查表——样本 796 例的 bm=3 = (ADD, DESTCOLOR, INVSRCALPHA) 乘算系、2 例的 bm=4 = (ADD, INVDESTCOLOR, ONE) 屏幕系，另有独立 alpha 三元组；全表与实现映射见 docs/emote-driver.md §3。播放器渲染尚未接入（实现待排期）。
  色调字段（color 几乎恒为中性 0x808080FF）。物理揺れ与眨眼/口型已在
  播放器侧以驱动近似实现（见 architecture.md）。

## 文本编码（sce 字符串）

脚本字符串按包的字符集解码（样本为 GBK，原始日文包为 CP932）。
解码表由 `reference/python/make_charset_tables.py` 从 Python
编解码器生成并逐字节校验（GBK 表走 gb18030、CP932 表走 cp932：
双字节严格解码得单字 ≤ 0xFFFF 才收录），产物内嵌于
`src/loader/charset_tables.gd`（≤4 KiB 分片数组 + join）。
**教训（实测）**：码表不能用 loose 数据文件随包——Godot 文件
系统扫描忽略 .b64/.bin/.dat，改 .txt 后 CLI 导出仍不打包进
.pck，导出包会读到空表导致全文字乱码（MVP 起潜伏四轮）。

## Web 在线包格式（anim-webpkg/2，2026-10-28 第五轮）

由 `reference/python/web_package_build.py <游戏目录> <输出目录>`
预处理生成，播放器 Web 版（桌面在线模式同一代码路径）按需加载：

- 除 `movie/*.mpg` 外所有文件原样复制（同盘硬链接优先）；
- `movie/*.mpg` 以 ffmpeg 转码为 Ogg Theora/Vorbis `.ogv`
  （libtheora q6 / libvorbis q4；样本 78 部：394 MB → 171 MB），
  因 Godot 无 MPEG-1 解码器、Web 构建又无 GDExtension 支持，
  原生 Theora 是 Web 端唯一可行的电影路径；
- 产物先是 flat 形态（anim-webpkg/1）：`manifest.json` 为
  `{format: "anim-webpkg/1", sce, define,
  files: {相对路径: 字节数}, movies: {原名小写: ogv 相对路径}}`。
- **部署形态为 v2 bundle 打包**（同脚本
  `--bundle-from <flat目录> <输出目录> [--chunk-mb 256]`）：
  浏览器游戏通用的大包形态（类 Godot .pck / Unity bundle），
  全部文件按 256 MiB 上限顺序装入 `bundles/bundle-NNN.bin`
  （文件不跨包切割），manifest 改为
  `{format: "anim-webpkg/2", sce, define, bundles: [包相对路径],
  files: {相对路径: [包序号, 包内偏移, 字节数]}, movies: {...}}`。
  样本包：1,283 文件 / 3.83 GB → 10 个 bundle。碎文件形态在
  HTTP 上逐个请求的连接开销不可接受（实测慢约一个数量级），
  故 v1 只作中间产物，播放器两者都兼容；
- 播放器据 manifest 建索引：普通文件解析为 (bundle, 偏移) 后
  单次 Range 直读；GFilePack 内部条目不展开，包本身作为一段
  span 落在 bundle 内（`GFilePack.open_web_span` 基址偏移），
  仍靠两次 Range 复现头部解析、条目按需取数（响应须未被
  gzip 改写，否则偏移失效；bundle 为 octet-stream 不会被
  CDN 压缩，manifest 的整取不受此限）。

## define.dat 的 em 姿势表

记录格式：`[u32 9][u32 flags]` + 标签 + `(变量名, ASCII 浮点)` 对，
以 `('', '0.0')` 终止。样本共 177 条（130 条全 18 变量姿势 + 若干偏置集），
24 个变量（head/body/face 系列 + `arm_type` + `fade_v~z`）。
提取器：`define_extract.py`。

**关键概念：em 标签是「一组 E-mote 变量预设（姿势）」，不是 PSB 内的时间轴名。**
sce 的 `0x52` 加载模型、`0x7C` 套用 em 标签；播放器维护当前变量状态，
全姿势替换、偏置集增量合并。
