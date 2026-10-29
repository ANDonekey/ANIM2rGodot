# ANIM2rGodot — `engine/majiro` 分支

ANIM2rGodot 的**第二引擎分支**：为 **Majiro** 引擎从零实现的
**Godot 播放器**——把原版游戏的数据包放进来就能直接游玩，解释器
模式，不做逐部游戏的转换移植（思路同 ONScripter 之于 NScripter）。

- `main` 分支 = ANIM.teamMM 引擎播放器（见 main 分支的 README）
- 本分支 = Majiro 引擎播放器；每引擎一条分支，核心层各自独立

样本游戏：**《STARLESS》**（Empress，2011；yichengong 汉化版）。
生态普查结论：此前不存在任何 Majiro 运行时/播放器实现，只有
反汇编、翻译与资源提取工具——本分支是第一个运行时重实现。

## 现状（2026-10-30）

**核心层已完成并全量实测；表现层设计规格已钉死，待批准后按
五期实现**（静态画面 → 文本 → 交互 → 声音 → 动画与转场）。

| 模块 | 状态 |
| --- | --- |
| MajiroArcV3 容器 | 已钉死：16 B 头 + 条目表 + CP932 名表；名哈希 = Majiro 的「坏 CRC-64」（反向实现误用正向多项式），样本 252/252 验证；GDScript 读取器实测通过 |
| .mjo 脚本（MajiroObjX1.000） | 头/函数表/crypt32 解密已钉死（头 +0x14 = 文本行数，readmark 227 条逐条对账）；477 个脚本（250 日文 + 227 汉化重编译）全量普查：896,634 条指令、text 101,892 |
| 指令解码器 | 操作码表自 majiro-py 注册表导出；与参考反汇编逐条对账，全语料扫描 896,634 条零失步 |
| VM 核心 | 真实启动流跑通：加载 start → $init@GLOBAL → $$main，300,068 步、调用深 9、**未处理操作码/syscall 归零、0 致命**，终点为标题菜单等待环（表现层未接入时的预期行为）；br.case / bsel / switch 语义已 REA 钉死并实现 |
| syscall 宿主层（MajiroHost） | 派发器全表已提取：456 个处理器 + 27 内联（`docs/majiro-syscalls.json`），语料 289 个名哈希全覆盖；文件族（CP932 文本逐 token 扫描）、dim_create、字符串/数学工具族为真实实现；表现系 syscall 先记账桩，待表现层接入 |
| 文本层 | CP932 / GBK 编解码表（gzip+b64 存仓，生成器 `generate_tables.py`），24 条真值串全对 |
| .rct / .rc8 图像 | 解码规格钉死：20 B 头 + LZ77 指令流；rct = 24bpp BGR、rc8 = 8bpp 调色板；TC01 带底图名、纯红透明递归合成；绝大多数 `.rc8` 是同名 `.rct` 的 alpha 掩码（`_.rc8` 规则）；GDScript 解码与 Python 参考实现 md5 对账 24 张全同 |
| 存档格式 | `.sav` / `system.mss` / `readmark.mss` 全解：头部块、缩略图、线程记录、三作用域变量表与变长 blob 均已建模，两份样本计算总长与文件精确一致 |
| 表现层（图形/文本/声音） | 设计规格完成（`docs/majiro-presentation-design.md`）：Page/Sprite/Console/声音的引擎模型均由 REA 反编译钉死——含页像素格式标志、grp_extcopy 附加淡化量、alfa 极性（0=不透明、255=全透明）、sprite 层序链表与动画时长参数；§10 未决项已全部钉死（2026-10-30）。实现待启动 |

## 文档

- `docs/majiro-format.md` —— 容器/脚本/图像/存档格式与 exe 行为规格（§§1–17）
- `docs/majiro-presentation-design.md` —— 表现层设计规格（宿主架构、Godot 映射、五期计划）
- `docs/majiro-syscalls.json` —— syscall 派发表（哈希 → 处理器地址 + 内联名单）

## 代码与测试

- 实现：`player/src/majiro/`（arc / mjo / insn / vm / host / rct / text）
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
