# PhotoCraft Bridge

在 XD 或 Figma 中选中图片，发送到 PhotoCraft 编辑，保存后更新回原图层。

不用手动导出再放回设计稿，原图层的位置、大小和旋转角度保持不变。

## 使用要求

仅支持 Apple 芯片的 Mac，需要先安装 PhotoCraft 和对应的设计软件。

| 设计软件 | 系统要求 |
| --- | --- |
| Figma 桌面版 | macOS 11 或更高版本 |
| Adobe XD 36 或更高版本 | macOS 26 或更高版本 |

## 安装

1. 在[下载页面](https://github.com/toufayehehua/photocraft-bridge/releases)下载对应的 Figma 或 XD 安装包及插件包。
2. 解压安装包，打开 **Figma PhotoCraft Setup.app** 或 **XD PhotoCraft Setup.app**，安装后复制显示的配对码。
3. 安装插件：
   - **Figma**：解压插件包，在 Figma 中选择 **Plugins → Development → Import plugin from manifest**，打开其中的 `manifest.json`。
   - **XD**：打开下载的 `.xdx` 文件安装插件。如果 XD 已打开，重启或重新加载插件。
4. XD 用户还需在 **系统设置 → 隐私与安全 → 辅助功能**中允许 **XD Compositor Bridge**。Figma 不需要这项授权。

## 使用

1. 在 XD 或 Figma 中选中一个图片图层。组里的图片要进入组，选中图片本身；一个图层只能有一个可见的图片填充。
2. 运行 **在 PhotoCraft 中编辑**。首次使用时粘贴配对码并连接。
3. 在 PhotoCraft 中编辑打开的图片，按 **Command + S** 保存，结果会更新回原图层。

## 注意事项

- 每次选择一个图片图层，支持 PNG、JPEG 和 GIF；GIF 按静态图片处理。
- 在 PhotoCraft 中添加的图层、蒙版和效果会合成一张图片放回设计稿，不会变成 XD 或 Figma 的多个图层。
- 直接保存此次打开的 PSD 文件，保持 PhotoCraft 的“最大化 PSD 兼容性”开启；“另存为”的新文件不会更新原图层。
- 使用 Figma 时，保持设计文件打开、插件运行。关闭插件或运行其他插件后，需要重新选图并运行本插件。
- 使用 XD 时，保持文档打开。保存后可能短暂切换到 XD，再返回之前的应用；手动调整过的图片内部裁切位置可能需要重新调整。
- 在设计稿中替换图片、删除图层或撤销更新后，需要重新选图并运行插件，才能继续更新。

## 隐私与开源

图片在本机处理，插件不会把图片上传到远程编辑服务；Figma 和 XD 自身的文档同步仍按各自设置运行。工作图片和 PSD 会留在电脑上，需要时自行删除。不要公开配对码。

查看[隐私说明](PRIVACY.md)、[Apache 2.0 许可证](LICENSE)和[第三方声明](THIRD_PARTY_NOTICES.md)。遇到问题可在 [Issues](https://github.com/toufayehehua/photocraft-bridge/issues) 反馈。

## 开发

从源码构建需要 Python 3 和 Xcode 命令行工具，运行 `python3 scripts/build_release.py`。直接使用安装包无需这些工具。
