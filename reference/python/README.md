# Python 参考实现

逆向阶段的成果代码，是格式规格的「可执行形态」。Godot 移植时以这些实现为
对照基准：同一输入文件，解析/评估结果须一致。

| 文件 | 内容 |
| --- | --- |
| `anim_gsecret.py` | GSecret 解密（逐字节参考版） |
| `gsecret_fast.py` | GSecret 解密（块级快速版） |
| `sce_token.py` / `sce_parse.py` | sce 字节码分词与全量解析（50,561 条记录平铺验证） |
| `sce_disasm.py` / `sce_export.py` | 反汇编与对白导出 |
| `unpack_kabe2.py` | 样本数据包全量解包（可续跑；problems=0） |
| `psb_parse.py` | PSB v3 解析（头部解密、名字 trie、对象树） |
| `psb_export_all.py` | PSB 批量导出（纹理页 + 部件切片） |
| `define_extract.py` | define.dat 的 em 姿势表提取 |
| `emote_render.py` | E-mote 静态帧评估器（图层合成核心语义，已目视验证多姿势） |
| `emote_anim.py` | 预渲染动画管线（旧路线产物，播放器路线下仅作评估器行为参照） |
| `legacy-renpy/` | 已弃用的 Ren'Py 逐游戏转换路线：转换器、预渲染批量、场景演示生成器 |

注意：这些脚本中的路径与样本名针对逆向时的本地实验目录，作规格阅读即可，
不保证开箱运行。
