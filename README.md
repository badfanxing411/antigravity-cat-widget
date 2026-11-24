# Antigravity 星猫额度挂件（Antigravity Cat Widget）

让一只傲娇的星空猫娘，陪你看 Antigravity（Gemini Models）的剩余额度。

**Windows 10 / 11 原生 WPF 轻量化桌面挂件 · 零 Electron 依赖 · 中文喵言喵语 · 当前版本 v1.0.0**

基于 GPT 龙娘额度挂件（Windows WPF + PowerShell + Node.js 单实例 Worker）的轻量化架构重新实现，所有进程锁、管道、数据目录与计划任务均与 GPT 娘完全隔离，**可与 GPT 龙娘同时运行互不冲突**。

---

## 快速安装（给新电脑部署）

### 环境要求
- **Windows 10 / 11**
- **Node.js 20 或更新版本**（未安装请先前往 [Node.js 官网](https://nodejs.org/) 下载 LTS 版）
- 已安装并登录的 **Antigravity 桌面端**

### 三步完成部署
1. 将本项目的完整文件夹解压或克隆到准备长期保留的位置（例如 `D:\Tools\AntigravityCatWidget`），**不要删除其中的子文件夹**。
2. 双击根目录的 **`安装星猫.cmd`**（无需管理员权限）：
   - 自动检测 Node.js 20+ 环境；
   - 自动注册无终端弹窗的开机自启与用户级守护任务；
   - 自动检测桌面上的 `Antigravity.lnk`，并询问是否一键添加 `--remote-debugging-port=0` 参数（**推荐按回车确认**，之后直接双击桌面 Antigravity 图标就能读取实时额度）。
3. 若 Antigravity 当前已打开，请**完全退出后重新打开**，星猫就会自动出现在 Antigravity 窗口右下角。

---

## 交互与操作

| 操作 | 效果 |
| --- | --- |
| **点击猫猫本体** | 弹出 **Gemini 剩余额度**（5 小时 / 每周进度条、倒计时自动切本机重置时间、手动刷新 `↻`）；在语录页点本体会切回额度 |
| **点击气泡** | **剩余额度 → 喵言喵语 → 收起气泡**（5 秒无操作也会自动收起） |
| **拖动猫猫** | 窗口内自由拖动、贴近左右边缘自动吸附并转向；桌面模式可跨屏自由拖动 |
| **右键猫猫 / 悬停菜单按钮** | 打开原生设置菜单（形象图库、人物/气泡独立缩放、音效、语录编辑、音乐律动、提醒与用量、显示位置） |
| **快速来回滑过猫猫** | 触发摸头互动反应与专属台词 |

> 默认情况下，**今日用量**与**最近模型步骤**不占用气泡轮播；可在右键菜单「**提醒与本机用量**」中随时单次查看，或勾选「气泡切换包含今日用量与最近步骤」加入轮播。

---

## 核心功能

- **实时只读额度查询**：通过本机 `127.0.0.1` 的 `DevToolsActivePort` 只读读取 `Gemini Models` 的 5 小时与每周额度，不发起模型请求、不上传凭据或对话内容；同时保留「手动额度记录」选项。
- **回复结束 & 审批等待提醒**：监听本机会话日志与审批状态，回复结束弹出 5 秒提醒，等待审批弹出 10 秒提醒；主窗口在后台时临时置顶提醒并自动恢复层级。
- **81 句内置喵言喵语 + 自定义编辑**：融合星猫原创台词与精选契合语录，支持 `3 | 语录` 权重语法、1/5/15 分钟自动语录及低频流光变色彩蛋。
- **猫娘表情彩蛋 & 本地角色图库**：内置「星猫 · 日常 / 得意 / 委屈」，默认日常形象下偶发得意/委屈表情彩蛋；支持导入任意 PNG/JPG/BMP/GIF 并支持移除与撤销。
- **4 套内置音色 + 自定义 WAV**：内置「气泡轻弹」「轻柔弹簧」「经典啾啾」「木质轻敲」，支持导入自定义 WAV（最长 5 秒）。
- **零延迟窗口跟随 & 音乐律动**：原生 WinEvent 跟随主窗口与遮挡隐身恢复，也可切为桌面自由模式与桌面置顶；支持系统播放音频节拍律动与甩出反弹。

---

## 根目录脚本说明

| 文件 | 用途 |
| --- | --- |
| `安装星猫.cmd` | 一键安装、注册无终端弹窗自启任务，并可顺手配置桌面 Antigravity 快捷方式 |
| `打开星猫.cmd` | 手动唤起星猫（重复点击不会叠加第二只） |
| `停用星猫.cmd` | 停止挂件并移除自启任务与启动快捷方式（保留程序文件与个人数据） |
| `配置桌面快捷方式.cmd` | 单独为桌面 `Antigravity.lnk` 添加 `--remote-debugging-port=0` 参数 |
| `启动Antigravity(含星猫额度).vbs` | 无黑框直接带本机调试参数启动 Antigravity 并唤醒星猫 |
| `检测额度.cmd` | 命令行检测当前 Antigravity 额度接口与本机日志读取状态 |
| `打包发布.cmd` | 一键生成可直接发给别人的纯净安装包（输出到 `dist/`，含 `SHA256SUMS.txt`） |

---

## 项目结构

```text
.
├── README.md
├── LICENSE / NOTICE.md / CHANGELOG.md
├── 安装星猫.cmd / 打开星猫.cmd / 停用星猫.cmd / 检测额度.cmd
├── 配置桌面快捷方式.cmd / 启动Antigravity(含星猫额度).vbs / 打包发布.cmd
├── scripts/
│   └── build-release.ps1            # 打包纯净分发 ZIP（自动排除本机 installation.json）
└── antigravity-cat-usage/
    ├── widget.ps1 / widget.xaml     # WPF 主界面与交互逻辑
    ├── Install.ps1 / Uninstall.ps1  # 安装 / 停用脚本
    ├── Configure-Shortcut.ps1       # 桌面快捷方式参数配置
    ├── Detect-Quota.ps1             # 额度命令行诊断
    ├── launch.vbs / supervisor.vbs  # 无终端弹窗启动入口（conhost --headless）
    ├── package.json
    ├── assets/                      # 角色图、81 句喵言喵语、表情台词、4 套 WAV 音效
    ├── runtime/                     # Node.js 额度/日志/审批后台 + PS1/C# 原生跟随与律动模块
    └── tests/                       # Node.js 单元测试与 Windows 完整验证脚本
```

---

## 分享给别人 & 开发验证

### 打包发给别人
双击 **`打包发布.cmd`**（或运行 `powershell -ExecutionPolicy Bypass -File .\scripts\build-release.ps1`），会在 `dist/` 目录生成：
- `antigravity-cat-widget-v1.0.0-windows.zip`（自动剔除你本机的 `installation.json` 等私有路径）
- `SHA256SUMS.txt`

把 ZIP 发给对方，对方解压后双击 **`安装星猫.cmd`** 即可使用。

### 运行自动化测试（无需安装任何 npm 依赖）

```powershell
cd antigravity-cat-usage
npm test
npm run test:windows
```

---

## 数据、隐私与彻底卸载

- 个人偏好、自定义语录、导入形象与额度快照保存在 `%LOCALAPPDATA%\AntigravityCatUsage\state`，不随项目目录打包，也不会上传至任何外部服务器。
- **移动目录**：先运行 `停用星猫.cmd`，移动文件夹后再重新运行 `安装星猫.cmd`（个人设置会自动保留）。
- **彻底卸载**：
  1. 运行 `停用星猫.cmd` 停止进程并移除自启任务；
  2. 删除程序目录；
  3. 如需清除个人配置，删除 `%LOCALAPPDATA%\AntigravityCatUsage`。

## 许可说明

代码与一般文档采用 [MIT License](LICENSE)；第三方组件、上游语录、音效与角色形象的使用边界详见 [NOTICE.md](NOTICE.md)。
