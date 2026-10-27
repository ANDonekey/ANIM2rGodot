# ANIM2rGodot 项目记忆

## 项目身份

- 目标（2026-10-28 用户明确）：为 ANIM.teamMM 自研引擎做**通用播放器**——
  有原始数据包就能直接游玩（解释器模式，如 ONScripter 之于 NScripter），
  不是逐部游戏转换移植。此目标下 Ren'Py 转换路线与预渲染批量均不成立，已弃用。
- 宿主（2026-10-28 拍板）：Godot（MIT 开源，安卓/桌面/Web 一套代码）。
  Unity 为非开源同架构备选，未采用。
- Web 版与原生版**并行开发**（2026-10-28 用户要求）：浏览器里选游戏文件夹
  直接游玩，数据只在本地读取、不上传。Web 导出关闭线程支持以避开 COOP/COEP
  依赖；宿主首选能设响应头的 Cloudflare Pages，GitHub Pages 不支持自定义头。
- 仓库：github.com/ANDonekey/ANIM2rGodot（公开）。游戏数据永不入库。

## 样本与引擎同一性（实测）

- 逆向样本：《壁の向こうの妻の嬌声2》（2016，GPT 汉化版完整包，2.78G，
  字节原样存于本地实验室目录，不入库）。
- 目标本体：《妻の肉穴にホームステイするマッチョ留学生》（2017）只有主程序
  macho_cn.exe 到手（SHA256 以 4d1321b67d3a 开头），其数据文件未到手。
- 同一引擎的证据：两作主程序 RTTI 类表逐一相同（62 个类，MOSys*/MOStage*/
  GFile*/GSecretFile* 等），文件命名与结构同构。样本结论用于本体属推断，未实测。

## 已攻破（实测，细节见 docs/ 与 reference/python/）

- **GSecretFile 加密**：格式与密钥更新算法完全钉死，解密器与 SExtractor 的
  ANIM 插件逐字节一致；PNG 解密 CRC 全过。
- **sce 脚本格式**：50,561 条记录全量逐字节平铺；对白 27,492 行；
  选项 50 处结构 50/50 符合；主要 op 语义钉死（对白/旁白/选项/标志/BGM
  播放 0x82 共 419 次、停止 0x83 共 145 次/电影/E-mote 加载 0x52 与姿势 0x7C/
  转场 ParamSet 0x68 各 id 计数等），完整规格在 docs/sce-format.md。
- **GFilePack**：voice .pck 与 psbpack.dat 共用，格式钉死。
- **全量解包**：图 1,016、语音 6,649、口型 CSV 6,073、PSB 69、BGM 11、
  电影 78，清单 problems=0。
- **PSB/E-mote**：v3 头部 XorShift128 加密已解（Key4 由已知明文求解，值不入库；
  69/69 头校验通过）；名字 trie/字符串表/chunk 表/对象树全可解析；
  纹理为原始 RGBA 图集 + icon 部件表（69 模型/91 纹理页/9,589 部件导出校验通过）。
- **define.dat em 表**：177 条记录、24 变量；sce 实际用到的 119 个 em 标签
  100% 覆盖。em 标签 = 变量预设（姿势），不是 PSB 内时间轴名。
- **E-mote 评估器**（Python）：图层 parameterize 变量定位时间轴、tween 线性
  插值、选择器 fade 映射、face_eye_open 眨眼轴均已实测并目视验证多姿势；
  三个有符号存储怪癖（坐标 int16 回绕、角度/端点 (180,255] 字节回绕、图标原点
  条件回绕）由数据对称性证明，写在 emote_render.py 注释里。

## 已验证的坑

- Ren'Py 8.5.3 本机环境**不渲染动画 WebP**（三组最小工程 A/B 实测，静态 PNG
  正常）——旧路线预渲染产物不能直接用，此坑与播放器路线无关，仅存档。
- BG/CG 是 2048×2048 画布，实际画面只在左上子矩形（样本实测 1280×720），
  上屏须按不透明 bbox 裁切。
- Godot 编辑器在无显示的 VM 上必须 `--headless` 运行，裸跑 `--version` 会挂住。

## 工具链（本地，已装并实测出包）

- Godot 4.7.2 stable（标准版，GDScript 起步）；导出模板装后 2.0G；
  Temurin JDK 17.0.21；Android SDK 486M（platform-tools 37.0.1、build-tools
  35.0.0、android-35、cmake 3.10.2；sdkmanager 被本机出口代理 reset，
  改走 curl 拉官方清单原包手动布局）。全部在持久目录，VM 重建不丢。
- 三端导出已实测：Web（关线程，39M）/ Android 调试 APK（57M，验签通过）/
  Linux（73M），零错误。GSecret 的 GDScript 移植与 Python 参考字节一致。
- NDK 未装：等 GDExtension（pl_mpeg 电影解码）阶段再装，约 2.5GB。
- 本地坑：/tmp 是 512MB tmpfs，大文件勿 staging 于此；Godot 导出路径
  不能用 `../`；Android 导出须开 import_etc2_astc 且开发期用 --export-debug。

## 未决事项

- 电影 MPEG-1 运行时解码（pl_mpeg 经 GDExtension）；
- VM 边角语义：存档快照 0x16（500 槽）、画廊解锁 0x1F、系统标签主循环、
  0xAC 轴义、0x8E/0x8F 旗标区别、0x92 签名、0xD6 语法；
- define.dat 中 em 表以外的部分未解析；
- E-mote 网格变形（mesh.bp）、遮罩、物理揺れ未实现；
- Mhide208a 某姿势渲染疑似多出一块身体部件，未定位；
- 口型时间轴（face_talk + CSV）未做动态驱动；
- Macho 本体数据包到手后需做同引擎兼容验证。
