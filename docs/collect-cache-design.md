# collect() 缓存设计（待评审，未实现）

状态：已按第 0 步剖面结论执行方案 B（见文末「执行记录」）；方案 A 保留为后续选项。

## 事实基础（2026-10-29 实测，wasm autoplay 180s）

- 节点复用（#1）落地后，渲染总耗时里 **collect() 占 78%**（40.7s / 52.1s），
  单次 collect 在 wasm 上约 250~400ms（双人场景更贵）。桌面约快一个数量级，
  所以这是 Web 专属瓶颈。
- 驱动动画（口型分档后仍有眨眼、物理弹簧、ParamSet 过渡）期间签名持续变化，
  每次变化都触发一次全量 collect；自适应合并已把频率压到成本自适应，
  但单次成本没降。
- 静态占比推断：说话时真正变化的只有脸（口/眼）和物理层（头发/胸等弹簧层），
  身体其余子树在同一姿势下逐帧不变——全量重算是浪费的大头。

## collect 的结构（emote_model.gd）

`collect(chara, motion, raw_vars, layer_offsets)`：
1. `effective_vars(raw_vars)`：变量展开（selector 等派生变量）。
2. `_travel(...)`：递归走 motion 树，按变量选帧、逐层合成 Ctx（矩阵/不透明度/
   可见性/clip 栈），叶子产出 part 字典（绝对 grid、rect、opa、z），
   同时把 stencil 源几何**注册进 Inst.registry**（副作用！），
   并给每个几何分配全局递增 `_gid`。
3. z 稳定排序；`_resolve_clips(out)`：按 registry 把 clip 几何挂到 part 上。

## 候选方案

### A. 子树缓存（收益最大、风险最高）

以 `_travel` 的节点为单位缓存：指纹 = 节点身份（树内路径）+ 进入时的 Ctx
（矩阵 6 元、不透明度、可见性、clip 栈身份）+ **该子树求值期间实际读到的
变量值集合**。命中时回放缓存的 part 列表（深拷贝或引用不可变约定），
并把缓存时记录的 registry 贡献回放到当前 Inst。

三个必须解决的难点：
1. **变量读集追踪**：变量读取散落在 `_travel/_axis_time/_ambient_time/
   selector 展开` 等处。需把 `vars_.get(...)` 收口到一个带日志的访问函数，
   按子树分段记录读集；`effective_vars` 的派生变量要在展开后层面记录，
   否则 selector 改而原始变量未改会误命中。
2. **_gid 重映射**：缓存几何的 `_gid` 是旧一轮的全局计数；`_resolve_clips`
   只用它做「是否同一几何」的相等判断。回放时须把该子树的 gid 整体平移到
   本轮的保留区间（例如按子树分配独立高位段），保证轮内唯一、且与
   part 自身 gid 的比较语义不变。
3. **clip 栈与 Inst 身份**：part 的 `_clip_pending` 引用求值当轮的 Inst
   对象；回放的 part 必须改挂当前轮的 Inst，且其 labels 在当前 Inst 的
   registry 里能查到（靠难点 2 的回放保证）。

验证策略：缓存开关并存，用测试套件对同一批 (chara, motion, vars) 序列
跑「无缓存 vs 有缓存」collect 输出逐项深比较（含 clip/gid 语义等价比较），
全等才默认开启；再跑 autoplay 统计一致性。

### B. grid 复用（收益中等、风险低）

`_grid_for` 是 travel 里最重的算术（每 part (n+1)² 点矩阵合成）。
part 的 grid 只取决于（图标尺寸、ox/oy、合成矩阵、warp 参数）；同一 part
在 Ctx 未变时 grid 逐点相同。可在 part 产出处按
（source 身份 + 矩阵量化 + offsets 量化）缓存 grid 数组。
不碰 registry/gid/clip 语义。缺点：帧选择、Ctx 合成、字典构造等其余开销
仍在，收益上限取决于 grid 占 travel 的比例——**需先剖面**（见第 0 步）。

### C. 不做（接受现状）

自适应合并 + 现有缓存下，wasm 帧率在重场景约 3~7fps。剧情推进、音频、
UI 都不受阻（渲染在主线程但被合并间隔钳制），只是过渡动画帧率低。
可接受但谈不上流畅。

## 第 0 步（任何方案之前）

给 collect 内部加分项探针：travel 总时、其中 _grid_for 累计时、
_resolve_clips 与排序耗时、part 产出数量。据此在 A/B 间定量选择：
- _grid_for 占比 > 50% → 先 B（小改动拿走大半收益），A 视残余再议；
- 占比低、开销均匀分布在遍历本身 → 只有 A 能解，按 A 的验证策略推进。

## 建议

先做第 0 步剖面（半天内可完成、零行为风险），数据出来后再定 A/B。

## 执行记录（2026-10-29）

第 0 步剖面（wasm autoplay 180s）：collect 27.9s 中 travel 占 99.8%，
其中 _grid_for 21.2s（76%）、49,055 次调用 / 7,028 个产出 part；
排序与 clip 解析各仅 32ms。按判定规则（grid 占比 >50%）选方案 B。

方案 B 已实现：EmoteModel 网格缓存——仅缓存 warped grid（flat grid
只有 4 点、比建 key 还便宜），key 为（尺寸/原点 + 逐 seg 平移/矩阵/
warp 控制数据）的 0.005px 量化串，LRU 点数预算 150 万点；默认关，
stage 建模时开启（与 fast 同模式），测试套件保持逐位一致
（test_emote PASS 177 poses）。

实测（同一 180s 段，前后对比）：grid 命中 20,528 次；
grid_ms 21.2s → 8.8s；collect 27.9s → 16.1s（-42%）；
渲染总耗时 30.5s → 18.1s。autoplay 统计逐项一致、0 错误。
残余大头变为 travel 的其余部分（选帧/Ctx 合成/字典构造约 7.2s）
与节点更新；若还要再压，方案 A 子树缓存是唯一剩余路线，
其难点与验证策略如前文。
