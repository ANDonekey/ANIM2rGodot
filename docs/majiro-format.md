# Majiro 引擎格式规格（STARLESS 实测）

> 分支：`engine/majiro`。样本：《STARLESS》（Empress，2011；yichengong 汉化硬盘版）。
> 研究在 instabox 主机 `orig-game` 上完成（`~/starless/`），参考实现为社区逆向成果
> trigger-segfault/majiro-py 与 AtomCrafty/MajiroTools——本文的每条结论都已在本样本上
> 实测复核，未复核的明确标注为「文档」。

## 1. 容器：MajiroArcV3.000（实测，全 9 个 .arc 一致）

```
+0x00  char[16]  "MajiroArcV3.000\0"
+0x10  u32       entry_count
+0x14  u32       name_table_offset
+0x18  u32       data_offset
+0x1C  entry[count]        每条 16 字节
       name_table          明文 CP932 文件名，\0 分隔，与 entry 一一对应
       data 区             条目原始字节拼接
```

entry 结构（16 字节）：

```
+0  u32  name_hash 低 32 位
+4  u32  name_hash 高 32 位
+8  u32  offset（绝对文件偏移）
+12 u32  size
```

- 条目按 name_hash 升序排列；文件名不加密，靠同序 name_table 对应。
- **name_hash = Majiro 的「错误实现版 CRC-64」**：反向 CRC 算法误用正向多项式
  `0x42F0E1EBA9EA3693`，init/xorout 均为全 1，输入为文件名的 CP932 字节。
  scenario.arc 252/252 条全部对上（实测）。
- 标识符（脚本内函数/变量名）用标准 CRC-32（zlib 同款）哈希，称 hash32。

## 2. STARLESS 资源清单（实测，全包统计）

| 包 | 内容 |
| --- | --- |
| scenario.arc | 250 个 .mjo（日文原版脚本）+ 2 个 .winmerge（XML 界面定义） |
| updateCHS.arc | 227 个 .mjo（汉化重编译脚本，同名覆盖）+ 汉化 .rct/.rc8 + majiro.env |
| data1.arc | .ogg（SE）291 + .rct 140 + .rc8 3 |
| data2.arc | .rc8 2107 + .rct 2107 |
| data3.arc / data4.arc | .rct 871 / 2060 |
| voice.arc | .ogg 15540（全语音，原生 Ogg Vorbis） |
| stream.arc | .ogg 21（BGM 等流式音频）+ 播放列表 .m3u |
| fastdata.arc | .rct/.rc8（系统图）+ .cfg 11（CP932 文本配置）+ .wav 2 + .env 1 |
| movie/（散文件） | StarlessOP.mpg（MPEG-1） |

合计：.mjo 477、.rct 5269、.rc8 2170、.ogg 15852。
图像只有 .rct/.rc8 两种 Majiro 私有格式——**没有 PNG/BMP 散图，UI 也是素材驱动**
（与 ANIM 的结论一致）。

## 3. 脚本：.mjo（MajiroObjX1.000）

```
+0x00  char[16]  "MajiroObjX1.000\0"
+0x10  u32       entrypoint_offset（入口函数在 code 内的偏移）
+0x14  u32       未定字段（样本值 0 / 79 / 906 / 4465…，疑为入口函数序号或数据量，待定）
+0x18  u32       function_count
+0x1C  function[function_count]   每条 8 字节：{u32 name_hash32, u32 code_offset}
       u32       code_length（= 文件剩余长度，实测多文件精确吻合）
       code[code_length]          加密字节码，见下
```

- **加密**：code 段逐字节 XOR，密钥流 = 标准 CRC-32 表（256 个 u32 小端打包）
  构成的 1024 字节周期序列，自 code 起始对齐（crypt32，实测解出完整日文原文与
  资源名操作数）。`MajiroObjV` 变体用 CRC-64 表的 2048 字节密钥（crypt64，文档；
  本样本全为 X 版，未涉及）。
- **指令**：u16 操作码 + 类型化操作数（类型表、CP932 字符串、哈希、变量偏移等），
  栈式虚拟机；入口函数哈希恒为 `0x1D128F30`（实测，本样本单函数文件均为此值；
  社区已知哈希库可反查部分函数/系统调用名）。引擎宿主功能以 syscall 形式提供
  （文本显示、图像、音频、存档等），是播放器实现的主要工作面（文档 + 待逐项实测）。
- 汉化版 .mjo 是用 MajiroCompile 重新编译的完整脚本（非文本替换），与日文版
  结构同构、体积不同（实测同名文件公共前缀仅 36 字节）。

## 4. 其它格式

- **.rct / .rc8**：Majiro 私有图像。文件头有固定 4 字节混淆前缀，其后可见
  `TC01` 等结构与被引用的基础图文件名（如 ef02_04.rct 引用 EF02_01.rct，
  疑为差分/合成图）；完整解码按 MajiroTools 的 Rct/Rc8 文档实现时逐项验证（待做）。
- **.ogg**：原生 Ogg Vorbis，Godot 直接可播（语音 15540 条是本作的体量大头）。
- **.cfg / .env**：CP932 明文文本配置，含 CG 鉴赏等模式定义，直接可读。
- **.winmerge**：XML 文本（消息窗等界面合并定义）。
- **CHS.TBL**：汉化字表（122880 字节）；Longinus.dll 是汉化组的字体/编码注入钩子，
  播放器不依赖它——但汉化 .mjo 内文本为 GBK 编码，渲染时按包来源区分编码。

## 5. 加载分层（实测 + 推断）

- updateCHS.arc 与 scenario.arc 同名条目对应：引擎按包优先级以汉化包覆盖原版
  （汉化组标准做法，条目名 227/234 与原版重合；覆盖顺序的精确规则待运行时验证）。
- 播放器应复刻同一分层：先挂原版包，再叠补丁包。

## 6. 实现计划（engine/majiro 分支）

1. GDScript 版 MajiroArcV3 读取器（明文索引，实现量小）+ hash64 校验。
2. .mjo 加载器：crypt32 解密、函数表、指令解码（对照 majiro-py 的 opcodes 表移植）。
3. MjoVM：栈式执行 + syscall 宿主层（先打通文本/选项/图像/语音的主线路径，
   按样本实测逐项补齐）；呈现层复用主线播放器的窗口与存档框架，语义按 Majiro 重写。
4. .rct/.rc8 解码器（按文档实现 + 与原版截图对照验证，同 ANIM 的真值台方法；
   原版可在同一台 instabox 主机的 Wine 下运行）。

## 8. 社区生态普查（2026-10-29，逐项核查）

- **不存在任何 Majiro 运行时/播放器重实现**（开源、闭源免费、跨平台均无；
  唯一被宣传过的 KrKr2「Majiro 支持」从未发布，仓库只含 Kirikiri 本体）。
  本分支即首个 Majiro 播放器，与 ANIM 侧的定位相同。
- 现有成果全在工具侧：majiro-py（反汇编/汇编 + 格式文档，最完整）、
  MajiroTools（C# 工具 + Wiki：完整操作码表、**163 条 syscall 的权威名表与参数**、
  1839 条已知哈希名）、VNTextPatch（文本提取/回填，其 MajiroDisassembler 可作
  指令编码的第二参照）、GARbro（arc 提取，C# 实现可作 V1/V2/V3 对照）、
  arc_conv（arc 打包，证实还存在 MajiroArcV4；本样本为 V3）。
- 实现方针：格式与语义以 majiro-py + MajiroTools Wiki 为文档基线，
  以本样本实测与原版 exe 的反编译（REA）为裁决。
- 补充核查（同日续）：封包层另有 detached64/GalArc（C#，V1–V3 解包+封包）
  可与 GARbro 互证；3licie/majiro-tools 里的 `mjdev.rar` 已验明**并非官方
  开发包**，而是 2005–2006 年的社区 OCaml 工具链（mjarc/mjasm/mjcrypt/
  mjdisasm + 全源码，GPLv2，arc_conv/text_conv 一脉的祖辈）——可作第三方
  互证，其 NOTES 记有一条引擎行为：图像查找不到 .rct/.rc8 时回退同名 .png
  （文档，未实测）。官方材料方面现存最佳线索是《Narcissu 10th Anniversary》
  泄露的官方脚本源 `console.mjs.old`（MajiroTools Wiki 外链）。

## 9. STARLESS 数据行为普查（实测，477 个 .mjo 全量反汇编）

- 指令总数 896,634；`text` 指令 101,892 条（全作对白/旁白量）；
  `ctrl` 199,911（文本控制）、`callp` 186,014、`line` 109,582（源码行号保留）。
- **实际用到的 syscall 名共 289 个**（含同名 syscall 的类型签名变体，
  名尾 `#`/`$` 即 MjIL 的返回类型标记；与引擎名表 163 条的差额构成待逐项对账）。
  大头：`sound` 族（sound/sound2/3/4
  + vol/fadeout/stop，合计约 2 万次）、`wait`、`file_read`、`sprite_*` / `page_*` /
  `grp_*`（页面-精灵图形模型）、`thread_begin/end`（脚本多线程）、
  `areaevent_set` / `event_hook`（点击热区）、`fontout*`（页面直写文字）。
- 函数调用目标 285 个：118 个可由社区哈希库命名（按组分工明确——
  `@KOEKOE` 语音/声音、`@PIC` 画面切换、`@MENU` 选择肢、`@CONFIG`、`@CGMODE`、
  `@BUTONMENU`、`@CONSOLE`）；167 个未命名者是游戏自有库函数（定义就在语料的
  其它 .mjo 里，可由函数表按哈希建全局索引自解）。调用量第一的
  `$e1751505`（99,005 次，几乎每句对白前调用一次）即属此类。
- 图形模型要点：脚本以 page（离屏图像缓冲）+ sprite（显示对象）为基本单位，
  与 ANIM 的部件合成模型不同，呈现层需按 Majiro 语义新建。

## 7. 未决问题

- ~~.mjo 头 +0x14 字段的语义~~ → §10.2：按脚本分配的标记位图大小（推断为既读标记）。
- .rct/.rc8 的完整像素解码与合成规则。
- arc 覆盖优先级：脚本层已由 §10.3 解释（后加载者优先 + 当前脚本优先）；
  资源文件层（同名 .rct/.ogg 跨包）的 VFS 搜索顺序仍待运行时验证。
- ~~syscall 覆盖清单~~ → §10.5：483 条全表已提取，语料覆盖 289/289。

## 10. STARLESS.exe 逆向（实测，REA+Ghidra 反编译，2026-10-29）

样本 STARLESS.exe（827,392 B，sha256 e8d015d7…）。以下地址均为该样本的 VA。

### 10.1 主循环与解释器（FUN_00411620）

- 引擎主循环与 VM 解释器是同一个函数：外层做帧定时（timeGetTime）、
  线程调度、等待/输入处理；内层为取指-译码-执行循环。
- 调度器遍历线程表（FUN_004266a0），逐个线程用 FUN_00426560 切换
  「当前线程」全局量（DAT_005b46a8 = 线程块，DAT_005b46a4 = 当前帧 +0x28 的 pc 槽），
  FUN_00426610 判活后跑内层循环，直到线程状态字 DAT_004c2140 非 0
  （0=运行，1=让出/等待中，2=退出，4=结束一帧，5=错误）。
- 译码：pc 处读 u16 操作码。`< 0x232` 经字节索引表（0x412784）映射到
  约 72 个基础处理器（FUN_00413c80–FUN_00415xxx，成对的 (0)/(1) 变体 =
  操作数形态差异）；`0x232–0x308` 为 stelemp 等稀疏变体；
  `0x309–0x835`、`0x836–0x850` 为两段 switch。操作码全表与 majiro-py
  opcodes.py 一致；语料实际只用 74 个操作码（0x100–0x850）。
- 未知操作码 → FUN_00410380 致命错误。

### 10.2 线程/帧/值模型

- 线程块：值栈在块 +0x24（16 B/值，容量 +0x10，满时 +0x100 槽 realloc），
  帧数组自 +0x28 起、**帧_stride = 0x4C B（19 个 u32）**，帧深上限 255。
- 帧布局（由 FUN_00426720 压帧、FUN_0040fc30 等推得）：+0x28=pc（相对帧基址
  +0x00 即 DAT_005b46a4 指向处），+0x30=值栈顶索引（相对帧 +0x08），
  +0x34=返回上下文，帧内 +0x14/+0x18/+0x1C 三个「等待截止」槽
  （调度器按当前时钟比较，bsel 系指令操作的对象）。
- 值 = 16 B：{+0x00 数据低，+0x04 标志，+0x08 类型，+0x0C 数据}。
  push 原语：FUN_00425f80（整值拷贝）、FUN_00426050（ldc.i 型：
  类型 3、标志 0、数据=操作数）、FUN_004260d0（ldc.r 型：标志 1）；
  FUN_00425980 = 值析构（字符串/数组释放）。当前值访问器 FUN_00426030
  返回栈顶值指针（其 +0x0C 为数据域，一元运算指令直接在原地改写）。
- .mjo 头 +0x14：加载器据此为每脚本建一个独立链表节点，内含
  ⌈(n+7)/8⌉+0x10 字节的位图（DAT_004c2148 链表）——推断为既读标记位空间，
  与 savedata/majiro_readmark.mss 对应（待存档结构验证）。

### 10.3 脚本加载与函数解析

- 加载器 FUN_004109e0：脚本对象 0xB0 B，名字存对象头，**缓存键 = hash64（名）**，
  全局链表 DAT_004c2144（新加载者插到表头）。先试松散文件，失败则把
  scenario、scenario1…scenario9 依次注册进搜索集（FUN_00451ad0）再重试。
  魔数先比 MajiroObjV1.000、再比 MajiroObjX1.000，**仅 X 格式对代码段
  执行 crypt32 解密**（FUN_00454f90）。
- 脚本调用指令（call/callp）在指令流内嵌 10 B 自缓存描述符
  {u32 名哈希， u32 已解析代码指针（原地回填）, u16 argc}（FUN_00413200）。
- 解析器 FUN_00410f90（哈希→代码指针）：先查「当前 pc 所在脚本」的函数表
  （以 pc 落在哪个已加载脚本的代码区间判定），再按加载链表顺序查其余
  脚本，均为线性扫描；未找到 → 致命错误。由此：后加载的同名函数在全局
  查找中先命中（汉化脚本覆盖的机制），而脚本内调用先落到自己。

### 10.4 等待/挂起模型

- syscall 需要等待时：置线程状态 1 并令 **pc -= 8**（回退整条 syscall
  指令长度：2 操作码 + 4 哈希 + 2 argc），下一 tick 重新执行该 syscall。
- 定时等待（哈希 0xCF35F0E3，派发器内联实现）：时长取自栈值，
  截止 = 当前时钟 + 时长；-2 = 无限等待（置全局等待态），
  另有按值字段的变体（0xFF75CD29）。输入等待（0x008ACBC0、0x1204D7E8）
  轮询按键（0x21/0x22/0x93 等）与三路按钮槽，返回按钮位掩码。

### 10.5 syscall 派发（FUN_00416400）

- 操作数 = {u32 名哈希， u16 argc}；派发器是编译器展开的**哈希比较
  二叉树**（无名字表、无哈希表数据段——exe 内不存在 syscall 名字字符串，
  仅各处理器内部的日志格式串含名字）。
- 全表已机械提取（Capstone CFG 分析 + Ghidra 伪代码两路交叉验证，
  重叠 298 条零分歧）：**456 个独立处理器 + 27 个派发器内联实现**，
  见 `docs/majiro-syscalls.json`；STARLESS 语料用到的 289 个哈希
  **全部覆盖（289/289）**。
- 收尾语义：syscall（0x834）保留返回值——析构 argc 个参数与中间值后
  把栈顶返回值搬到参数基址槽，sp = 基址 + 1；syscallp（0x835）全部析构，
  sp = 基址。与 majiro-py 的 transition 记法 `[*#a].*` / `[*#a].` 对应。
- 名字对账：哈希是对标识符全名（含类型/作用域修饰）的标准 CRC32
  （majiro-py `crypt.hash32`），名↔哈希用其 known_hashes 库对账，
  实现期逐条落名。

## 11. 运行时语义补遗（实测，VM 实现期 2026-10-29）

- **启动顺序**（WinMain FUN_0042e480）：注册 VFS 搜索族（update12…update、
  fastdata12…fastdata、scenario…等，update 族最先）；加载 `start`，先解析并
  执行其 `$init@GLOBAL`（即各脚本偏移 0 处的函数，负责 load_library 全部
  库脚本），之后才以头 entrypoint 偏移进入 `$$main@GLOBAL`。脚本重启动作
  同理：按名加载、以 entrypoint 进入 $$main（偏移为 -1 则致命错误）。
- **标识符哈希形式**：函数名以 `$名@组` 的完整形式做标准 CRC32，
  实测 `$main@GLOBAL` = 0x1D128F30、`$init@GLOBAL` = 0xB1BB8ADC
  （MjIL 显示的 `$$main` 是展示层再加的函数标记，不入哈希）。
- **相对偏移基准**：一切相对偏移都相对于「该偏移字段自身的末尾」——
  分支指令即指令末尾（pc 在处理器执行时已越过整条指令），switch 的每个
  case 偏移相对于该 case 条目自身的末尾（at + 8 + 4·i + case[i]）。
  社区文档「相对指令起点」的说法不确。
- **变量模型**：hash 作用域（persistent/savefile/thread）以 (哈希→单元数组)
  存储、offset 索引单元；**local 作用域是每帧一个数组、offset 即槽号**
  （实测同一函数 79 个 local 变量 offset 互不冲突、最大 100；alloca 的
  类型表即帧槽位表）。offset = -2 为数组长度伪元素（hash 作用域）；
  offset = -1 为合成单值单元，语料中仅 `$__SYS__NumParams`
  （0xA704BDBD，171 处）使用，读值 = 当前帧实参个数。
- **load_library**（syscall 0x10DB0A43/44）：引擎加载器对脚本名做
  大小写折叠（脚本里写 `UserTrans`、包内文件是 `usertrans.mjo`）。
- **add.s 的类型强制**：数值操作数会被字符串化后拼接（pic 库以此拼
  文件名）；字符串比较同样对操作数做字符串强制。int 除法向零截断、
  除零得 0（与 MajiroTools 文档的怪癖表一致）。
- st 族存值后保留栈顶值（编译器随后以 pop 丢弃），stelem 的栈序为
  [值, 索引…]（值在最深处）；stp/stelemp 为存后弹出版本。

## 12. 图像格式 .rct / .rc8（实测，2026-10-29）

- 通用头（20 B）：`98 5A 92 9A`（「六丁」）+ 4 字符签名 + u32 宽 + u32 高
  + u32 数据长。签名：rct 为 TC00/TC01（明文）或 TS00/TS01（XOR 加密，
  本样本未见）；rc8 为 `8_00`。样本图多为 1280×960（客户端 1024×768，
  引擎缩放呈现）。
- **TC01**：头后 u16 底图名长（含 NUL）+ CP932 底图文件名，随后才是
  本图数据。合成规则：本图像素覆盖底图，**纯红 #FF0000 为透明**（露出
  底图）；底图可递归。实测 bg04a（99.1% 透明、11,014 像素变更）合成
  无缝。
- **rc8**：头后 256×RGB 调色板（**RGB 序**，与 rct 的像素 BGR 序相反），
  随后是索引数据流；引擎中常用作 rct 的 alpha 通道（配对在图形层）。
- **数据流 = LZ77 指令流**：首像素原始字节；其后命令字节循环——
  bit7=0 为直读（count=cmd，0x7f 时再加 u16；实际像素数 count+1）；
  bit7=1 为回拷（count=cmd&CountMask，取满时再加 u16；像素数
  count+CountBase；shift 索引 =(cmd&0x7f)>>ShiftStart，查宽度相关的
  移位表得「像素偏移」= (s>>4) − (s&0xF)×宽，乘字节深度得字节偏移，
  自当前位置之前重叠拷贝）。
  参数：rct 深度 3、移位表 32 项、ShiftStart 2、CountMask 0x3、
  CountBase 1；rc8 深度 1、移位表 16 项、ShiftStart 3、CountMask 0x7、
  CountBase 3。移位表本体见 MajiroTools wiki（Format: Rct image）。
- 验证：Python 参考解码 263 张（data1 全量 + 其余 arc 抽样）全部精确
  消费 DataSize；bg13/bg01/ea03/ea04 等整图与 bg04 合成图目视无误；
  GDScript 实现（MajiroRct）与参考 md5 对账 24 张全同（TC00/TC01/8_00）。

## 13. 既読 readmark（实测，2026-10-29）

- .mjo 头 +0x14 = 该脚本的**文本行数**（majiro-py 旧称 line_count）：
  与 savedata/majiro_readmark.mss 中 227 条记录的 text_count **逐条全等**。
- readmark.mss = 条目序列（无文件头），每条：128 B 脚本名（CP932、
  大写 .MJO）+ u32 bitmap 字节数 + u32 text_count + 3×u32 残留指针
  （写出进程的链表地址，读时忽略）+ bitmap 本体。
  bitmap 字节数恒 = ⌈text_count/8⌉ + 16，与加载器为每脚本分配的
  ⌈field_0x14/8⌉ + 16 B 位图一致；每 bit 对应一行文本的已读标记。

## 14. 存档文件（结构初探，2026-10-29）

- `majiro_NNNN.sav`：16 B 头 `MajiroSavV1.103\0`，其后为 CP932 存档
  标题（定长填充），主体为线程/变量的序列化状态；文件中段可见以
  记录形式存入的脚本名（如 `STARLESS.MJO`）。完整解码需对照 exe 的
  存/读档函数，后续专项处理。
- `majiro_system.mss`：16 B 头 `MajiroSysV1.100\0` + u32 计数/尺寸
  字段，其后数据高熵（疑似加密或压缩的全局变量存储），未解。
- `majiro_readmark.mss`：见 §13（已完全钉死）。

### 12.1 伴随掩码与加密变体（GARbro 源码交叉验证，2026-10-29）

- GARbro 的独立实现（ArcFormats/Majiro/ImageRCT.cs）与 §12 的头格式、
  LZ 参数、TC01 纯红透明合成规则完全一致（交叉验证通过）。
- **掩码伴随文件**：`<名>_.rc8` 是同名 .rct 的 alpha 掩码（掩码像素经
  其调色板取灰度均值再取反作 alpha）。STARLESS 实测：data2.arc 中
  约 2,107 个 `_.rc8` 条目（全包 rc8 共 2,170 个）——绝大多数 rc8
  是掩码而非独立图片，立绘类素材应按 rct+掩码合成 RGBA。
- **TS00/TS01 加密变体**：数据段与 1024 B 密钥 XOR；密钥由口令派生：
  key32[i] = crc32(口令的 CP932 字节) XOR crc32 表[(i + crc32) & 0xFF]；
  口令可由 scenario.arc 的 start.mjo 中提取（GARbro FindImageKey）。
  STARLESS 样本无 TS 文件，未实测。

## 15. br.case / bsel / switch 语义（REA 实测，2026-10-29）

- **br.case（0x830）**：把栈顶被比较值存入线程内部变量
  `%Op_internalCase~@MAJIRO_INTER`（哈希 0x11F91FD3，经 FUN_00425c00
  单元解析器），弹出，随后无条件跳到检查链首。
- **bXX.case（0x831/832/833/838/839）**：把内部变量与栈顶常量（保留
  不弹）比较，**关系成立则跳到下一检查、不成立则落入 case 本体**：
  bne=≠、bge=≥、ble=≤、blt=<、bgt=>（FUN_00413970/FUN_00413a00 实测，
  ble/blt/bgt 为同族对称推断）。编译形态：每 case 先 ldc 常量再 bXX.case。
- **switch（0x850，FUN_00413370）**：索引越界（负或 ≥ 计数）时取
  **最后一项**作默认；case 偏移相对该条目自身末尾（与 §11 统一规则同）。
- **bsel.\***：按钮选择的目标登记机。帧字段 [5][6][7] 存三个按钮的
  跳转目标、[8] 存锚点；线程块 +0x4c38/3c/40 是输入层置位的按钮锁存。
  bsel.1/2/3 登记对应目标、锁存已置位则消费并跳转（FUN_004133e0）；
  bsel.x 同一目标登记三键（FUN_00413500）；bsel.clr 清 [5..7]；
  bsel.4 只记锚点不跳；bsel.jmp.4 沿帧栈回退到持有锚点的帧并跳转
  （FUN_00413600）。无输入环境下锁存永不置位，登记后顺序执行。
- VM 实现后启动流回归：**未处理项 0**，步数/调用/syscall 数与此前一致。
