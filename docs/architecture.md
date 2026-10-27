# 播放器架构设计（Godot）

设计原则：**运行时解释原包**。加载器、虚拟机、渲染器三层一一对应逆向成果，
Python 参考实现是规格的对照基准，移植以「同输入同输出」验收。

## 模块划分

| 模块 | 职责 | 规格来源 |
| --- | --- | --- |
| Loader | 扫描游戏目录；GSecret 解密、GFilePack 解包按需供数（不预解全包） | `docs/formats.md`、`anim_gsecret.py`、`unpack_kabe2.py` |
| ScriptVM | 解释 sce 字节码：标签/跳转/调用、标志变量、Select 分支、对白队列、系统标签与主循环语义 | `docs/sce-format.md`、`sce_token.py`、`sce_parse.py` |
| EmoteRenderer | PSB 解析 + 变量评估 → 每帧生成图层四边形列；姿势切换对变量字典做插值过渡；眨眼/口型时间轴驱动 | `psb_parse.py`、`emote_render.py`、`define_extract.py` |
| Stage | BG/CG 图层、转场（ParamSet id 1/33/34/35/40/71 的近似或 shader 实现）、HC 全屏场景 | `sce-format.md` §4/§4.1 |
| Audio | BGM（`.eog` 剥头直播、循环）、语音（`.pck` 按名取）、BGV/环境声参数（`0xAC`，轴义待定） | 同上 |
| Video | MPEG-1 播放：pl_mpeg 经 GDExtension 接入；接入前先做跳过占位 | — |
| UI/系统 | 对话框、存档（先实现播放器自有存档；原引擎 500 槽快照语义后补）、回想、画廊、设置 | — |

## Godot 侧落点

- 语言：GDScript 起步（评估器热点若不够再局部换 C#/GDExtension）。
- 渲染：立绘每部件一个带纹理的 `Polygon2D`/`MeshInstance2D`（图集纹理共享），
  变换由评估器逐帧给出；网格变形阶段改用 PSB 的 bp 网格作顶点。
- 分辨率基准：原引擎 1280×720；BG/CG 的 2048 画布只取不透明子矩形上屏。

## 平台与数据包加载（三端同代码）

游戏数据永不打进 `.pck`，三端差异只在"怎么拿到目录"这一层：

- **桌面**：原生目录选择对话框，读外部目录。
- **Android**：存储权限读外部目录。
- **Web（与原生版并行开发）**：通过 JavaScriptBridge 走浏览器文件选择
  （`webkitdirectory` 选整个游戏文件夹），文件只在用户浏览器本地读取、不上传；
  可选 IndexedDB 持久化免重复选择。导出关闭线程支持以免依赖
  COOP/COEP 响应头（宿主仍建议支持，如 Cloudflare Pages 的 `_headers`；
  GitHub Pages 不支持自定义头，故不作首选宿主）。
  内存纪律：WASM 内存上限紧，Loader 必须按需解密、禁止预解全包。

Web 渲染走 Compatibility（WebGL2），与 project.godot 的既定设置一致；
音频 Ogg 浏览器原生可播；电影 MPEG-1 在 Web 端同样缺解码器，
候选为 pl_mpeg 编译到 WASM 或 jsmpeg，与原生版的 GDExtension 方案并行评估。

## MVP 定义（第一可玩版）

1. 选目录 → 识别数据包 → 从头开始播放主线；
2. 对白/旁白/选项/标志跳转正确（以 `sce-format.md` 的 50,561 条记录为回归基准）；
3. BG/BGM/语音/E-mote 立绘（静态评估帧 + 姿势切换淡入淡出过渡近似）齐全；
4. 电影跳过占位；存档先用播放器自有格式，仅支持进度存取。

## 后续阶段

- 姿势变量插值过渡、眨眼与口型时间轴动态驱动；
- 网格变形、物理揺れ近似、ParamSet 特殊转场（条带/放射/色淡）；
- pl_mpeg 接入（需装 NDK 做 GDExtension）；
- 原引擎存档快照（`0x16`）、画廊解锁（`0x1F`）等系统语义补全；
- 第二个游戏的数据包做兼容性验证（同引擎其他作品）。

## 未决问题清单

- `0xAC` (x, y) 参数轴义；`0x8E`/`0x8F` 标志区别；`0x92` 签名；`0xD6` 文本块语法；
- define.dat 中 em 表以外的部分；
- Mhide208a 某姿势渲染疑似多出一块身体部件（评估器保真问题，与宿主无关，两条路线都需修）。
