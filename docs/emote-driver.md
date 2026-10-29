# emotedriver.dll（M2 E-mote 运行时）逆向规格

样本：ANIM.teamMM《壁の向こうの妻の嬌声2》（kabe2）同梱 `emotedriver.dll`，623,104 B，SHA256 `27df27985abd24f0546e8db8c46e32a32333f99ece7e782ab11e2858c941e71b`。
工具：instabox 对照机（orig-game）上 REA（Ghidra 12.1.2）反编译/交叉引用 + 二进制扫描（2026-10-30）；官方资料对照：M2 官网手册/FAQ、用户提供的 WebGL 示例 SDK 包（内含 `iemote.h` 与带符号的 asm.js 构建）。
标注约定：**实测** = 本轮反编译/动态验证；**文档** = 官方资料原文；**推断** = 证据拼合、未直证。

## 1. 导出面与对象模型（实测）

- 仅 2 个 C 导出：`EmoteCreate`（RVA 0x2EE0）、`EmoteFilterTexture`（RVA 0x2F50）。宿主 exe 只 import 这两个，其余全部走 C++ 虚表。
- 抽象接口：`IEmoteDevice` 虚表 @0x100775A4（24 槽，23 槽为 purecall）、`IEmotePlayer` 虚表 @0x1007760C（64 槽）。
- 具体类：`PEmoteDevice` 虚表 @0x10077714（24 方法）、`PEmotePlayer` 虚表 @0x1007777C（64 方法）。类名与方法面与 SDK 包 `iemote.h` 同源（见 §8；头文件为更新世代，IEmotePlayer 约 88 槽，本 DLL 为 64 槽）。
- `EmoteCreate`：分配 0x10 B → `PEmoteDevice` 构造（FUN_10001220）：[0]=虚表、[1]=1、[2]=核心对象（0x428 B，构造 FUN_1005B0C0，参数 = InitParam[0]）、[3]=InitParam[0]（宿主接口对象）。InitParam[1]/[2] 若非空，装为全局 malloc/free 指针（PTR__malloc_10091db4 / PTR__free_10091db8）。
- DLL 仅 import `d3dx9_43.dll` 的 4 个矩阵函数（D3DXMatrixTranspose/Multiply、D3DXVec3Project、D3DXMatrixLookAtLH）与 KERNEL32；不 import d3d9——D3D9 设备由宿主持有、经接口传入，DLL 内的设备调用全部走虚表间接调用。
- RTTI 类清单（34 型）：PEmoteDevice/PEmotePlayer、AEmotePlayer/MEmotePlayer、AMotionPlayer/MMOTIONPlayer、AMotionRenderer/MMOTIONRenderer、MMotionManager、MMOTIONDevice、APSBObject/PSBObject、PSBFilter/StructCryptFilter，以及 `emote::` 命名空间的 11 个 EP*Control（§6）。

## 2. PSB 部件解析（实测，FUN_1003A3F0）

部件/node 解析函数按固定序读取属性：mask → coord → opa → bm → color（其余键见 .rdata 0x10078158 起的键表：act/src/ox/oy/fx/fy/angle/zx/zy/sx/sy/ti/ccc/occ/acc/zcc/scc/cp/mesh/cc/flags/dt/dofst/docmpl/dtgt/timeOffset/model/loop/prt/trigger/fmin/fmax/vmin/vmax/amin/amax/zmin/zmax/range/camera/target/feedback、particle* 与 stencilCompositeMaskLayerList 等）。每个属性先查部件 flags 位，命中才按名查 PSB 字典（FUN_10057F60，键缺失即 abort），值按类型类别表 DAT_100773E8 转换。

已钉字段（写入解析结构体 param_3）：

| 属性 | flags 位 | 落点 | 备注 |
|---|---|---|---|
| opa | 0x400 | param_3[0xF]（byte） | 不透明度 |
| **bm** | **0x20000** | **param_3[8]（+0x20，int）** | 混合模式，见 §3 |
| color | 0x200 | param_3[0xB..0xE] 四通道 + byte @+0x13 | 缺省四通道均为 −1 |
| coord | 0x2 | —（此前已解） | |
| motion | 0x80000 | —（此前已解） | |

flags 位与 `formats.md` 的既有表一致，本轮以解析代码复核无误。

## 3. bm 混合模式（实测，全链钉死）

渲染状态设置函数 FUN_1005C810 以模式值低半字节（bm & 0xF）索引表 DAT_10078720（条目 12 B = {BLENDOP, DESTBLEND, SRCBLEND}），逐项调 SetRenderState（D3DRS_BLENDOP=171 / DESTBLEND=20 / SRCBLEND=19）。表仅 6 条有效（第 7 条起为其他数据）：

| bm | BLENDOP | SRCBLEND | DESTBLEND | 效果 | 样本出现 |
|---|---|---|---|---|---|
| 0 | ADD | SRCALPHA | INVSRCALPHA | 标准 α 混合 | — |
| 1 | ADD | SRCALPHA | ONE | 加算 | — |
| 2 | REVSUBTRACT | SRCALPHA | ONE | 反转减算 | — |
| 3 | ADD | DESTCOLOR | INVSRCALPHA | 乘算系 | **796** |
| 4 | ADD | INVDESTCOLOR | ONE | 屏幕系 | **2** |
| 5 | REVSUBTRACT | SRCALPHA | ONE | RGB 同 2（差异在纹理阶段配置，见下） | — |

官方口径对照（文档）：E-mote 3.8 世代编辑器可读 5 种 PSD 混合（通常/乗算/スクリーン/焼き込み/覆い焼き）+ 加减，与上表集合相容；3.9 的 18 种为后世代扩展，不适用于本 DLL。

alpha 通道另有独立三元组（D3DRS_SRCBLENDALPHA=207 / DESTBLENDALPHA=208 / BLENDOPALPHA=209）：

- bm ≠ 0：(SRCALPHA=ZERO, DESTALPHA=ONE, OPALPHA=ADD)——目标 α 保持不变。
- bm = 0 且渲染器字段 [obj+0x2AC] = 0：(ONE, INVSRCALPHA, ADD)——标准 over 的 α 合成。
- bm = 0 且 [obj+0x2AC] = 1：(ONE, ONE, ADD)——α 相加。

纹理阶段（设备接口 +0x10C 的 stage-state 调用）由模式高半字节（0x10 位）与渲染器标志 [obj+0x284]（源自当前纹理描述符 +0x1C 字节，绘制循环在纹理切换时拷入）共同选择配置，影响颜色/α 操作数，不改变上表 RGB 混合三元组。运行时拼装字的逐位来源未完全对账（推断：高半字节来自部件的 mask 相关属性）；实现时以 bm 低半字节查上表为准，stage 配置取标准 modulate 近似。

播放器实现映射（Godot）：bm=0 → 常规混合；1 → 加算；3 → 以 (src×dstColor + dst×(1−srcA)) 写自定义 shader 或材质混合近似乘算；4 → 屏幕近似 (src×(1−dstColor) + dst)；2/5 → 反转减算近似。精确等价以 (op, src, dst) 三元组在 shader 中直写为准。

## 4. 渲染器结构（实测）

- 状态缓存式：绘制循环（FUN_10005099 区，AMotionRenderer）逐 draw item 比对（纹理索引 item+0x24、打包字 item+0x10、item+0xC 字、纹理描述符 +0x1C 标志），仅在变化时调 FUN_1005C780（写颜色 float 四分量 [state+0x418..0x424]，分量序 A=byte0、R=byte1、G=byte2、B=byte3）/ FUN_1005C810 刷新设备状态。
- 渲染目标模式（FUN_1005D5D0）：[state+0x270]=0 为直绘（alpha 测试三件套 ALPHATESTENABLE/ALPHAREF/ALPHAFUNC 取自 [0x398/0x39C/0x3A0]）；=1 为离屏路径（SetRenderTarget + FUN_1005C440 视口设置 + 状态刷新），mask 合成走此路径。
- **mask 世代定性（文档+实测方向一致）**：本 DLL 属 TYPE1（纹理内嵌型）世代，mask 为 **α 值掩码**；TYPE2 世代才用 stencil 2 值掩码（3.9.3 发布说明）。PSB 键名虽含 stencilCompositeMaskLayerList，本代实现按 α 掩码理解。

## 5. 纹理过滤 EmoteFilterTexture（部分实测）

`EmoteFilterTexture`（FUN_10002F50）是真实的 PSB/纹理处理例程，涉及 `StructCryptFilter` 与常量串 "1195030893"（FUN_10060E67）——PSB 纹理加密过滤器。样本游戏的纹理经现有解析链可正常解码，本函数的完整算法未逐行反编译（残项，见 §9）；播放器若遇解不出的纹理变体，先查此函数。

## 6. 变量系统与 EP*Control（实测 + SDK 符号对照）

架构（实测）：11 个控制类（EPBustControl / EPEyebrowControl / EPEyeControl / EPGraph / EPLoopControl / EPMouthControl / EPPendControl / EPRotateControl / EPSelectorControl / EPTransitionControl / EPWindControl）的虚表**各仅 1 槽**——标量删除析构；其余方法均为非虚函数，经变量系统的工厂/类型分发调用。对象由工厂按 PSB 变量定义逐个构造（Pend 工厂 FUN_1000C780：读 PSB 数值 → 参数块 → malloc 0xB0 → 初始化 FUN_10027670）。

方法面（文档：SDK 包带符号构建的 demangle 全表，与 DLL 类名逐一对应）：各控制类统一形态 `epProcess`（逐帧求值）/ `epSetInternal(InternalParam)` / `epGetInternal` / `epSkip` / `epRunning` / `epSetCommand`；个别专有：

- **EPGraph**：`epCalcRoute` / `epLength` / `epSetData`，内部型 Line/Cross/Route——图插值变量在关键值图上走最短路（与官方手册「眉推移は最短経路を自動計算」互证，符号级实证）。
- **EPPendControl**：`epProcess` / `epSetInternal` / `epSkip` / `epUpdateWind`（风对摆的耦合入口）。
- **EPWindControl**：`epProcess` / `epStartWind` / `epWind`；对应公开 API `IEmotePlayer::StartWind(start, goal, speed, powMin, powMax)`（iemote.h）。
- **EPMouthControl**：另有 `epSetMouth` / `epSetTalk`（口型与说话量）。
- **EPSelectorControl**：内部 Option 表（对应 arm_type 选择器）。
- 世代差：SDK 包（新世代）**无 EPLoopControl**，本 DLL 有——循环在旧世代是独立控制类。

EPPendControl 对象布局（实测，FUN_10027670）：共 0xB0 B；[0]=虚表；[1..0xD]=13 个参数（源自 PSB 变量定义：范围/速度类量）；[0xF]=1（字节标志）；其后是 3D 摆链状态——锚点 vec3（全局 DAT_10091DF8 起）与方向 vec3（DAT_10091DE4 起），以参数 [6]/[7] 为两节长度算出关节点 [0x16..0x1B]，[0x1C..0x21] 为当前/上一位置副本、[0x22..0x27] 为复位副本——Verlet 式链式摆（当前+上一位置积分布局）。

变量语义校验口径（文档，官方手册附录变量表）：face_eye_open / face_eyebrow / face_mouth 为图插值变量（关键值与中间点结构有官方表）；物理输出为 LR / LR_M（弛み）/ UD 三通道、钳制 −30..+30；物理预设 = 质量/抵抗（阻尼）/弹性组合 + 全局「物理挙動スケール」，数值公式官方未公开，以 DLL 逆向为准（本轮未逐行反编译 epProcess 的积分公式，残项见 §9）。

## 7. 与播放器的关系

- bm：按 §3 表实现（此前求值器仅透传 bm、腮红等部件混合不正确，本轮已解）。
- mask：按 α 掩码实现（§4），不做 stencil。
- 变量：以官方变量表校验现有求值器的插值路径（尤其眉/眼/口的图插值与最短路）；Pend/Wind 以「Verlet 链 + 风耦合」结构建模，参数取 PSB 定义原值。
- 时间线差分/主时间线、face_talk 由 WAV 波形生成等编辑侧机制见官方手册（SDK 参考笔记），与运行时格式无冲突。

## 8. 来源与世代

- 本 DLL：DirectX9 原生、TYPE1、IEmotePlayer 64 槽（约 2016 年世代，随 kabe2 发布）。
- WebGL 示例 SDK 包（2020-06 打包，readme 2018 版）：asm.js（Emscripten）跨平台 OpenGL 构建，IEmotePlayer 约 88 槽；`.emtbytes` = PSB v3 原文件改名，与本作同容器世代；`iemote.h` 为完整原生 API 参考（IEmoteDevice 21 虚函数、InitParam 仅 allocator 一项——与本 DLL 的 InitParam[1]/[2] malloc/free 注入吻合）。
- 许可注意（文档）：示例 SDK 仅供示例角色验证、禁止商用与解析，条款在下载页；本规格仅记录结构事实用于自研播放器互操作。

## 9. 残项

- EP*Control 各 `epProcess` 的逐帧积分/插值公式未逐行反编译（Pend 的 Verlet 链结构与参数布局已钉，公式待需要时按 epProcess 地址在 DLL 内继续追）。
- 模式字高半字节（0x10 位）的逐位拼装来源未对账（不影响 §3 像素语义）。
- `EmoteFilterTexture` / StructCryptFilter 的完整算法未逐行反编译（样本纹理不依赖它）。
