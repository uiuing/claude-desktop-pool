<p align="center">
  <img src="docs/images/banner.png" alt="Claude Pool" width="100%">
</p>

<p align="center">
  <a href="https://github.com/uiuing/claude-desktop-pool/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/uiuing/claude-desktop-pool?label=release&color=D97757"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <a href="https://github.com/uiuing/claude-desktop-pool/actions/workflows/check.yml"><img alt="Checks" src="https://github.com/uiuing/claude-desktop-pool/actions/workflows/check.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/github/license/uiuing/claude-desktop-pool"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

<h3 align="center">多个 Claude 账号，一个 Claude Desktop 全用上。</h3>

<p align="center">一个账号额度用完，下一个自动接上。<br>还是同一段对话，不用退出重登，也不用重新开始。</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/pool-zh-Hans-dark.png">
  <img alt="Claude Pool：多个 Claude 账号的剩余额度" src="docs/images/pool-zh-Hans-light.png">
</picture>

## Claude Pool 适合你吗？

你有不止一个 Claude 订阅，可在 Claude Desktop 里用起来很折腾：

- 聊到一半，账号的 5 小时或每周额度用完，对话只能停下。
- 换账号要退出、重新登录，原来的对话也带不过去。
- 哪个账号还有余量，只能一个个登进去看。
- 有的账号早早用完，有的一直闲着；没用过的额度也不会开始下一个周期。
- 贴代码、日志或配置提问时，密钥、密码和个人信息也跟着发了出去。

Claude Pool 把这些账号放在同一个连接背后。Claude Desktop 只连一次，由 Pool 决定哪个账号来回答。

## 为什么用 Claude Pool

- **额度用完也能接着聊。** 账号快用完时，下一轮提问会换到还有余量的账号，对话一起带过去。已经开始的回答不会重复发送。
- **Desktop 只连一次。** 一键把 Claude Desktop 指向 Pool，之后增删账号都不用再动 Desktop。断开时恢复你原来的设置。
- **所有账号的额度一目了然。** 菜单栏和主面板显示每个账号还剩多少、什么时候重置。
- **花钱买的额度一点不浪费。** 新对话交给余量最多的账号；额度一重置，Pool 可以马上开始新周期，下次重置也来得更早。
- **敏感信息留在本机。** 消息和工具结果里的密钥、密码、邮箱等个人信息，在请求发出前就在本机替换掉，回复里再还原。识别由本机的 [AstrLink Guard](https://huggingface.co/QuantumNous/astrlink-guard) 模型完成，不经过任何远程脱敏服务。
- **用量心里有数。** 按模型、套餐、账号查看 token、缓存命中和估算费用。
- **只用官方客户端。** 每个请求都经由官方 Claude Code，用各账号自己的登录。不用 API Key，不复制 token。
- **不用操心维护。** Claude Code 的安装、更新和首次设置都由 Pool 自动完成。

<table>
  <tr>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/accounts-zh-Hans-dark.png"><img alt="账号" src="docs/images/accounts-zh-Hans-light.png"></picture></td>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/routing-zh-Hans-dark.png"><img alt="分配" src="docs/images/routing-zh-Hans-light.png"></picture></td>
  </tr>
  <tr>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/usage-zh-Hans-dark.png"><img alt="用量" src="docs/images/usage-zh-Hans-light.png"></picture></td>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-zh-Hans-dark.png"><img alt="设置" src="docs/images/settings-zh-Hans-light.png"></picture></td>
  </tr>
</table>

## 安装

1. 从 [Releases](https://github.com/uiuing/claude-desktop-pool/releases/latest) 下载最新的 `Claude-Pool-*-universal.zip`，把 **Claude Pool.app** 拖进「应用程序」。
2. 目前的版本还没有经过 Apple 公证，第一次打开会被 macOS 拦下。先打开一次，再到 **系统设置 › 隐私与安全性** 点 **仍要打开**。也可以在终端执行：

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Claude Pool.app"
   ```

需要 macOS 14 或更高版本，支持 Apple 芯片和 Intel。每个版本的下载文件旁都附有 SHA-256 校验值。

## 开始使用

1. **打开 Claude Pool。** 它会自己安装官方 Claude Code 客户端和本地脱敏模型。
2. **添加账号。** 每个账号都走 Claude 自己的登录流程，以验证过的邮箱作为标识。
3. **连接 Claude Desktop。** Pool 把网关配置写进 Desktop 的设置并打开 Desktop；如果 Desktop 正在运行，会先问你再重启。
4. **照常使用 Desktop。** Pool 在背后分配对话，随时可以断开并恢复 Desktop 原来的设置。

你平时的 Desktop 登录、已有对话，以及你自己安装的 Claude Code 都各自独立，不受影响。

## 工作原理

```
Claude Desktop ──► 本地网关（仅本机回环地址，需验证）
                       │  本地脱敏
                       ▼
                    账号分配 ──► 官方 Claude Code（交互模式）
                                  每个账号一个独立文件夹
```

Desktop 把请求发到 Pool 的本地网关。Pool 先做脱敏，再选账号，把这一轮交给该账号的交互式 Claude Code 会话。回复按 Claude Code 收到的样子流式传回；Desktop 的工具通过 MCP 桥交还给 Desktop，仍由 Desktop 执行。详见 [架构](docs/architecture.md)、[兼容性](docs/compatibility.md) 和 [产品约定](docs/product.md)（英文）。

## 从源码构建

需要装有 Swift 6 工具链的 Xcode 命令行工具。

```bash
git clone https://github.com/uiuing/claude-desktop-pool.git
cd claude-desktop-pool
swift build
swift test
zsh scripts/build.sh
open "dist/Claude Pool.app" --args --demo
```

`--demo` 只显示虚构数据：不读取账号、不启动网关，也不启动任何 Claude 进程。`zsh scripts/package.sh --universal` 会生成发布用的压缩包和校验值。完整检查步骤见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 隐私

- Pool 从不读取、复制或记录你的 Claude 凭据，凭据由 Claude Code 保存在各自的账号文件夹里。
- 应用日志只记录决策、计数和耗时，不记录对话内容。
- 脱敏完全在你的 Mac 上进行，处理文本和工具的结构化数据，不识别图片内容；和任何检测器一样，它也可能漏检或误判。设置里有本地预览可以检查效果。
- 网关只监听本机回环地址，需要密钥，并拒绝来自浏览器网页的请求。

## 致谢

Claude Pool 的灵感来自 [Magpie](https://github.com/yetone/magpie)，感谢作者 [yetone](https://github.com/yetone) 开发并开源了这个项目。

第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 声明

Claude Pool 是独立的开源项目，与 Anthropic 没有关联，也未获其认可或赞助。Claude、Claude Code 和 Claude Desktop 是 Anthropic 的商标。请只用于你自己拥有的订阅，并遵守 Anthropic 的服务条款和使用政策，使用责任由你自行承担。

## 许可证

[MIT](LICENSE) © uiuing
