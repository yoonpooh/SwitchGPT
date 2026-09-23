<p align="center">
  <img src="Assets/SwitchGPT.png" width="128" alt="SwitchGPT 图标">
</p>

# SwitchGPT

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md) · **简体中文**

**保留插件与远程连接，只切换运行模型的账户。**

SwitchGPT 是一款 macOS 菜单栏应用，在保持 ChatGPT 桌面账户登录的同时，选择处理 Codex 模型请求的账户。GitHub 等已连接插件以及对这台 Mac 的远程访问继续使用原有认证，同时你可以使用多个已保存账户的剩余额度。

你可以手动选择账户，也可以在额度用尽时自动切换到其他可用账户。

[下载 v0.2.5](https://github.com/yoonpooh/SwitchGPT/releases/tag/v0.2.5) · [最新版本](https://github.com/yoonpooh/SwitchGPT/releases/latest)

## 当前源码（尚未发布）

- **mini 模型兼容路由：** 将 GPT-5.4 mini / low 请求转为 GPT-6 Luna / low，并支持 zstd 压缩请求。
- **简化面板：** 减少临时用量查询错误提示和空状态区域的间距。

其他模型和推理级别保持不变。此修改尚未包含在已发布的 0.2.5 应用中。

## 0.2.0 引入的核心功能

- **保留桌面登录：** 切换模型账户时，保留现有插件连接和远程访问所用的桌面认证。
- **切换无需重启：** 首次连接后，新的模型请求使用所选账户。已经正常处理中的响应由原账户完成。
- **额度用尽自动切换：** 5 小时或每周额度任一用尽时，按保存列表的顺序选择可用账户。
- **区分选择与实际处理：** 分别显示下次请求的账户、最近完成响应的账户和桌面登录账户。

账户卡片还会显示剩余额度、重置时间、套餐徽章、可用头像和重置次数。在小巧的面板中即可重命名、拖动排序和管理账户。认证信息保存在 macOS 钥匙串中。界面支持英语、韩语、日语和简体中文。

## 各项连接使用哪个账户？

| 连接 | 使用的账户 |
| --- | --- |
| ChatGPT 桌面登录 | 当前桌面账户 |
| GitHub 等已连接插件 | 已连接到应用的各服务账户 |
| 对这台 Mac 的远程访问 | 原有桌面登录和远程设置 |
| 这台 Mac 上的 Codex 模型请求 | SwitchGPT 中选择的账户 |

例如，桌面保持 A 账户登录及原有 GitHub 连接、远程设置，模型请求则由已保存的 B 账户处理。B 的额度用尽后，可自动切换到 C，无需更改桌面登录或重新连接插件。

适用于这台 Mac 上使用内置 `openai` 提供方的 Codex 请求，也包括通过远程连接在这台 Mac 上执行的请求。不会更改普通 Chat 对话、其他提供方，或在其他电脑、云端执行的模型请求。

## 安装与连接

需要 **Apple 芯片 Mac、macOS 14 或更新版本**，以及已安装并登录的当前 ChatGPT 桌面应用。须使用默认文件式认证路径 `~/.codex/auth.json`。SwitchGPT 使用应用自带的 CLI，无需单独安装 CLI。

1. 从[发布页面](https://github.com/yoonpooh/SwitchGPT/releases/tag/v0.2.5)下载 `SwitchGPT-v0.2.5-macos-arm64.zip` 和 `SHA256SUMS.txt`。
2. 使用下方命令验证校验和，解压 ZIP，将 **SwitchGPT.app** 移至**应用程序**。
3. 打开 SwitchGPT 并点击菜单栏图标。选择 **+**，通过浏览器登录添加账户。对每个要保存的账户重复操作。
4. 首次选择账户时，在 `⋯` 中关闭自动切换，然后点击账户卡片。若要按列表顺序使用，请重新开启自动切换。 如提示重启 ChatGPT，请先完成正在进行的工作。
5. 在桌面应用中发送 Codex 请求，确认响应正常完成。

将 ZIP 和校验和文件放在同一文件夹中，然后运行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

SwitchGPT 没有普通窗口或 Dock 图标。使用模型中继时，请保持它在菜单栏中运行。

### 首次启动与更新

发布版采用 **ad-hoc 签名**，**未经 Apple 公证**。若 macOS 阻止启动，请确认下载来源并尝试打开应用，然后在选项可用时使用**系统设置 → 隐私与安全性 → 仍要打开**。请参考 [Apple 的说明](https://support.apple.com/en-ca/guide/mac-help/mh40616/mac)。受管理的 Mac 可能限制此选项。

更新时，请等待正在处理的模型响应完成，通过 `⋯` 退出 SwitchGPT，替换应用程序中的应用后重新打开。已保存账户和钥匙串条目位于应用包外。由 0.1.x 更新时，如有提示，请完成首次连接步骤。

### 请 ChatGPT 帮忙安装

粘贴到可使用本地文件与终端工具的 ChatGPT 会话中：

```text
请从 https://github.com/yoonpooh/SwitchGPT 安装最新的 SwitchGPT 版本到这台 Mac。先确认 Mac 符合要求，下载应用 ZIP 和公开的 SHA256SUMS.txt，并在安装前验证校验和。保留所有已保存账户和钥匙串条目。如果 SwitchGPT 正在运行，请等待模型响应完成后退出它，替换 /Applications 中的应用并重新打开。不要代为登录、切换账户或重启 ChatGPT。如果 macOS 阻止首次启动，请指导我使用 Apple 针对单个应用的“仍要打开”步骤，不要禁用系统安全设置。
```

若无法使用本地工具，请采用上述手动安装步骤。

## 面板使用方法

- **所选账户：** 在列表中突出显示，手动模式下可点击更改。
- **桌面登录：** 在底部分别显示桌面登录账户。
- **自动切换：** 在 `⋯` 中默认开启，标题旁显示自动或手动。
- **刷新：** 获取用量和可用重置次数。面板关闭时仍会在每次刷新完成 60 秒后自动刷新；登录、切换账户或正在刷新时会跳过。
- **账户管理：** 拖动卡片设置顺序；通过 `⋯` 或右键重命名、从保存列表移除账户。显示名称留空会恢复邮箱。移除保存记录不会删除 OpenAI 账户本身。

点击账户卡片的 **重置**，确认目标账户及消耗1次重置机会后使用。当前不可用或查询信息过期时，按钮会禁用。使用后会重新查询限额和剩余次数，自动模式会重新应用账户优先级。若响应中断或后续刷新失败，可点击 **确认结果** 继续此前的请求。未确认的请求编号会在重启应用后保留，重置次数不会自动消耗。

日期采用 Mac 的时区和界面语言。更改 Mac 首选语言后请重新打开应用。不支持的语言回退为英语，其他中文地区或文字变体使用简体中文。

## 自动切换

1. 自动模式优先使用列表中近期查询确认可用的第一个账户。使用第 3 个账户时，若第 1 个账户额度恢复，会在查询确认恢复后的下一个模型请求中使用第 1 个账户。仅到达预计重置时间不会触发切回。
2. 如果服务器以 `usage_limit_reached` 拒绝模型请求，会在转发响应前换用可用账户重试。每个请求对每个账户最多尝试一次。
3. 已正常开始的流式响应由原账户完成，不会重新执行。
4. 临时速率限制和认证错误直接返回，不触发切换。用量查询失败或信息过期的账户不会被选为自动切换的备选账户。
5. 如果所选账户已用尽且无法确认可用备选账户，请求会停止。需要等待额度重置，或选择、添加可用账户。重置次数不会被自动消耗。

在 `⋯` 中关闭自动切换后，将继续使用所选账户并直接返回其额度错误。自动模式下，卡片顺序优先于手动选择，调整顺序会从下一个请求起生效。各账户额度仍各自独立。

## 问题排查

- **退出 SwitchGPT 后请求失败：** 重新打开它，或按下方说明解除中继连接。
- **首次连接一直待确认：** 如有重启按钮，请先使用，再在桌面完成实际 Codex 请求。用量刷新或 CLI 请求不会确认桌面连接。
- **账户需要重新登录：** 通过浏览器重新添加该账户。已保存账户会自动刷新；如果刷新令牌本身已过期或被撤销，则需要重新登录。
- **无法获取用量：** 缺失信息显示为未知，而不是剩余量为零。
- **已有自定义端点：** SwitchGPT 会提示冲突，不会覆盖其他中继设置。

## 数据与兼容性

认证信息存储于 macOS 钥匙串。选择模型账户时保留 `~/.codex/auth.json`，将所选账户的认证读入内存。SwitchGPT 通过 `127.0.0.1:19565` 的中继直接向 OpenAI 转发模型请求，没有外部 SwitchGPT 服务器。

| 本地数据 | 存储位置 |
| --- | --- |
| 账户列表和顺序 | `~/Library/Application Support/SwitchGPT/accounts.json` |
| 所选模型账户 | `~/Library/Application Support/SwitchGPT/routing-selection.json` |
| 自动切换和连接状态 | `~/Library/Application Support/SwitchGPT/routing-preferences.json` |
| 未确认的重置请求编号 | `~/Library/Application Support/SwitchGPT/reset-credit-attempts.json`（含用于并发保存控制的 `.lock` 文件） |
| 请求元数据 | `~/Library/Application Support/SwitchGPT/relay-events.jsonl` |
| 原有桌面认证 | `~/.codex/auth.json` — 保留 |

通过 `~/.codex/config.toml` 的管理区块设置 `openai_base_url`，并使用 HTTP 流式传输，让后续请求采用所选账户。本地日志记录不透明的账户标识、路径、模型、HTTP 状态、完成状态、令牌计数、客户端类型、时间及额度耗尽状态。不记录提示词、响应内容或认证令牌。

解除连接时，请先结束正在进行的工作，仅移除 `~/.codex/config.toml` 中的 `BEGIN/END SwitchGPT model routing` 区块，然后重启 ChatGPT。保留其他设置。之后可以退出或删除 SwitchGPT；只删除应用包会留下中继设置。

用量通过 OpenAI 的非公开端点 `chatgpt.com/backend-api/wham/` 获取。端点和桌面行为可能变化。若当前账户列表不存在，会复制旧存储位置的列表，并保留原文件及钥匙串条目。

当前限制：

- 仅发布 Apple 芯片版本，Intel 未验证。
- 不支持 API 密钥认证、keyring/auto 认证存储、自定义 `CODEX_HOME` 或配置其他远程主机。对这台 Mac 的远程访问保留原有设置。
- 使用这台 Mac 内置 `openai` 提供方及相同配置的 CLI 会话也会经过中继。
- 没有内置应用更新器。当前桌面会话由Codex刷新令牌，SwitchGPT同步其最新认证信息。
- 构建成功不代表兼容所有桌面或 macOS 版本。实际插件与远程行为需要单独验证。

请勿在 Issue 或提交中包含认证信息、账户列表或显示个人账户的截图。SwitchGPT 是独立工具，与 OpenAI 无关联，也未获得 OpenAI 的认可。

## 从源码构建

安装包含 Swift 6 和 macOS SDK 的 Xcode，并选用其命令行工具，然后运行：

```sh
brew install zstd
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

脚本会为运行构建的 Mac 的架构生成应用。已发布的 v0.2.5 文件是 Apple 芯片构建。

```sh
./script/build_and_run.sh --release
ditto -c -k --norsrc --keepParent dist/SwitchGPT.app dist/SwitchGPT-v0.2.5-macos-arm64.zip
(cd dist && shasum -a 256 SwitchGPT-v0.2.5-macos-arm64.zip > SHA256SUMS.txt)
```

## 源码结构

```text
Assets/                         应用和菜单栏图标
Sources/SwitchGPT/
  App/                          菜单栏应用入口
  Models/                       账户、用量模型及本地化辅助逻辑
  Resources/                    英语、韩语、中文和日语文本
  Services/                     登录、钥匙串、用量及桌面会话处理
  Stores/                       账户状态和排序
  Views/                        账户面板和用量显示
Tests/SwitchGPTTests/            凭据、登录、服务器、排序及本地化测试
script/build_and_run.sh          构建和应用打包入口
```

测试使用模拟凭据和临时文件，不会实际切换账户或消耗额度重置次数。真实登录和服务器兼容性需要单独验证。
