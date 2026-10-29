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

- .mjo 头 +0x14 字段的语义。
- .rct/.rc8 的完整像素解码与合成规则。
- arc 覆盖优先级的精确规则（多包同名时谁赢、fastdata 的定位）。
- syscall 覆盖清单：哪些是 STARLESS 实际用到的（可由全脚本反汇编统计得出）。
