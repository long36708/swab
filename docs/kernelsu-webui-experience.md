# KernelSU 模块 WebUI 开发经验总结

> 场景：给 swab 模块加一个图形界面（模块详情页可点击按钮切换 A/B 槽位、查看状态），
> 适配的是 **KernelSU-Next**（rifsxd/KernelSU-Next，dev 分支）。
>
> 关键结论：**KernelSU-Next 的 WebUI JS API 与官方 `kernelsu` 文档 / npm 包差异极大，不能照文档写。**

## 一、最终成果

- 模块内置 `module/webroot/`（`index.html` / `style.css` / `app.js`），KernelSU Manager 在模块详情页用 WebView 渲染。
- 界面功能：槽位状态查看、切换槽位（A/B/对位/重启）、结构体级 active/protect 操作、boot_ctrl dump、开机保护日志查看。
- 危险写 `misc` 分区操作均带二次确认。
- 按钮背后就是 `sh /data/adb/modules/<id>/swab.sh <参数>`，与命令行行为一致。

页面结构（`webroot/` 放模块根目录，非 `module/` 内再套一层）：

```
module/
├── module.prop
├── service.sh
├── skip_mount
└── webroot/
    ├── index.html
    ├── style.css
    └── app.js
```

## 二、踩过的坑（按出现顺序）

### 1. 用 `import { exec } from 'kernelsu'` —— 整个脚本静默加载失败

官方文档示例是 `import { exec } from 'kernelsu'`（npm 包），但 WebView 里**没有这个裸模块名**，
`import` 无法解析 → 整个 `app.js` 模块加载失败 → 所有按钮事件没绑定。

**现象**：状态区永远停在 HTML 写死的"正在读取槽位状态…"，点刷新无反应（按钮是死的），且没有任何报错提示。

**修复**：去掉 `type="module"` 和 `import`，改用 Manager 注入的**全局对象 `window.ksu`**：

```html
<!-- index.html -->
<script src="app.js"></script>   <!-- 注意：不是 type="module" -->
```

```js
// app.js
const ksu = window.ksu;   // 由 addJavascriptInterface(WebViewInterface, "ksu") 注入
```

### 2. `moduleInfo()` 当成对象取 `.id` —— 路径变成 `/undefined/`

官方文档让 `moduleInfo()` 返回模块信息对象，但实际 KernelSU-Next 里它**返回 JSON 字符串**，
直接 `.id` 拿到 `undefined`，命令变成 `sh /data/adb/modules/undefined/swab.sh -s`。

**修复**：先 `JSON.parse`：

```js
const MOD_ID = (() => {
  try {
    const info = JSON.parse(ksu.moduleInfo());
    return info.id || (info.moduleDir ? info.moduleDir.split('/').pop() : 'swab_protect');
  } catch (_) {
    return 'swab_protect';   // 兜底默认模块 id
  }
})();
const SWAB = `/data/adb/modules/${MOD_ID}/swab.sh`;
```

### 3. `exec` 当成 Promise 解构 `{errno,stdout}` —— 解构 undefined 崩溃

这是最隐蔽的一处。KernelSU-Next 的 `exec` **不是返回 Promise**，形态有三种：

| 形态 | 签名 | 返回值 / 回调参数 |
| --- | --- | --- |
| 同步版 | `ksu.exec(cmd)` | 直接返回 **stdout 字符串**（无 errno/stdout 字段） |
| 回调版 | `ksu.exec(cmd, callbackFunc)` | `callbackFunc(code, stdout, stderr)`，`code` 即退出码 |
| 三参版 | `ksu.exec(cmd, options, callbackFunc)` | `options` 为 JSON 字符串 `{cwd, env}` 或 `null` |

我最初写的 `exec(cmd, 30000)` 把 30000 当 options 传，又期待返回 Promise，结果 `await undefined` 后
解构 `errno` → 报错 `Cannot destructure property 'errno' of '(intermediate value)' as it is undefined`。

**修复**：封装成统一返回 Promise 的 `ksuExec`，按 `ksu.exec.length` 自动区分形态：

```js
function ksuExec(cmd) {
  return new Promise((resolve, reject) => {
    if (!ksu) { reject(new Error('ksu API 不可用')); return; }
    // 回调式：把全局函数名传给 exec，WebView 内部 evaluateJavascript 调用它
    const cbName = '__ksuCb_' + Date.now() + '_' + Math.floor(Math.random() * 1e6);
    window[cbName] = (code, stdout, stderr) =>
      resolve({ errno: (code | 0), stdout: stdout || '', stderr: stderr || '' });
    try {
      const n = ksu.exec.length;
      if (n >= 3) ksu.exec(cmd, null, cbName);          // 三参版
      else if (n === 2) ksu.exec(cmd, cbName);          // 回调版
      else {
        delete window[cbName];
        resolve({ errno: 0, stdout: String(ksu.exec(cmd) || ''), stderr: '' });  // 同步版
      }
    } catch (e) {
      try { delete window[cbName]; } catch (_) {}
      reject(e);
    }
  });
}
```

回调式需注意：传给 `exec` 的回调必须是**挂在 `window` 上的全局函数名（字符串）**，不能传闭包，
因为 WebViewInterface 内部用 `webView.evaluateJavascript("${callback}(code, stdout, stderr)")` 调用。

## 三、确认 API 真相的方法（重要）

文档 (`kernelsu.org` / npm `kernelsu`) 与 KernelSU-Next 实际实现不一致，不要只信文档。
确认真实签名要直接读 Manager 源码：

- `WebUIActivity.kt`：确认 `addJavascriptInterface(interface, "ksu")` 注入的全局对象名。
- `WebViewInterface.kt`（`com/rifsxd/ksunext/ui/webui/`）：确认每个方法（`exec` / `moduleInfo` / `toast`）的真实签名。

不同 KernelSU 发行版（官方 KernelSU、KernelSU-Next、MKSU 等）接口可能各不相同，换发型前务必核对源码。

## 四、本地打包要点

GitHub Actions 用 `cd module && zip -r9 ../xxx.zip .`，产物根目录**直接是模块内容**，没有 `module/` 层。
本地用 PowerShell/Python 打包时容易多包一层 `module/`，导致安装后模块无法识别。

正确做法（Python `zipfile`，保留权限位）：

```python
arc = os.path.relpath(full, "module")   # 以 module/ 为基准，去掉这层目录
# 脚本类文件 external_attr = (0o100755 << 16)，其余 0o100644
```

- `service.sh` / `swab.sh` 需要 **0755** 可执行权限（Magisk/KSU 安装器对已知脚本名会 chmod，但显式设更稳）。
- `webroot/` 内文件只要能被 WebView 读取，0644 即可。
- Windows 的 `Compress-Archive` 不保留 Unix 权限位，不推荐直接用于模块打包。

## 五、其他注意

- WebUI 是 **KernelSU 独有机制**，Magisk 不支持（Magisk 模块没有 WebUI 界面）。命令行 `swab.sh` 用法两者通用。
- 写 `misc` 分区属于底层危险操作，UI 上务必加二次确认，避免误触变砖。
- 初始化调用要包一层 `if (ksu)` 判断，API 缺失时界面显示明确报错，而不是静默假死。
