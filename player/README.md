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

## 测试

```bash
$G --headless --path . -s tests/test_gsecret.gd -- <加密文件> <期望sha256>
```

期望哈希由 `reference/python/anim_gsecret.py` 对同一文件算出；
已在 sce / define / .gax 三个真实文件上字节一致（PASS）。
