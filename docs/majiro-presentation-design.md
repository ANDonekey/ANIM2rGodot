# Majiro 表现层设计规格

状态：调研完成，待批准后实现。
证据标注：= 本项目在 STARLESS 语料/exe 上验证；= 社区资料
（MajiroTools wiki），与实测冲突时以实测为准。

## 1. 总体架构

- UI 逻辑全在脚本层：`pic.mjil`（63 函数）包办画面操作与转场；
`console.mjil` 是单个巨型函数，用 sprite + grp_boxfill +
sprite_animate 自己拼出消息窗与历史界面；menu / buttonmenu /
message_box / cgmode / config / loadsave 等库都用同一套原语
（sprite_create/move/alfa_define + areaevent_set 热区）。
- 引擎只需提供原语：page（离屏图）、sprite（定位图层）、grp_*（页间
绘制）、console_*（文本状态）、areaevent（鼠标热区回调）、声音四系
（sound/sound2/3/4、voice、music）、等待/输入（mk_wait/wait/draw_wait）。
- 每行 text 前调用的 `$e1751505`（99,005 次）是 pic 库的行前钩子。
- syscall 参数在栈上自顶向下为 arg1..argN（编译器逆序压栈）。

## 2. 调用面普查

表现层占 26,727 处。高频核心（名称 次数 argc 变体）：
sound 10258 [1,2]、sound4 2640、sound2 1543、sound3 595（四通道系，
各有 _vol/_fadeout/_stop/_wait/_is_loop）；sprite_move 416 [3,4]、
grp_copy 179 [6,8]、sprite_release 174、page_release 141、
areaevent_set 138 [8,9]、sprite_alfa_set 112 [2,3]、grp_boxfill 110 [6]、
sprite_create 84 [1,5,6]、page_create 80 [2,3]、sprite_alfa_define 69
[5..13]、pic_unpack 49 [2,3,4]、sprite_animate_define 39 [5..35]、
wait 845 [1]、client_width/height 243/222、console_on/off 各约 20-40、
invalidate_enable/disable 各 33、grp_extcopy 28 [8,9]。

## 3. Page 模型

- 句柄 = 引擎对象指针，以整数形式交给脚本。校验函数 FUN_004516d0
（非页返回非零，处理器报错并返回 0，不致命）。
- 构造器两个：FUN_00451470 = 32bpp 页，FUN_004515f0 = 8bpp 页。
page_create(w, h, [flag=1])：flag≠0 → 32bpp，否则 8bpp；w/h <1
报错并钳到 ≥1。
- 页结构（u32 下标）：[0]=宽 [1]=高 [4]=占用/锁定标志（锁定页作
grp 目标或改 drawmode 会报错）[5]=has_alfa [6]=drawmode
[7]=alfa 页指针。
- page_create_withalfa：主图按 flag 建，主图 [5]=1，并新建一张 8bpp
页挂到 [7] 作 alfa 伴生页。
- page_create_file(name)：名经 FUN_0041fcb0 归一/校验扩展名后由
FUN_004203a0 经 VFS 加载解码；无法识别/缺失时**不报错**，返回
1×1 占位页（构造器由 FUN_00458d80 判定）。
- page_create_file_withalfa：加载主图后按「去扩展名 + 后缀常量」
拼伴生名（即格式规格 §12.1 的 `_.rc8` 掩码规则），伴生存在则
加载并置 [5]=1、[7]=伴生页。
- get_alfapage(x)：x 可为页或 sprite（sprite 先解其页），返回 [7]。
- page_drawmode(page, mode)：校验 + 未锁定才生效，置 [6]=mode 并
重建该页的呈现绑定（FUN_0044a3f0）。
- 屏幕页：内部默认页由 FUN_0044f7d0() 给出；脚本侧可用
get_frontbuffer（$3E11F2C5）取得。
- grp_copy(src, x, y, xl, yl, dst, [dx=0, dy=0])：FUN_00451790 做
矩形裁剪（越界返回非零则整次跳过），FUN_00459350 执行拷贝；
**双方都有 alfa 页时连 alfa 通道一并同矩形拷贝**；最后重登记
dst 的呈现绑定（标脏）。
- grp_extcopy(src, x, y, xl, yl, dst, [dx, dy, [mode9]])：src 有
alfa 页走 FUN_00456b30（按 alfa 混合），无则 FUN_00459c60
（普通拷贝）；第 9 参为附加模式量（默认 0，语义待实现期细究）。
- grp_boxfill(page, x, y, w, h, color)；grp_extboxfill 多一个
transparency（1=不透明、256=无效）；grp_sepia /
grp_modcopy / grp_modify_copy / grp_mulcopy 等滤镜系按同一
矩形模型，细节在实现期逐个对调用点。

## 4. Sprite 模型

- sprite_create(page, [x, y, xl, yl, [alfa_page]])：argc=1 时源矩形
= 整页；argc 5/6 时给源矩形（xl/yl 钳 ≥1），第 6 参为显式挂接的
第二页（校验为页），缺省时用 FUN_0044f7d0() 的默认页。
构造 FUN_0044c0f0。sprite_create_ext = sprite_create 后置
sprite[+0x3AC]=1（ext 标志）。
- sprite_create_file(name$, [x, y, xl, yl]) / _ext：文件版同理。
- sprite_move(spr, x, y[,?])、sprite_get_pos_x/y、sprite_len_x/y
（= 源矩形 xl/yl）、sprite_get_page(spr)。
- sprite_alfa_set(spr, alfa[,?]) 即时值；sprite_alfa_define 为
关键帧列（值/时长交替，argc 奇数 5..13），sprite_alfa_wait 等
动画结束；sprite_animate_define(spr, frm, spd,...) 为帧动画
（帧号/速度对列，argc 5..35）；sprite_animate_add 追加一帧；
sprite_xmodify/ymodify_define(spr, float%, ms,...) 为缩放关键帧
（浮点百分比 + 时长）；sprite_rotate(spr, deg[,...])。
- 层序：sprite_priority_high/low(spr[, ref])、_single(a, b) 调整
合成顺序；sprite_push/pop 保存/恢复层序栈；sprite_paste、
sprite_page_auto_release、sprite_clip 为辅助。
- 合成时机：引擎主循环按层序把 sprite 合成到 frontbuffer；
invalidate_enable/disable 门控自动刷新，draw_wait 等待一次呈现。

## 5. Console / 文本模型

- text 操作码（FUN_0041e800）**不是渲染器，是累加器**：把操作数
字符串追加进线程的待显缓冲（池内 16 槽 × 0x404 B，槽间拼接，
上限 0x400 B）。proc/ctrl 操作码是冲刷点（呈现 + 语音/等待的
衔接在 FUN_0041e930 / FUN_0041f780，启动流阶段已反编译）。
- console_set(page, x, y, xl, yl)：置全局文本域 {page, x, y,
cur_x=x, cur_y=y, xl, yl}；page 非页时报错并回退默认页。
旧签名记作 (int, x, y, xl, yl)，首参实为页句柄。
- console_font(name$, yl, xl, ystep, proportional)、
console_color(a, b)、console_locate(_force)(x, y)、
console_curpos_x/y()、console_cls()、console_redraw(t)。
- console_on(a, b)：首次开启时以哈希回调脚本函数
$F7AC8CD8（console 库的开启入口，2 参透传），置开启标志；
console_off 对称。即消息窗的显隐动画等行为由 console.mjil
线程执行，引擎只维护文本域与历史缓冲（histbuff_*、
console_hist_pos/num_hist/prev/next/replay）。

## 6. 输入 / 热区模型

- areaevent_set(id, x, y, xl, yl, $on, $off, $click, [flags9])：
分配 0x34 B 记录 {id, x, y, xl, yl, on, off, click, 状态=0,
鼠标对象, flags, 0, next}，挂到鼠标模块（DAT_005b46a8）的
链表尾。回调是脚本函数哈希。
- areaevent_setdefault($lclick, $rclick, $mclick, $mroll) 设全局
默认回调；areaevent_reset() 清表；areaevent_offs 偏移全体。
- areaevent_check（FUN_0043b6b0，派发器头案）：引擎每帧按鼠标
位置/按键遍历链表，命中变化时以脚本调用机制（$CD00D280 系）
起回调线程：移入触发 $on、移出 $off、点击 $click。
- mk_wait() 返回按键/点击位掩码（派发器内联，见格式规格 §10）；
mk_unwait 清等待态；mk_read/mk_stat 查状态。bsel（§15）是脚本
帧内的按钮目标登记，与 areaevent 是两套机制（bsel 用于 VM
内同步选择，areaevent 用于异步 UI 回调）。

## 7. 声音模型

- 四条 SE 通道以名字区分：sound / sound2 / sound3 / sound4
(name$, [flags])，各带 _vol/_fadeout(ms)/_stop/_wait/_is_loop/
_get_fn$；sound_ch(ch,...) 是可编程通道版（loadsave/config 库用）。
- voice(name$) 单语音通道 + voice_ch(ch,...) 多通道版，各带
_vol/_pan/_fade/_wait/_stat/_get_fn$；voice_setup /
voice_text_setup / voice_musicdown_vol 为语音与 BGM 的联动。
- music(name$, [flags]) BGM：_fade/_fadeout/_vol/_stop/_pause/
_resume/_stat/_wait + _push/_pop/_replace（栈式 BGM 管理）。
- 资源为原生 OGG（voice.arc 15,540 条），Godot 原生可播。

## 8. Godot 映射（设计提案）

宿主新增 MajiroStage（与 MajiroHost 并列，attach 到 VM 的
syscalls 表），内部模型与引擎同构：

- **Page 池**：id → {image: Image（RGBA8 或 L8), alfa: PageId,
drawmode, locked}。32bpp 页 = FORMAT_RGBA8，8bpp 页 =
FORMAT_L8（alfa 页/灰度）。page_create_file 走玩家 VFS +
MajiroRct 解码（含 TC01 底图合成与 `_.rc8` 掩码挂接）。
- **呈现**：Stage 根为 1024×768 的 CanvasLayer；每 sprite 一个
TextureRect/Sprite2D（纹理 = 页 Image 的 ImageTexture，
region = 源矩形），z_index 对应 priority 链；grp_* 直接改
Image 像素（blit_rect / fill_rect / 自写混合），改完标脏，
帧末统一 texture.update。frontbuffer = 一张专用页 + 全屏
TextureRect 兜底（脚本直接 grp_copy 到 frontbuffer 的情形）。
- **Console**：MajiroConsole 状态机持有 {page, rect, font, color,
cur} 与历史环；text 累加由 VM trace 喂入，proc/ctrl 冲刷时
逐字呈现（mojispeed/auto/fast 模式读引擎配置变量）；呈现载体
为 Label 池绘制到 console 页 Image（与脚本自绘的消息窗 sprite
并存，互不干扰：脚本窗是普通 sprite，文字画在 console 页上）。
- **输入**：Stage 用 Control 捕获鼠标；areaevent 链表在宿主侧
维护，每帧（或事件驱动）做命中判定，回调经 VM 的
script-call 通道起线程（复用 thread_begin 机制）；mk_wait 的
挂起复用 VM 的 wait 模型（pc-=8 重执行），位掩码语义照 §10。
- **声音**：AudioStreamPlayer 池：SE 4 通道 + sound_ch 可变
通道、voice 1+ch 通道、music 1 通道（push/pop 在宿主侧存
流名栈）；fade 用 Tween/音量包络；_wait 类 syscall 以
播放状态轮询 + VM 挂起实现。
- **动画**：sprite 的 alfa/animate/xmodify 关键帧由 Stage 的
tick(dt) 推进（与 VM 线程调度同帧），_wait 系挂起至动画结束。
- VFS 搜索顺序沿用格式规格 §11（loose → update 族 → fastdata →
scenario → data 族），MajiroHost.read_file 已有基础，Stage
共用同一 VFS 对象（本次实现时把 VFS 从测试里提炼为正式类）。

## 9. 分期（每期主机实测 + 与原版基线截图对账）

1. **静态画面**：Page 池 + grp_copy/boxfill + sprite 静态合成 +
page_create_file(_withalfa) → 标题画面渲染与原版对账。
2. **文本**：Console 状态机 + text/proc/ctrl 呈现 → 开场引文卡 +
首场景对白可读（含逐字、等待点击）。
3. **交互**：areaevent + mk_wait 真挂起 + bsel 输入注入 → 标题
菜单可点、选项可走。
4. **声音**：sound/voice/music 全系 → BGM/SE/语音与画面同步。
5. **动画与转场**：alfa/animate/xmodify 关键帧 + transit 库自洽
→ 淡入淡出/立绘动画与原版对账。

## 10. 未决问题（实现期逐项钉，不阻塞设计批准）

- grp_extcopy 第 9 参的精确语义；grp_copy 中页 [4] 锁定标志的
置位/清除者（疑为 sprite 引用计数或呈现占用）。
- sprite_move 第 4 参、sprite_alfa_set 第 3 参的可选参语义。
- sprite 层序的精确数据结构（priority_high/low 的相对语义）与
frontbuffer 的合成次序（sprite 在 frontbuffer 页内容之上/之下）。
- console 呈现的字体来源：console_font 的 name$ 在包内对应何种
字体资源（Longinus 钩子替换字体的关系），Godot 侧用系统字体
还是包内字库需在第 2 期前钉死。
- movie_*（OP 动画 MPG）不在本设计范围，另行立项。
