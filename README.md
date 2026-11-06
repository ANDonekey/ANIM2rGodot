# ANIM2rGodot — `engine/majiro` 分支

ANIM2rGodot 的**第二引擎分支**：为 **Majiro** 引擎从零实现的
**Godot 播放器**——把原版游戏的数据包放进来就能直接游玩，解释器
模式，不做逐部游戏的转换移植（思路同 ONScripter 之于 NScripter）。

- `main` 分支 = ANIM.teamMM 引擎播放器（见 main 分支的 README）
- 本分支 = Majiro 引擎播放器；每引擎一条分支，核心层各自独立

样本游戏：**《STARLESS》**（Empress，2011；yichengong 汉化版）。
生态普查结论：此前不存在任何 Majiro 运行时/播放器实现，只有
反汇编、翻译与资源提取工具——本分支是第一个运行时重实现。

## 现状（2026-11-06）

**核心层与表现层均已完成并全量实测**：样本游戏可从开机一路
跑到标题画面，菜单四个去向（New Game 正文链 / Load / Option /
Exit）全部端到端验证（截图实证）；正文在窗内以原版配色与
打字机节奏呈现，章节背景与原版 Wine 基线像素级一致。

实现要点与实现期钉死的语义见
`docs/majiro-presentation-design.md` §11–§12 与
`memory/devlog/2026-11-04.md` 至 `2026-11-06.md`：实参引擎序、
bsel.5 帧析构、timer_sync、areaevent 回调、sprite_paste 真签名、
引擎内置 CONSOLE_* 事件、fontout 家族、FRONT 合成帧语义、
sprite_push 搁置语义、pic_unpack 贴印分流均已实测钉死。
残留：存档后端未实装（Load 屏为空槽状态）、转场效果码未全、
菜单超时 attract 未验、movie_*（规格外）。

| 模块 | 状态 |
| --- | --- |
| MajiroArcV3 容器 | 已钉死：16 B 头 + 条目表 + CP932 名表；名哈希 = Majiro 的「坏 CRC-64」（反向实现误用正向多项式），样本 252/252 验证；GDScript 读取器实测通过 |
| .mjo 脚本（MajiroObjX1.000） | 头/函数表/crypt32 解密已钉死（头 +0x14 = 文本行数，readmark 227 条逐条对账）；477 个脚本（250 日文 + 227 汉化重编译）全量普查：896,634 条指令、text 101,892 |
| 指令解码器 | 操作码表自 majiro-py 注册表导出；与参考反汇编逐条对账，全语料扫描 896,634 条零失步 |
| VM 核心 | 真实启动流跑通：加载 start → $init@GLOBAL → $$main；$exec/$call 已实装、章节链（STA000 → STA001a0 → STA001b0）真实推进；load_library 启动 17 个库 main；$exec 派发引擎内置 HOT_RESET；未知 syscall 收敛至 3 个正当桩（reg_read / show_mouse_cursor / 引擎记账 $c438ba98）；br.case / bsel / switch 语义已 REA 钉死并实现 |
| syscall 宿主层（MajiroHost） | 派发器全表已提取：456 个处理器 + 27 内联（`docs/majiro-syscalls.json`），语料 289 个名哈希全覆盖；文件族（CP932 文本逐字段扫描：逗号/换行定界、字段内空格保留）、dim_create、字符串/数学工具族、get_variable/set_variable（名哈希 = 明文 CRC-32）均为真实实现 |
| 文本层 | CP932 / GBK 编解码表（gzip+b64 存仓，生成器 `generate_tables.py`）；汉化字形替换 codec「chs」（CP932 对 → CHS.TBL → GBK 码）已钉死并与离线 oracle 逐条对齐（155 条真中文） |
| .rct / .rc8 图像 | 解码规格钉死：20 B 头 + LZ77 指令流；rct = 24bpp BGR、rc8 = 8bpp 调色板；TC01 带底图名、纯红透明递归合成；绝大多数 `.rc8` 是同名 `.rct` 的 alpha 掩码（`_.rc8` 规则）；GDScript 解码与 Python 参考实现 md5 对账 24 张全同；汉化补丁的三张牌图为近原始字面流（整流短 2 px），解码器已改输入有界容忍 |
| 存档格式 | `.sav` / `system.mss` / `readmark.mss` 全解：头部块、缩略图、线程记录、三作用域变量表与变长 blob 均已建模，两份样本计算总长与文件精确一致；**运行时读写后端未实装**：get_save_info$ 返回空串、save 系为记账 no-op |
| 表现层（图形/文本/声音） | 已实现（`majiro_stage/console/audio.gd` + `majiro_player` 入口场景）：Page 池与 alfa 伴生页、Sprite 链表层序与 push/pop 搁置、grp 像素操作（字节缓存）、FRONT 合成帧取景、fontout 记录文本、转场呈现、areaevent 输入、Console 文本烘焙（固定明朝系字体、阴影 alpha 配色模型）与点击门、SE/语音/BGM 声道池。开机→厂标→标题→四子屏/正文全程主机实测通过；细节与残留见规格 §12 |

## 文档

- `docs/majiro-format.md` —— 容器/脚本/图像/存档格式与 exe 行为规格（§§1–18）
- `docs/majiro-presentation-design.md` —— 表现层设计规格（宿主架构、Godot 映射、五期计划）
- `docs/majiro-syscalls.json` —— syscall 派发表（哈希 → 处理器地址 + 内联名单）

## 代码与测试

- 实现：`player/src/majiro/`（arc / mjo / insn / vm / host / rct / text / vfs / stage / console / audio），入口场景 `player/majiro_player.tscn`（放游戏目录路径为参数启动）
- 测试：`player/tests/test_majiro*.gd`（loaders / decode / corpus / text / vm / rct），
  均在 Godot 4.7.2 headless 下实测 PASS。运行方式（项目根目录）：
  `timeout 600 godot --headless -s res://tests/test_majiro_vm.gd`
  （Godot 的 `-s` 脚本编译失败时会空转，务必用 `timeout` 包裹并回读日志判定 PASS/FAIL）

## 说明

- ❌ 本仓库不包含任何游戏数据；使用者自备原版数据包
- 本分支的开发与测试在独立主机上进行（游戏数据不进 git、不经本机大流量传输）
- 逆向方法：社区工具（majiro-py / MajiroTools）逐项复核 + 原 exe 的
  REA/Ghidra 反编译 + 原版 Wine 实跑基线，三路证据交叉对账；
  结论在规格中逐项标注实测 / 文档 / 推断
