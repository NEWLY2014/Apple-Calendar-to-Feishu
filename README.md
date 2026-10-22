# Apple 日历同步到飞书

一个原生 macOS 小工具，使用 Swift、AppKit 和 EventKit 读取 Apple 日历，通过飞书官方 `lark-cli` 将选定范围内的日程同步到飞书主日历。

## 功能

- 选择日期范围和来源日历，预览新增、更新、无变化及删除项目后手动确认同步。
- 同步后的日程标记为忙碌，默认设为私密；不开启提醒、不邀请参会人、不发送通知、不创建视频会议。
- 全天日程默认关闭，可手动开启。
- 删除同步默认关闭；开启后，仅处理本工具记录中、位于所选日历和日期范围的缺失日程。
- 保存本地同步映射与内容指纹，供后续同步识别已处理日程。

本工具单向同步 Apple 日历到飞书，每次需手动运行，不在后台自动同步。Apple 中的重复日程会按所选范围内的单次实例处理。

## 运行要求

- macOS 14 或更新版本。
- 构建需要 Xcode Command Line Tools（提供 `swiftc`、macOS SDK 和签名工具）。
- 安装并配置飞书官方 [lark-cli](https://github.com/larksuite/cli)，完成用户身份授权，并授予创建、修改和删除日历日程所需的权限。
- 应用在 `/opt/homebrew/bin/lark-cli` 或 `/usr/local/bin/lark-cli` 查找 CLI。若安装在其他位置，需调整源码中的 `callCLI` 路径。

可先在终端执行 `lark-cli auth status` 检查授权，并用 `lark-cli calendar events create --help` 检查所安装版本的日历命令接口。应用不会内置或自动配置你的飞书应用凭据。

## 构建

```sh
xcode-select --install # 已安装 Command Line Tools 时可跳过
./scripts/build.sh
open "build/Apple日历同步到飞书.app"
```

脚本为当前 Mac 的 CPU 架构构建应用，并执行本地临时签名。构建产物位于 `build/`，不纳入 Git。临时签名不等同于 Apple Developer ID 签名或公证。

## 使用

1. 打开应用，允许访问 Apple 日历。
2. 选择开始日期、结束日期和需要同步的来源日历。
3. 按需调整私密、全天日程及删除同步选项。
4. 点击“预览变化”，检查待处理日程。
5. 点击“开始同步”，在确认窗口中核对数量并执行。

详见 [使用说明](docs/使用说明.md)。

## 本地数据与凭据

同步映射保存在 `~/Library/Application Support/AppleToFeishuManualSync/mappings.json`，其中包含来源日历标识、标题、时间和飞书日程 ID。请妥善保留该文件；丢失映射后，工具可能无法识别之前同步的日程。

飞书凭据由本机 `lark-cli` 管理。仓库仅包含源码、应用元数据、构建脚本和文档，不包含授权二维码、访问令牌、个人日程、同步映射或预编译应用。

## 代码结构

```text
Sources/AppleToFeishuSync.swift   应用界面、EventKit 读取、同步与状态保存
Resources/Info.plist             应用标识与日历权限说明
scripts/build.sh                 编译、打包和本地临时签名
docs/使用说明.md                使用说明
```
