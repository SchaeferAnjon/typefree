# 参与 Typefree

谢谢你愿意花时间。几条说明：

## 提 Issue

最有用的是「识别/润色不准」的真实例子：你说的话、识别出来的文字、期望的结果。功能想法、bug、崩溃也都欢迎。不用客气，中文英文都行。

## Pull Request

目前**只接受小修**：错字、明确的 bug、兼容性修复、文档。新功能请先开 Issue 讨论，别直接提大 PR——大概率会被放着。

原因说一下：作者需要保留对这份代码的完整版权，以便将来以其他许可分发（例如上架 Mac App Store）。所以大块的外部代码暂时不合并；提交小修即视为你同意作者可以以任何许可继续分发包含你改动的代码。

## 本地开发

```bash
cd mac
./build.sh                                  # 构建
bash scripts/install_app.sh && open /Applications/Typefree.app
cd VoicePolishCore && swift test            # 核心库测试
```

改润色提示词时请用真实用例对比效果，一次只改一处。
