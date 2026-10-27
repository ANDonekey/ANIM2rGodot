# player/

Godot 4.7 工程。模块设计见 `../docs/architecture.md`。

## 工具链（本地已装并验证，2026-10-28）

- Godot 4.7.2 stable（标准版）：`~/workspace/tools/godot-4.7.2/`
  - 本机无显示环境必须带 `--headless`，裸跑会挂住
- 导出模板 4.7.2：`~/.local/share/godot/export_templates/4.7.2.stable/`（2.0G）
- Temurin JDK 17.0.21：`~/workspace/tools/jdk17/`
- Android SDK：`~/workspace/tools/android-sdk/`（486M；platform-tools 37.0.1、
  build-tools 35.0.0、platforms android-35、cmake 3.10.2）
  - sdkmanager 在本机走不通（出口代理对 Java 的连接直接 reset），组件是按
    官方仓库清单用 curl 拉原包手动布局的；编辑器设置里已指向上述路径
- 调试密钥：`~/workspace/tools/debug.keystore`（androiddebugkey / android）

## 导出（已实测出包）

在 `player/` 下：

```bash
G=~/workspace/tools/godot-4.7.2/Godot_v4.7.2-stable_linux.x86_64
$G --headless --export-release "Web"      # build/web/（关线程版，39M）
$G --headless --export-debug   "Android"  # build/android/anim2rgodot.apk（57M，签名校验通过）
$G --headless --export-release "Linux"    # build/linux/
```

注意：Android 用 `--export-release` 会因缺 release 密钥失败，开发期用
`--export-debug`；Android 导出依赖工程设置 `import_etc2_astc=true`（已开）。

## 字体（克隆后必做一步）

字体文件不入库（体积原因）。把 Noto Sans CJK 常规体放到
`player/assets/fonts/NotoSansCJK-Regular.ttc`（系统字体目录一般有现成的
`NotoSansCJK-Regular.ttc`，或从 Google Noto 官网下载），工程设置已将其
设为默认字体；缺失时 Godot 回退默认字体，中文会显示为方框。

## 运行

```bash
$G --headless --path . -- --game-dir /path/to/game   # 指定游戏目录（桌面调试）
$G --path .                                          # 正常启动，弹目录选择框
```

操作：点击 / 空格 / 回车推进；F5 快速存档 / F9 读档（`user://save.json`）；
脚本快照点（op 0x16）自动存档。工程默认字体已内嵌 Noto Sans CJK。

无头自动播放验收（Xvfb 下截图 + 统计）：

```bash
xvfb-run -a $G --path . --resolution 1280x720 -- --game-dir /path/to/game \
  --autoplay 240 --shots out/shots --stats out/stats.json
```

## 测试

```bash
$G --headless --path . -s tests/test_gsecret.gd -- <加密文件> <期望sha256>
$G --headless --path . -s tests/test_loader.gd  -- <gamedir>
$G --headless --path . -s tests/test_parser.gd  -- <gamedir> <baseline_sce.json>
$G --headless --path . -s tests/test_vm.gd      -- <gamedir> <baseline_oracle.json>
$G --headless --path . -s tests/test_emote.gd   -- <gamedir> <baseline_emote.json>
```

期望值全部由 `reference/python/` 的参考实现生成（同输入同输出验收）：
GSecret 在 sce / define / .gax 三个真实文件上字节一致；解析器记录链哈希
50,561 条与 Python 基准全等；VM 与独立 Python 模拟器的规范事件流
34,860 个全等（一次完整通关）；E-mote 三组姿势部件几何逐项一致。

注意：`-s` 脚本编译失败时 headless 进程会空转不退出——务必用外部
`timeout 60` 包裹并回读日志确认 PASS，别信进程退出码。
