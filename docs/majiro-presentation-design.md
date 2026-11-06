# Majiro 表现层设计规格

状态：用户 2026-11-03 批准实现；期 1–4 主体与期 5 部分已落地（2026-11-04，见文末 §11 实现附记）。
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
- 构造器两个：FUN_00451470 = **24bpp BGR 色彩页**，FUN_004515f0
= 8bpp 索引页（共用分配器 FUN_004514b0，页本体即 GDI DIB
section）。page_create(w, h, [flag=1])：flag≠0 → 色彩页，否则
8bpp；w/h <1 报错并钳到 ≥1。
- 页结构（u32 下标，对象 0x38 B）：[0]=宽 [1]=高（绝对值）
[2]=行 stride（4 字节对齐：色彩页 ⌈(3w+3)/4⌉×4、8bpp 页
⌈(w+3)/4⌉×4）[3]=flag 上下文 **[4]=像素格式（0=24bpp BGR、
非 0=8bpp 索引，分配时定死）** [5]=has_alfa [6]=drawmode
[7]=alfa 页指针 [8]=BITMAPINFO [9]=调色板指针（仅 8bpp 页，
构造时初始化为灰度斜坡 i→(i,i,i,0)）[10]=像素 [11]=HBITMAP。
页另有全局链表（[0xC]=next、[0xD]=prev，表头 DAT_005afde8）。
初稿把 [4] 读作「锁定标志」是误读，现按格式标志更正：grp_copy
仅在「24bpp 源 → 8bpp 目标」组合报错、page_drawmode 对 8bpp
页报错，均为格式约束而非占用。
- page_create_withalfa：主图按 flag 建，主图 [5]=1，并新建一张 8bpp
页挂到 [7] 作 alfa 伴生页。
- page_create_file(name)：名经 FUN_0041fcb0 归一/校验扩展名后由
FUN_004203a0 经 VFS 加载解码；无法识别/缺失时**不报错**，返回
1×1 占位页（构造器由 FUN_00458d80 判定）。
- page_create_file_withalfa：加载主图后按「去扩展名 + 后缀常量」
拼伴生名（即格式规格 §12.1 的 `_.rc8` 掩码规则），伴生存在则
加载并置 [5]=1、[7]=伴生页。
- get_alfapage(x)：x 可为页或 sprite（sprite 先解其页），返回 [7]。
- page_drawmode(page, mode)：校验 + **8bpp 页（[4]≠0）报错**，
置 [6]=mode 并重建该页的呈现绑定（FUN_0044a3f0）。
- page_release(page)：校验句柄与占用（FUN_00449f20 须通过）后，
先释 alfa 伴生页、再释本页（FUN_00421340）。
- 屏幕页：FUN_0044f7d0() 返回全局前台缓冲页 DAT_005afd10；
脚本侧可用 get_frontbuffer（$3E11F2C5）取得同一页。
- grp_copy(src, x, y, xl, yl, dst, [dx=0, dy=0])：FUN_00451790 做
矩形裁剪（越界返回非零则整次跳过），FUN_00459350 执行拷贝；
**双方都有 alfa 页时连 alfa 通道一并同矩形拷贝**；最后重登记
dst 的呈现绑定（标脏）。
- grp_extcopy(src, x, y, xl, yl, dst, [dx, dy, [fade9]])：src 有
alfa 页走 FUN_00456b30（按 alfa 混合），无则 FUN_00459c60。
第 9 参 = **附加淡化量**（默认 0）：逐像素与源 alfa 相加作混合
权重（FUN_00460260 实测：有效权重 w=alfa+fade+1，目标权重 w、
源权重 256−w；w≥255 的像素跳过，参数本身 ≥255 时整次拷贝无
操作）。**alfa 字节极性：0=不透明、255=全透明**（sprite 合成
与 `_.rc8` 掩码转 RGBA 时 alpha=255−掩码字节）。目标有 alfa
页时同步乘算更新（dst_alfa=(src_alfa+1)×dst_alfa>>8）。
- grp_boxfill(page, x, y, w, h, color)；grp_extboxfill 多一个
transparency（1=不透明、256=无效）；grp_sepia /
grp_modcopy / grp_modify_copy / grp_mulcopy 等滤镜系按同一
矩形模型，细节在实现期逐个对调用点。

## 4. Sprite 模型

- sprite_create(page, [x, y, xl, yl, [page6]])：argc=1 时源矩形
= 整页；argc 5/6 时给源矩形（xl/yl 钳 ≥1），第 6 参为显式挂接的
第二页（校验为页），缺省 = 前台缓冲页（FUN_0044f7d0）。
构造 FUN_0044c0f0：对象 0x62C B，追加到全局 sprite 链表尾；
第 6 参页另进**引用计数的缩放缓存注册表**（节点 0x24 B，按页
去重，存降采样尺寸与缓冲，供缩放/旋转绘制取样）——Godot 侧以
Image 缩放缓存等价实现，接口不变。sprite 字段：[0]=页
[1/9]=源 x（基准/当前）[2/10]=源 y [3]=xl [4]=yl [5]=第 6 参页
[0xB]=当前 alfa [0xC]=层组号（初始 = 自身）[0xF9]/[0x141]=
x/y 缩放（初值 1.0f）。sprite_create_ext = sprite_create 后置
sprite[+0x3AC]=1（ext 标志，置位后源矩形/表面走 [0xEC..EF]
自有描述）。
- sprite_create_file(name$, [x, y, xl, yl]) / _ext：文件版同理。
- sprite_move(spr, x, y, [dur])：第 4 参 = **动画时长 ms**（缺省
0 = 即时）；动画状态存 [0x13/14]=起点、[0x15/16]=增量、
[0x11]=起始时刻、[0xF]=进行标志；处理器把参数拆存
[0x12]=v&0x84FFFFFF、[0x10]=v&0x78000000（高位为标志/曲线
保留区，本作任何调用点都不设置：menu 恒 100、yazlib/staffroll
为名为 $_time 的变量、transit 为逐项数组元素）。
sprite_get_pos_x/y、sprite_len_x/y（= 源矩形 xl/yl）、
sprite_get_page(spr)。
- sprite_release(spr)：摘链 + 脏矩形登记后销毁；sprite[8]≠0 时
连带释放其主页面与 alfa 页（FUN_0044c920）。[8] 的置位者 =
sprite_page_auto_release(spr)（0x8838FD56，FUN_0044CA10 汇编：
沿 sprite 链表找到该 sprite 后 `movl $1, 0x20(%ecx)`，即
[8]=1；2026-11-04 对账钉死）。全语料调用点仅 3 处（pic 1、
yazlib 2），均为 sprite_create 后立即对新 sprite 调用，与本
播放器实现（auto_rel 标志）一致。
- sprite_alfa_set(spr, alfa, [dur])：alfa 为**透明度**（0=不透
明、255=全透明，与 alfa 页极性一致）；第 3 参 = 淡变时长 ms，
缺省/0 即时置 [0xB]；非 0 起动画（[0xA3]=起始值、[0xA5]=
目标、[0xA6]=时长、[0xA0]=起始时刻、[0xA4]=2 动画类型、
[0x9F]=进行标志；FUN_0044d1e0 实测）。sprite_alfa_define 为
关键帧列（值/时长交替，argc 奇数 5..13），sprite_alfa_wait 等
动画结束；sprite_animate_define(spr, frm, spd,...) 为帧动画
（帧号/速度对列，argc 5..35）；sprite_animate_add 追加一帧；
sprite_xmodify/ymodify_define(spr, float%, ms,...) 为缩放关键帧
（浮点百分比 + 时长）；sprite_rotate(spr, deg[,...])。
- 层序（FUN_0044d550 / FUN_0044d330 实测）：**单一双向链表**
（[0x189]=next、[0x18A]=prev；表头 DAT_0059f7d0、表尾
DAT_0059f7cc），新建 sprite 追加表尾；绘制按表头→表尾画家序，
即**表头 = 最下层、表尾 = 最上层**。priority_high(spr) 把 spr
摘链重插至表尾（最上），priority_low(spr) 重插至表头（最下）；
带 ref 的 2 参形式插到 ref 相邻处并越过与 ref 同层组
（[0xC]）的连续段、且 spr 继承 ref 的层组号；_single 形式推定
为只紧邻 ref 插入、不越段（未单独反编译，按命名与 2 参实现
推断）。sprite_push/pop 保存/恢复层序栈；sprite_paste、
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
- console_font(name$, yl, xl, ystep, proportional)：处理器
（FUN_0041dd50）把名称与四个尺寸量格式化为描述符串、经
FUN_0041d320 查找/创建字体对象；默认字体名来自 fastdata.arc
的 sysdata.cfg（load_sysdata 读取）= **ＭＳ 明朝**（OS 字体名，
非包内资源），默认 yl=24、xl=12、ystep=35、proportional=0，
可经 $#confont_*@SYSTEM 持久覆盖。**本播放器的实现决策
（2026-10-29 用户拍板）：固定选一种明朝系系统字体，不做字体
名解析/映射；console_font 仅尺寸参数生效。** 汉化组的
Longinus 字体钩子是外挂，不进播放器。
console_color(a, b)、console_locate(_force)(x, y)、
console_curpos_x/y()、console_cls()、console_redraw(t)。
- console_on(a, b)：首次开启时以哈希回调脚本函数
$F7AC8CD8（console 库的开启入口，2 参透传），置开启标志；
console_off 对称。即消息窗的显隐动画等行为由 console.mjil
线程执行，引擎只维护文本域与历史缓冲（histbuff_*、
console_hist_pos/num_hist/prev/next/replay）。
> **修正（2026-11-06）：本条作废。** $F7AC8CD8 在脚本与 exe 中
> 均不存在；CONSOLE_ON/OFF/CLS/WROTE 是引擎内置事件，详见 §12.1。

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
drawmode, format}。原版色彩页为 24bpp BGR + 独立 alfa 伴生页，
Godot 侧色彩页以 FORMAT_RGBA8 承载（alpha 通道闲置或由伴生页
合成时写入），8bpp 页 = FORMAT_L8（alfa 页/灰度）。掩码转
alpha 时注意极性反转（见 §3）。page_create_file 走玩家 VFS +
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

## 10. 原「未决问题」的钉死结论（2026-10-30，REA 链 8/8b 全量实测）

初稿列出的未决项已逐项钉死，结论已并入 §3/§4/§5 正文，此处
只作索引：

- **grp_extcopy 第 9 参** = 附加淡化量（与源 alfa 相加作混合
权重，见 §3）；**页 [4]** 不是锁定标志，而是像素格式标志
（0=24bpp BGR、非 0=8bpp 索引，分配器 FUN_004514b0 定死，
见 §3）——初稿的锁定读法就此撤销。
- **sprite_move 第 4 参** = 动画时长 ms（高位标志区本作未用）；
**sprite_alfa_set 第 3 参** = 淡变时长 ms；alfa 极性为
0=不透明、255=全透明（见 §4）。
- **sprite 层序** = 单一双向链表，表头最下、表尾最上，画家序
合成到 frontbuffer（frontbuffer 是链表之下的底页，sprite 恒
在其上）；priority_high/low = 摘链重插至表尾/表头，2 参形式
带层组（[0xC]）语义（见 §4）。
- **console 字体** = OS 字体名（默认 ＭＳ 明朝，源自
sysdata.cfg）；本播放器固定选一种明朝系系统字体、只取尺寸
参数，Longinus 钩子不进播放器（见 §5，用户 2026-10-29 拍板）。
- sprite[8]（release 时连带释页的标志）的置位者已于
2026-11-04 对账钉死：sprite_page_auto_release（见前文
sprite_release 条），本节再无未钉到 handler 级的残项。
- movie_*（OP 动画 MPG）不在本设计范围，另行立项（不变）。

## 11. 实现附记（2026-11-04，实现期钉死/修正）

以下为实现期以 exe 汇编与主机对照实测钉死的语义，前文与此冲突处以本节为准：

- **实参引擎序**：函数调用与 syscall 的 arg0 = 最后压栈的值（exe 句柄自值栈顶向下读取；FUN_00420F80 page_create 汇编、yazlib 淡入 worker 的实参用途双证）。§3 的 page_create(w, h, flag) 等签名均按引擎序书写；实现时 VM 的 frame.args 与 syscall 分发都取反转序。脚本侧的压栈序是「先名义末参、后首参」的逆序，不要按压栈序读签名。
- **bsel.5（0x847）的真身是帧析构登记**：FUN_00413640 只把目标写入帧上下文 +0x24（mjil 标注 `@destructor`）。帧 ret 时先以该帧上下文执行析构、析构的 ret 才完成返回；thread_end 杀线程时先跑顶帧析构；点击跳过 = 宿主中断等待直跑析构；do_event_single("DO_TRANSITION") 只是阻塞至时长届满（或点击提前结束）后正常返回——不需要跳转模型。pic 等待环轮询的 $1635363c 实为 thread_begin 返回的 tid，工作线程的析构负责置 0。
- **等待族补正**：wait(≤0) 是帧同步等待（一帧）；另有 timer_sync(state, 间隔) → 新 state（0xFF75CD29，非 wait 变体）；timer（0x6584F13E）/get_current_time$ 返回引擎毫秒时钟。宿主等待键必须由重入的处理函数自有，tick 唤醒时不得删键（否则 wait 永久重装）。
- **areaevent**：areaevent_set 引擎序 (id, x, y, xl, yl, on, off, click, flags)；回调实参 = 区域自身的 (id, x, y, xl, yl)；分发由脚本循环调用 areaevent_check（0x3A3BFB29）完成；区域点击锁存独立于 mk_unwait。event_hook/event_hook_after 按名登记（实参序：名、函数哈希），do_event 以事件实参逐个 spawn 处理线程。
- **sprite_paste（0x4AB0CAEF）**：(dst_page, src_page)，按 sprite 的位置/alfa/掩码把显示 src_page 的 sprite 光栅化进 dst_page（FUN_0044C5E0 遍历 sprite 链表匹配页对）。
- **呈现残留**：page6=0 的 sprite（如标题图案背景）其呈现面（backbuffer/翻页）语义未明，暂未上屏；DO_TRANSITION 的效果码（负数、500 等）仅以淡入近似；grp 像素编辑走每页字节缓存（px cache），脚本逐行 extcopy 特效靠它才达到可用速度。

## 12. 实现附记二（2026-11-05/06，呈现层全量钉死；前文与本节冲突处以本节为准）

### 12.1 对 §5 / §11 的修正

- **§5 的「$F7AC8CD8 回调」不存在**：该哈希在全部脚本记录与 exe 中均无踪迹。引擎的真实模型是**引擎内置事件**：console_on/console_off syscall 触发 CONSOLE_ON / CONSOLE_OFF 事件，ctrl "w" 触发 CONSOLE_CLS，消息提交触发 CONSOLE_WROTE；脚本侧以 event_hook / event_hook_after 按名订阅（$$main@CONSOLE 登记的即这批）。console_on 本体（FUN_0041DE90）只维护引擎状态。
- **§11 的 sprite_paste 签名作废**：真签名是 **sprite_paste(sprite, page)**（FUN_0044C5E0 按精灵表/页表分别校验两参）。旧实现按 (dst, src) 解读时静默全灭，是标题屏黑屏的主因之一。
- **§11「page6=0 图案背景未上屏」销项**：标题图案/LOGO 的呈现面就是 FRONT 合成帧（见 12.4），菜单态截图实测干净（白晕亦销项：所谓白晕是 alfa 伴随页未挂时的误读）。

### 12.2 VM / 调度

- **spawn_function 实参序**：宿主 spawn（event/hook/button 回调）收到的是源码序参数，须在内部反转为 thread_begin 的栈序；早期未反转使 button_menu 恒返回 30（超时值），菜单四项从未真正选中（两份「已验证」报告已撤回）。
- **$exec（0x718EF651）/ $call（0xCD00D280）**按 FUN_0040ff60 / FUN_0040fc30 实装；$exec 转移后由 VM 派发 **HOT_RESET(0, "", 0)**（exe 内置事件，无脚本 fire 点），console 的 hot_reset 分支据此重读 sysdata.cfg 并复位 fc/dc/kmk。
- **load_library 首次加载即启动库 main**：在库 entrypoint 追加线程（17 个 LIBMAIN 实测）；只加载不开 main 是整批子系统（console/pic/config…）从未初始化的根因。
- **get_variable / set_variable / curpos_x / curpos_y**：变量名哈希 = **明文 CRC-32**（zlib 同款；以 "#musicvol@CONFIG" 0x5731EA89 等三例对齐）。get/set 经 VM 派发核心处理（栈序：名在末、set 的值在首）；'#' 名走 persistent 合成存储，其余走 savefile 存储，已存在单元优先于 sigil 判定。curpos 返回 Stage 追踪的鼠标坐标。此四者原为桩时，config 的逐项滑杆 worker（$026db55c）全部空转。
- **未知 syscall 收敛**：全流程实测仅剩 reg_read（0x80177286）、show_mouse_cursor（0xAB13BE44）、$c438ba98（0xC438BA98，FUN_0042A050 钉死为引擎记账：锁存/清零/指针交换，无呈现语义，桩正当）。save 系（save_enable / save_menu_enable / save_point / save_menu_disable 0x44B5C4ED）为记账 no-op；reg_write（0x9A1ACECA）no-op。**存档读取已实装**（2026-11-06，见 12.7）：启动时恢复 majiro_system.mss 的 PERSISTENT 作用域，get_save_info$（0x65075141）/ get_save_time$（0xA549E852）读真实 .sav 文件头/时间；写入与 do_load 状态恢复仍未实装。

### 12.3 Console / 文本

- **cfg 字段读取器**：字段以逗号/换行定界，`//` 注释到行尾，**字段内空格保留**（「ＭＳ 明朝」是一个字段），空字段跳过。旧实现按空白切分使全部 console 几何量错位轮转。config.cfg 以同一读取器离线模拟与运行时令牌流逐一对齐（567 令牌）。
- **CONSOLE_WROTE 按行带真实参数**：原生在每行字形落页**之后**才发事件，参数 = (con_draw 页, x, y_中心 = pos.y + yl/2, 行宽 px, yl, zerotime=0)；实现改为 bake 作业携带参数、落页后触发。事件泵顺序化：泵在 ctrl "w" 遇未排空的 bake 队列时停驻，避免旧字形盖新窗。
- **bake 字体/配色在 console_set 时刻捕获**；**阴影 alpha 来自 console_color 第二参的顶字节**（kmk；hot_reset 置 1 → 约 0.4%，几不可见）。早期实现丢弃顶字节、全强度黑影把白字压成暗团——一度误报为「原生深色字」，已撤回。原生正文 = 白字 + 极淡影。
- **get_mojispeed**：先读 set 值，非零用之；否则读 config 持久值 $ddf4e4e2（实测 1837）；再否则 50。timer_progress 源序 = (start_tick, duration_ms, max)。
- **文字门闩与探针脚手架的教训**：`--hold-text` 类「按住文本」的调试开关若其释放路径依赖被测事件本身，会把流程永久钉在第一处等待并伪装成引擎停顿（曾误判「69 条齐停」）。产品代码无此类开关。

### 12.4 Page / Sprite / 合成

- **FRONT 是合成帧**：原生 frontbuffer 是软件合成结果（含精灵）。子屏（config/loadsave）以 grp_copy 自 FRONT 取景作底图；实现中 FRONT 页平时只有直绘内容，故 _blit_pair/_extcopy_pair 以 FRONT 为源时先由 Stage 抓 SubViewport 纹理回填 FRONT 页（_refresh_front）。
- **sprite_push / sprite_pop 是精灵表搁置**：push 把当前精灵表整体藏起（子屏期间不显示）、新表从空开始；pop 丢弃子屏表、按搁置时的可见性恢复原表。仅 config/loadsave 使用。旧实现只存不用，Load 面板精灵被压在标题精灵之下永不见光。
- **pic_unpack 分流**：解码图 ≥ 页 → 整页替换（章节背景；1280×960 原画以 0.8 全幅压入 1024×768、左上对齐，与 Wine 基线三地标 NCC 0.978–0.998 一致）；解码图 < 页 → **贴印**：按 (x, y) 偏移、经其 `_.rc8` alfa 伴随（极性 255=全透明）blend onto 页（loadsave 的 52×53 印章即此，脚本偏移 (138,76)）。旧实现的无条件整页替换曾把画完的 Load 面板连 20 行字一并抹掉。
- **page_set_antidata（0xF9705332）**实装（color 页挂 alfa 伴随页）；grp_copy 的 9999 宽高是「整页」哨兵，由裁剪收敛。
- **grp_copy / grp_extcopy 的 6 参短形式**：脚本常只给 (src, sx, sy, w, h, dst)，原生默认 **dx=sx、dy=sy**（FUN_00422310 实证：argc≤6 时 dst_x 取 sx 槽、≤7 时 dst_y 取 sy 槽）。早期实现默认 (0,0)，使 omake 屏 wipe 的 42 条 12×768 条带全叠在 x=0——两牌左缘同为背景花纹，画面逐字节不变，一度误判「Extra 选后无反应」。
- **章节取景定案**：背景原画全幅 0.8 squash、左上对齐，与原版一致（旧目测位移说撤回）。

### 12.5 fontout 家族与 grp_mulboxfill（REA 反编译钉死）

- 四个 setter 惰性创建**每线程共享的 fontout 上下文**（0x6C B，模板在 exe 0x4A7258）：locate(page,x,y) 置 ctx 页/笔；color(main, sub=-1)；font(name$, h=20, w=h/2, step=⌊h×5/4⌋, extra=0)，名字含「明朝」（CP932 字节）置 Mincho 标志；push/pop 链式存取上下文。
- **fontout 本体**：无 box 时在笔位绘、返回行宽、笔 x += 行宽；带 (box_w, box_h[, align]) 时 align −2 右 / −1 左 / 其它 居中，y 临时居中、绘后恢复。渲染器 = GDI TextOutA 逐字缓存；**Mincho 合成粗体** = 同字 x+1 再绘一次；sub 色低 24 位为影/边色、顶字节（&0x7F）为模式：0 = 单影（偏移 max(1,h/9), max(1,h/18)），1 = 八邻描边（δ=max(1,h/18)）；sub=−1 无影。w/step/extra 不被渲染器消费（推进量纯量宽）。
- **UI 记录字符串固定 cp932 解码**：config/loadsave/message_box 三库不在汉化补丁内（补丁只有 scenario + 少量 .rct），其 fontout 文本是日文原文。
- **grp_mulboxfill（0x61BAE53C）**：(page, x, y, w, h, color)，仅 24bpp 页；逐像素 ch := ch × (m+1) >> 8（COLORREF 序）。

### 12.6 子屏终验（2026-11-06，全部截图实证）

- 标题菜单四去向全验：New Game → 章节链（STA000 245+ 条文本、背景链 sky01/EA01 上屏）；**Continue/Load 上屏**（Load File's 台账 20 行 + 页签 + 印章 + Back）；**Option/Config 上屏**（環境設定全条目、滑杆、文字速度 1837；push/pop 修正后回归无恙）；**Exit 完整框**（模态变暗 + 问题文 + はい/いいえ）。
- 标题菜单 30 秒超时（sel=7 → attract/demo）未验；Wine 原版 Config/Load 基线截图未取到（原版进程在对照机上反复退出/窗口漂移），两屏按脚本 + 牌图 + cfg 数据对齐，未做原版像素对照。
- **Extra / omake 中枢已验**（2026-11-06）：以真实通关档（majiro_system.mss 中 $c88dfb04=1）启动，标题出现第 5 项 Extra（buttonmenu_set 面积 4@374,623 实测），选中返回 4；中枢屏（start.mjil block_01f8b 在标题函数内自建）经 wipe 条带动画呈现（短形式默认偏移修正后），四子项可选；子项 1 派发 $$cg_mode@CGMODE，cgmode.cfg 读入、画廊建成并停在其点击等待循环（cgmode:0x3614 的 areaevent_check + wait(2)，退出标志由面积回调写 $2619c6dd）——中枢本体闭环。画廊**内部**呈现残留见 12.7。

### 12.7 残留

- **期5 转场（脚本派发）已实装并实测**（2026-11-06）：do_event_single 按 pic/transit 的 mjil 语义实装——以事件名定位参数串、payload 派发给全部钩子 worker，调用线程 join 等待全体 worker 结束，点击则杀 worker 并跳调用方析构。章节链实测 21 次转场真派发（claim 锁 $$trans_notice@PIC 只响一次 dialog_error_ok 桩）。曾报「errors 314 vs 基线 103」经频率表定案：**全部是 argcheck 标注噪声**，其中 210 条 = 21 次转场 × 10 个声明 4 参却收 6 参 payload 的钩子函数（游戏数据自带，引擎自身亦如此派发），非缺陷。DO_TOP_TRANSITION 走同一路径但活体未验；transit_top worker 的 page6 目标页语义未普查。
- **make_alfa_table（0x3CAD3884）已实装**（exe FUN_00423520 + FUN_00459f60）：两页须 8bpp、数组 ≥256 项钳制建表，dst[i] = table[src[i]]（R 通道即索引字节）；transit 的渐变 worker 据此逐帧重映射 alfa 页。
- **存档读取已实装**（2026-11-06，格式见 majiro-format §§16/17/19）：VM `load_persistents` 在 boot 前恢复 system.mss 的 PERSISTENT 作用域（标量进合成存储、数组按 §16.2 blob 对象解码进单元存储）；播放器在 game_dir/savedata/ 存在 majiro_system.mss 时自动载入。Extra 解锁门 $c88dfb04 即经此生效（真实通关档实测标题多出 Extra 项）。get_save_info$ / get_save_time$ 读真实 .sav（文件名规则与 §16 同：last/%04d/quick）；Load 屏第 2 页签的真实标题行尚未探针验证（存档 0101/0102 应在该页签）。**存档写入与 do_load 线程状态恢复仍未实装**；readmark 既読存储未实装（§13 格式已钉死）；copy_thumbnail（0x78A6A112，FUN_00429180 语义已反编译）未实装——真实档缩略图均为 1×1 占位，无视觉价值，优先级低。
- **画廊（CG Room）内部呈现未落定**：中枢子项 1 派发后画廊逻辑建成并等待点击，但前台停在进画廊前的变暗标题底图、画廊底板未合成。已定位的线索：cgmode 的 cfg 指令流解释中有 pic_unpack 收到空名（值 0）失败两例（页 65664/65665 无图）；另有 cgmode 专用 syscall **0x99a5de25** 未实装——exe FUN_00429f30 钉死为**资源存在性查询**（去扩展名 → 名哈希 → 查 exe 内置表 → 1/0），现桩返回 0 可能使画廊条目被整体跳过。其余三间 Room（回想 / 音乐 / ED）未探。
- attract 模式（菜单超时 sel=7）未验；标题菜单 30 秒超时默认回标题的呈现未验。
