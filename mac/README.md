# Typefree

**macOS 上的 AI 语音输入法：按住快捷键说话，松手后文字已经整理好、贴进了光标处。**

[官网 typefree.app](https://typefree.app) · [下载 DMG](https://github.com/kdsz001/typefree/releases/latest/download/Typefree.dmg) · [API Key 配置教程](https://typefree.app/setup-guide.html) · [会员](https://typefree.app/#pricing)

> 这个目录（`mac/`）是 Typefree macOS 版的完整源码，以 GPL-3.0 开源。仓库根目录是官网；功能介绍和动画演示看[仓库首页](../README.md)，这里偏开发者说明。

## 能做什么

- **说话变文字**：按住快捷键（或鼠标长按）说话，松手即识别，AI 自动去口语、理顺句子、分段、加标点，直接输入到任何 App
- **长按问 AI**：在空白处长按说一句问题，右上角面板给出联网回答，可续聊、可固定
- **语音翻译 / 口令**：句首或句尾说「用英文」直接输出英文
- **词库与纠错学习**：常用词可加进词库；识别错的词改过一次，下次自动认对
- **历史记录**：所有输入本地加密保存，可导出，保留时长可设
- **多家模型**：识别用火山引擎，润色用通义千问，自动路由质量与速度

## 三种用法

| | 说明 |
|---|---|
| **免费试用** | 官方签名版（官网 / GitHub Releases 的 DMG）含 7 天试用，零配置，走作者的服务器 |
| **自带 Key** | 在「设置 → 模型」填入你自己的 API Key，**永久免费、不限字数**。费用走你自己的账户，Key 只存在本机钥匙串 |
| **会员** | ¥188 / 年，不用申请任何 Key，识别、润色、问 AI 走作者的服务器。会员通道同样只在官方签名版里可用 |

## 从源码构建

要求：macOS 14.0+，Xcode 26.3（Swift 6）。

```bash
cd mac
./build.sh                       # 产物在 dist/Typefree Install.app
bash scripts/install_app.sh      # 安装到 /Applications，然后自己 open 一下
```

也可以直接用 Xcode 打开 `VoicePolish.xcodeproj`，scheme `VoicePolish`。签名换成你自己的 Team 即可。

**自己编译的版本没有试用和会员通道**（服务器地址不在仓库里，见 `local.build.env.example`），装好后先到「设置 → 模型」填入自己的 API Key——[教程在这里](https://typefree.app/setup-guide.html)，几分钟就能拿到火山引擎的 Key。

运行核心库测试：

```bash
cd mac/VoicePolishCore && swift test
```

## 目录

- `Sources/` — macOS 状态栏 App（AppKit + SwiftUI）
- `VoicePolishCore/` — 核心库（录音、云端识别、AI 润色、词库、历史加密），Swift Package
- `Resources/` — 图标、entitlements
- `build.sh` / `scripts/install_app.sh` — 本地构建与安装

不在这里的：iOS 版、Windows 版、试用服务器、激活服务、评测工具。

## 隐私

- 你的 API Key 只保存在本机钥匙串，绝不上传
- 自带 Key 时，音频直接发给你选的模型厂商，不经过作者的服务器
- 试用期走作者的代理服务器，只转发、不保存音频和文本
- 历史记录在本机加密存储

完整隐私政策：[typefree.app/privacy](https://typefree.app/privacy.html)

## 许可与商标

代码以 [GNU GPL-3.0](LICENSE) 开源：你可以自由使用、修改、再分发，但基于它的软件也必须以 GPL 开源。

**「Typefree」名称、图标与官网内容不在开源许可范围内**，请勿用于你自己发布的版本，以免用户混淆。

## 参与

- 欢迎提 [Issue](https://github.com/kdsz001/typefree/issues)：bug、想法、识别不准的例子都行
- Pull Request 目前只接受小修（错字、明确的 bug、兼容性）。见 [CONTRIBUTING.md](CONTRIBUTING.md)

---

## English

Typefree is a voice-input app for macOS: hold a hotkey, speak, release — the text is cleaned up by an LLM (filler words removed, punctuation and paragraphs added) and typed into whatever app you're in. It also answers questions on long-press, translates to English on command, and learns your vocabulary.

Bring your own API key (Volcengine for ASR, Qwen for polishing) and it's free with no limits. The signed build from [typefree.app](https://typefree.app) includes a 7-day zero-config trial; builds from this repo don't (the trial server address is not in the repo).

Build: macOS 14.0+, Xcode 26.3 — `cd mac && ./build.sh`. Licensed under GPL-3.0; the Typefree name, icon and website are not covered by the license.
