# playwright 桩包（stub）

## 为什么需要它

Octop 的依赖里有 `playwright>=1.40`。而 Playwright：

- PyPI 上**只有 `manylinux`（glibc）wheel**，没有 musllinux；
- 它的 browser driver 是**打包进 wheel 的 Node.js 二进制**，同样是 glibc 链接；
- 因此即便强行装进去，运行时也会因为 glibc 缺失而崩。

但 Octop 对 playwright 是**惰性导入**的 —— 只有真的要用浏览器自动化时才加载。
所以在这类设备上，只要让「导入」不报错，其余功能就能正常工作。

桩包就是干这个的：**导入通过，真调用才报错。**

## 设计要点（踩过的三个坑）

| 坑 | 现象 | 正确做法 |
|---|---|---|
| **版本号太低** | `ERROR: Could not find a version that satisfies the requirement playwright>=1.40` | 桩包版本必须 **≥ 下游要求的最低版本**，这里用 `1.99.0` |
| **用模块级 `__getattr__` 抛异常** | 连 `from playwright.sync_api import sync_playwright` 都过不去，因为 `__getattr__` 会拦掉所有属性访问 | 不要用模块级 `__getattr__` 抛错；改用**可导入的占位对象** |
| **导入即抛错** | 上游只要 `import playwright` 探测是否存在就崩 | 只在**真正调用**（`__call__`）时才 `raise ImportError` |

所以最终形态是：`sync_playwright` / `async_playwright` 是可导入的 `_StubEntryPoint` 实例，
`repr` 正常、能被 `find_spec` 找到，只有你 `sync_playwright()` 调用它时才报错。

## 用法

在设备（或任意机器）上构建 wheel：

```sh
sh build.sh                 # 产物在 dist/
```

`install.sh` 会自动使用 `prebuilt/` 里或 wheelhouse 中的 `playwright-*.whl`，
通常你不需要手动构建。

## 影响范围

- ✅ Octop 能正常启动，依赖检查通过
- ❌ **浏览器自动化功能不可用**（`harness_browser` 的网页操作会报明确错误）
- 其余能力（微信/QQ 通道、命令执行、知识库、模型对话等）不受影响

如果你确实需要浏览器自动化，得换 glibc 设备或改用 Docker 部署。
