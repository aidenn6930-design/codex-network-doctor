# Codex Network Doctor

独立的社区 Windows 网络诊断工具，**与 OpenAI 没有关联，也未经 OpenAI 认可**。它帮助定位代理环境不一致、监听端口、HTTPS 和 WebSocket 问题，不保证修复所有 Codex 错误。

理念：**先诊断、说明依据、安全修复、修后验证。** 0.1.0 面向 Windows 10/11、Windows PowerShell 5.1 与 PowerShell 7。本机实际验证环境为 Windows 11、PowerShell 5.1 与 7.6.5；Windows 10 尚未验证。

## 背景与功能

浏览器能访问 ChatGPT，并不证明 Codex Desktop、CLI 和后台进程使用相同代理。一个匿名 Windows 11 案例中，本地代理正常，但用户级 `HTTP_PROXY`、`HTTPS_PROXY` 一度消失。补齐变量后 CLI 检查通过，桌面窗口却仍报工作区错误：直连 HTTPS 超时，而代理路径及 CLI Doctor 通过。只给桌面应用传入代理启动参数后，观察到窗口恢复，无须启用 Windows 系统代理。HTTP 432 和工作区路由错误也可能有其他原因。

工具只读发现系统代理、WinHTTP、进程/用户/系统环境变量、本地监听、Codex 版本和进程。网络检查通过明确配置的本地代理进行，`curl.exe` 使用连接 5 秒、总计 12 秒超时。若 CLI 支持，会调用 `codex doctor --network-only` 并归纳 WebSocket 结果。报告提供证据、置信度和建议，支持脱敏 JSON。

## 安装与快速开始

从可信来源下载或克隆项目；诊断无需管理员权限。`curl.exe` 缺失时网络探测会报告不支持。不要绕过组织 PowerShell 执行策略。

```powershell
.\src\codex-doctor.ps1 diagnose
.\src\codex-doctor.ps1 diagnose -Detailed
.\src\codex-doctor.ps1 diagnose -Json
.\src\codex-doctor.ps1 diagnose -SkipNetwork
.\src\codex-doctor.ps1 diagnose -CheckDesktopPath
```

退出码：`0` 无错误或警告；`1` 警告；`2` 错误；`3` 命令失败。JSON 不包含代理凭据、原始 `NO_PROXY`、原始 `CODEX_CLI_PATH` 或 Codex Doctor 原始输出。

## 桌面窗口的网络路径

若桌面窗口显示“Couldn't load workspace settings”，但 CLI 检查通过，可运行 `diagnose -CheckDesktopPath`。此可选检查用 `curl.exe --noproxy '*'` 对比直连 HTTPS 与本地代理路径，均有超时限制。`DESKTOP_PROXY_ROUTE_GAP` 表示两条路径结果不同；还需核对应用日志才能确认桌面请求的实际路由。

专用启动器读取当前用户一致的 `HTTP_PROXY`、`HTTPS_PROXY`，没有写死端口。也可用 `-ProxyUrl` 明确指定无凭据的本地 HTTP 代理。先预览、正常退出 Codex，再通过脚本启动。脚本不会改变 Windows 系统代理。它使用 Electron 的 [`--proxy-server` 参数](https://www.electronjs.org/docs/latest/api/command-line-switches)；重启后应核对新进程参数及应用日志。

```powershell
.\src\Start-CodexWithProxy.ps1 -Preview
.\src\Start-CodexWithProxy.ps1 -ProxyUrl http://127.0.0.1:7892 -Preview
.\src\Start-CodexWithProxy.ps1
```

也可双击根目录的 `Start-Codex-With-Proxy.cmd`，或自行创建指向它的桌面快捷方式；原始应用图标不会自动带上专用代理参数。

## 修复与回滚

先运行诊断。`repair` 会重新检查问题、验证明确配置的本地 HTTP 代理端口、通过代理访问 ChatGPT HTTPS，并显示要修改的用户级变量。多个候选必须用 `-Candidate` 指定序号。输入 `YES` 后才修改；仅涉及用户级 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY`。原始设置使用当前 Windows 用户 DPAPI 加密备份。运行中的进程不会自动更新环境变量，必要时有序关闭并重开 Codex，某些启动器可能需要注销或重启 Windows。

```powershell
.\src\codex-doctor.ps1 repair
.\src\codex-doctor.ps1 repair -Candidate 1
.\src\codex-doctor.ps1 rollback -Backup .\backups\backup-YYYYMMDD-HHMMSS-<id>.cndb
```

回滚恢复原值和变量原先是否存在。若回滚会删除变量，脚本会明确列出；若发现备份之后有新修改，会警告并额外要求输入 `OVERWRITE`。回滚前还会备份当前状态。修复写入验证成功后，即使后续诊断失败，也不会撤销修复。加密备份通常只能由原用户在本机解密。

## 常见问题与限制

- 浏览器正常而 Codex 异常：检查不同进程所继承的代理变量，并运行 Codex 自带网络诊断。
- HTTP 403、432：单个状态码无法证明根因是代理。保留发生时间与脱敏错误类别，检查认证及服务端状态。
- WebSocket 检查不可用：旧版 CLI 可能不支持 `doctor --network-only`，工具会明确报告不支持。
- ChatGPT 首页 HTTP 200：只证明这一条 HTTPS 路径可用。
- 失效的 `CODEX_CLI_PATH`：工具只提示，不自动删除。
- CLI 未找到：工具会检查 PATH 和已安装的 Codex Desktop 自带 CLI；桌面版自带 CLI 不必出现在持久的用户 PATH 中。
- 其他运行中进程的环境变量：工具无法安全通用地读取，报告仅展示当前 shell 环境。

## 测试、监测与贡献

```powershell
Invoke-Pester .\tests -PassThru
```

测试使用模拟数据，不依赖 OpenAI 在线服务，也不改系统代理变量。可选的登录后一次性只读检查见 [监测方案](docs/monitoring.md)，项目不会自动创建任务。参见 [架构](docs/architecture.md)、[安全模型](docs/security-model.md)、[故障排查](docs/troubleshooting.md) 和 [贡献指南](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

MIT 许可见 [LICENSE](LICENSE)。软件按现状提供，修复前请检查计划并保留备份。
