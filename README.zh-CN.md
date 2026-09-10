<p align="center">
  <img src="Assets/SwitchGPT.png" width="128" alt="SwitchGPT 图标">
</p>

# SwitchGPT

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md) · **简体中文**

一款轻量的 macOS 菜单栏应用，用于切换 **ChatGPT 桌面应用**中的账户。

在一个小巧的面板中保存账户、查看剩余用量并切换账户。SwitchGPT 是独立工具，与 OpenAI 无关联，也未获得 OpenAI 的认可。

[下载最新版本](https://github.com/yoonpooh/SwitchGPT/releases/latest)

## 功能

- 通过浏览器登录添加账户，不替换当前 ChatGPT 会话。
- 将登录凭据保存在 macOS 钥匙串中。
- 显示账户邮箱和套餐徽章。
- 显示服务返回的使用额度周期、剩余百分比和重置时间。
- 显示可用的额度重置次数及最近的到期日期。将指针移到日期上可查看具体时间。
- 确认后切换账户；此过程会重新启动 ChatGPT 及其本地后台服务器。
- 拖动卡片调整账户顺序，并通过边框突出显示当前账户。
- 菜单栏图标随浅色和深色外观自动调整。
- 根据 Mac 的首选语言显示英语、韩语、简体中文或日语。其他语言回退为英语；本版本的其他中文地区或文字变体也使用简体中文。
- 日期采用所选语言的格式和 Mac 的时区。

## 系统要求

- macOS 14 或更新版本。
- 可下载的 `arm64` 构建适用于搭载 Apple 芯片的 Mac。本版本不包含 Intel 构建，也未验证其兼容性。
- 已安装并登录当前版本的 ChatGPT 桌面应用。
- 使用默认的文件式凭据存储路径 `~/.codex/auth.json`。

SwitchGPT 面向整合了 Chat、Work 和 Codex 的当前 ChatGPT 桌面应用（[OpenAI 文档](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)）。它通过现有的应用标识符 `com.openai.codex` 查找应用，并使用应用自带的 CLI，无需单独安装 CLI。浏览器会话不会被更改。

## 安装

1. 从[发布页面](https://github.com/yoonpooh/SwitchGPT/releases)下载 `SwitchGPT-v0.1.2-macos-arm64.zip`。
2. 解压 ZIP，将 **SwitchGPT.app** 移到**应用程序**文件夹。
3. 打开应用。菜单栏会出现双向箭头图标；应用没有常规窗口或 Dock 图标。
4. 点击菜单栏图标，选择**添加账户**，然后在浏览器中完成登录。

### 请 ChatGPT 帮忙安装

在可以使用本地文件和终端工具的 ChatGPT 会话中，粘贴以下提示词：

```text
请从 https://github.com/yoonpooh/SwitchGPT 安装最新的 SwitchGPT 版本到这台 Mac。先确认该版本支持我的 Mac，下载应用 ZIP 和随附发布的 SHA256SUMS.txt，并在安装前验证校验和。退出所有正在运行的 SwitchGPT 实例，将应用安装到 /Applications 并打开。保留所有已保存的账户和钥匙串项目。不要替我登录或切换账户。如果 macOS 阻止首次启动，请指导我按照 Apple 的单个应用“仍要打开”步骤操作，不要关闭系统安全设置。
```

如果无法使用本地工具，请按照上面的手动安装步骤操作。

### 首次启动

发布版本采用 **ad-hoc 签名**，**未经 Apple 公证**。如果 macOS 阻止启动，请确认下载的是预期版本，尝试打开应用，然后在选项可用时使用**系统设置 → 隐私与安全性 → 仍要打开**。请参考 [Apple 关于打开来源不明应用的说明](https://support.apple.com/en-ca/guide/mac-help/mh40616/mac)。组织管理的 Mac 可能会限制此类例外许可。

发布文件还包含 `SHA256SUMS.txt`。将两个下载文件放在同一文件夹中，然后运行以下命令验证压缩包：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

### 更新

从菜单栏面板退出 SwitchGPT，将应用程序文件夹中的应用替换为新版本，然后重新打开。已保存的账户列表和钥匙串项目存储在应用包之外。

## 使用方法

1. **添加账户：** 为每个要保存的账户完成浏览器登录。邮箱地址从登录凭据中读取。
2. **刷新：** 点击刷新按钮获取当前用量和可用重置次数。
3. **切换：** 先完成正在进行的 ChatGPT 工作，再点击其他账户卡片并确认重启。点击当前账户不会触发切换。
4. **排序：** 将一张账户卡片拖到另一张卡片上，以更改保存顺序。
5. **移除：** 点击垃圾桶图标并确认从保存列表中移除。这不会删除 OpenAI 账户本身。

额度重置区域**仅供查看**。SwitchGPT 不会执行或消耗重置次数。

语言变更会在重新打开应用后生效。应用内不提供语言选择菜单。

## 从源码构建

安装包含 Swift 6 和 macOS SDK 的 Xcode，并选用其命令行工具，然后运行：

```sh
git clone https://github.com/yoonpooh/SwitchGPT.git
cd SwitchGPT
./script/build_and_run.sh --verify
```

此命令会在 `dist/SwitchGPT.app` 构建本地应用，进行 ad-hoc 签名并启动，然后检查进程是否运行。它不会自动安装到应用程序文件夹。要安装自行构建的版本，请退出 SwitchGPT，然后使用 Finder 将生成的应用移到应用程序文件夹。

可用命令：

```sh
./script/build_and_run.sh           # 构建并启动调试版
./script/build_and_run.sh --verify  # 构建、启动并检查进程
./script/build_and_run.sh --build   # 仅构建调试版，不启动
./script/build_and_run.sh --release # 仅构建优化版，不启动
swift test                         # 运行测试
```

请尽量将仓库放在 iCloud Drive 之外。如果同步文件夹导致与 Finder 信息或资源分支相关的代码签名错误，请使用独立的构建目录运行测试：

```sh
swift test --scratch-path /tmp/switchgpt-tests
```

### 打包发布版本

脚本会为运行构建的 Mac 的架构生成应用。已发布的 v0.1.2 文件是 Apple 芯片构建。

```sh
./script/build_and_run.sh --release
ditto -c -k --norsrc --keepParent dist/SwitchGPT.app dist/SwitchGPT-v0.1.2-macos-arm64.zip
(cd dist && shasum -a 256 SwitchGPT-v0.1.2-macos-arm64.zip > SHA256SUMS.txt)
```

Swift 包和可执行目标保留内部名称 `CodexAccountSwitch`；应用包和界面使用 `SwitchGPT`。

## 数据与兼容性

| 数据 | 存储位置 |
| --- | --- |
| 已保存的登录凭据 | macOS 钥匙串，服务 `local.codex-account-switch.credentials` |
| 账户列表和顺序 | `~/Library/Application Support/CodexAccountSwitch/accounts.json` |
| 当前桌面登录凭据 | `~/.codex/auth.json` |

切换前，应用会保存当前凭据，并通过权限为 `0600` 的临时文件替换当前认证文件。如果 ChatGPT 重启失败，应用会尝试恢复之前的凭据，并报告恢复失败的情况。

用量信息直接从 OpenAI 的非公开端点 `chatgpt.com/backend-api/wham/` 获取。SwitchGPT 没有自己的后端。这些端点及桌面应用的本地服务器行为可能发生变化，凭据过期后可能需要重新登录。仅在本地成功重启，并不能证明服务器已经接受新会话。

当前限制：

- 不支持 API 密钥认证、keyring/auto 凭据存储方式、自定义 `CODEX_HOME` 或远程主机。
- 不提供自动账户切换或内置更新器。
- 切换可能影响与桌面应用共享本地服务器的 CLI 会话。请先完成正在进行的工作。
- 缺失的用量或到期信息会显示为不可用，而不是零。
- 构建成功并不代表与所有 ChatGPT 桌面版本或受支持的 macOS 版本均兼容。

请勿在 Issue 或提交中包含凭据、账户列表或显示个人账户信息的截图。

## 源码结构

```text
Assets/                         应用和菜单栏图标
Sources/CodexAccountSwitch/
  App/                          菜单栏应用入口
  Models/                       账户、用量模型及本地化辅助逻辑
  Resources/                    英语、韩语、中文和日语文本
  Services/                     登录、钥匙串、用量及桌面会话处理
  Stores/                       账户状态和排序
  Views/                        账户面板和用量显示
Tests/CodexAccountSwitchTests/   凭据、登录、服务器、排序及本地化测试
script/build_and_run.sh          构建和应用打包入口
```

测试使用模拟凭据和临时文件，不会实际切换账户或消耗额度重置次数。真实登录和服务器兼容性需要单独验证。
