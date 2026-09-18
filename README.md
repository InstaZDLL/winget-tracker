# WinGet Tracker

WinGet Tracker 是一个自动化工具，用于监控软件包更新并自动向 Microsoft 的 [winget-pkgs](https://github.com/microsoft/winget-pkgs) 仓库提交更新请求。

## 功能特性

- **自动版本检测**：定期检查已配置软件包的新版本
- **智能更新机制**：根据配置的规则从官方源获取最新版本信息
- **哈希计算**：自动下载安装包并计算 SHA256 哈希值
- **重复 PR 检查**：避免重复提交相同的版本更新
- **自动提交**：使用 `Komac` 工具自动向 winget-pkgs 提交 PR
- **日志记录**：完整的操作日志便于追踪和调试

## 项目结构

```
winget-tracker/
├── .github/workflows/     # GitHub Actions 工作流配置
├── packages/               # 软件包配置文件目录
└── scripts/                # PowerShell 脚本目录
```

## 脚本说明

| 脚本 | 功能 |
|------|------|
| `check-version.ps1` | 主脚本：检查所有包的新版本，并行处理 |
| `submit-winget.ps1` | 主脚本：提交更新到 winget-pkgs（使用 komac） |
| `resolve-version.ps1` | 解析远程版本号（GitHub/API/Web三种模式） |
| `resolve-download.ps1` | 解析下载 URL，支持变量替换、jsonpath 提取、match_url 匹配 |
| `calc-hash.ps1` | 下载文件并计算 SHA256（带重试） |
| `check-existing-pr.ps1` | 检查 winget-pkgs 是否已存在 PR |
| `get-installer-version.ps1` | 从 EXE/MSI/MSIX 提取内置版本号 |
| `infer-version-from-filename.ps1` | 从 URL 文件名推断版本号 |
| `scan-url-version.ps1` | 从 HTML 中所有 URL 扫描版本 |
| `cleanup-merged-prs.ps1` | 清理已合并的 PR 分支（使用 komac） |
| `sync-winget-fork.ps1` | 将 fork 的 winget-pkgs 仓库主分支同步到上游 microsoft/winget-pkgs |
| `validate-config.ps1` | 验证配置文件格式 |

## 本地使用说明

### 必需工具
1. **PowerShell 7+** - 脚本运行环境
2. **powershell-yaml 模块** - 用于解析 YAML 配置
   ```powershell
   Install-Module powershell-yaml -Scope CurrentUser -Force
   ```
3. **Komac** - 用于提交 winget-pkgs PR
   ```powershell
   winget install RussellBanks.Komac --source winget
   ```
4. **GitHub CLI (gh)** - 用于 PR 搜索和标题更新
   ```powershell
   winget install GitHub.cli --source winget
   ```

### 环境变量
- `WINGET_TOKEN`: GitHub Personal Access Token（需要 public_repo 权限）

### 使用方法

#### 1. 设置环境变量
```powershell
$env:WINGET_TOKEN="your_github_personal_access_token"
```

#### 2. 运行版本检查
```powershell
.\scripts\check-version.ps1
```
遍历 `packages/` 目录，检查远程版本，发现更新时写入 `updates.json`。

#### 3. 提交更新
```powershell
.\scripts\submit-winget.ps1
```
读取 `updates.json`，检查 PR 存在性，下载并计算哈希，从安装包提取版本，使用 Komac 提交 PR，更新 YAML 配置并自动 Git 提交。

## GitHub Actions 自动化使用说明

项目包含 GitHub Actions 工作流，Fork 本仓库后，在 Action 中手动执行一次后，后续即可自动运行：

- **触发方式**：根据 cron 表达式自动运行，或手动触发 (`workflow_dispatch`)
- **所需 Secrets**：`WINGET_TOKEN`（GitHub Personal Access Token，需要对自己 Fork 的 winget-pkgs 仓库有写权限）
- 工作流开始时会自动将你 Fork 的 winget-pkgs 仓库主分支与上游 microsoft/winget-pkgs 同步（见 `scripts/sync-winget-fork.ps1`），一般无需再去手动同步

## 工作流程

### 完整工作流程
```
┌──────────────────┐
│ packages/*.yaml  │ 配置文件（包含 checkver 和 autoupdate 规则）
└────────┬─────────┘
         │
         ▼
┌──────────────────────┐
│ check-version.ps1    │ 1. 解析 checkver 配置
│                      │ 2. 检查远程版本（GitHub/API/Web）
│                      │ 3. 比较版本号
│                      │ 4. 生成 updates.json（包含更新列表）
└────────┬─────────────┘
         │
         ▼
┌──────────────────┐
│  updates.json    │ 中间文件格式：
│                  │ {
│                  │   "id": "Publisher.AppName",
│                  │   "version": "1.2.3",        # 用于 manifest
│                  │   "url_version": "1.2.3.456", # 原始版本
│                  │   "file": "Publisher.AppName.yaml"
│                  │ }
└────────┬─────────┘
         │
         ▼
┌──────────────────────┐
│ submit-winget.ps1    │ 1. 读取 updates.json
│                      │ 2. 检查 PR 是否已存在
│                      │ 3. 解析 autoupdate 规则生成下载 URL
│                      │ 4.下载安装包并计算哈希
│                      │ 5. 从安装包提取内置版本
│                      │ 6. 根据 version_format 配置使用 Komac 提交 PR
│                      │ 7. 更新 YAML 配置并 Git 提交
└──────────────────────┘
```

## 版本检查模式

### 1. GitHub Releases
```yaml
checkver:
  url: https://github.com/owner/repo
```
自动调用 GitHub API 获取最新 release。

### 2. Web 网页（正则匹配）
```yaml
checkver:
  url: https://example.com/download
  regex: Version ([\d.]+)
```
从 HTML 中用正则表达式提取版本号。

### 3. API 请求（JSON 解析）
```yaml
checkver:
  url: https://api.example.com/v1/version
  method: GET
  jsonpath: data.list.app_version
  exclude_pattern: "99"  # 可选，排除匹配的版本
```
从 JSON API 响应提取版本号。


## 版本号变量

### 基本变量
| 变量 | 说明 |
|------|------|
| `$version` | 完整版本号 |
| `$major` | 主版本号 |
| `$minor` | 次版本号 |
| `$patch` | 修订版本号 |
| `$build` | 构建号 |

### URL 原始版本变量 ($url*)
用于区分原始版本和格式化版本，支持全小写和驼峰式两种格式（`$urlversion` 或 `$urlVersion`）。

### 安装包版本变量 ($pkg*)
从安装包提取的版本，支持全小写和驼峰式两种格式（`$pkgversion` 或 `$pkgVersion`）。

## 完整配置文件格式

每个软件包需要一个 YAML 配置文件，放置在 `packages/` 目录下：

```yaml
id: Publisher.AppName
current_package:
  version: "1.0.0"
  architecture:
    x64:
      url: https://example.com/app-1.0.0-x64.exe
      hash: "SHA256_HASH"
checkver:
  url: https://example.com/releases
  regex: Version ([\d.]+)
autoupdate:
  version_format: $pkgMajor.$pkgMinor.$pkgPatch  # 可选，用于格式化 manifest 版本
  architecture:
    # 方式1: URL 模板（纯字符串，支持 $version 等变量替换）
    x64: https://example.com/app-$version-x64.exe
    # 方式2: jsonpath（从 API JSON 提取 URL）
    # x86:
    #   jsonpath: data.list.url
    # 方式3: match_url（从 GitHub Release assets 按文件名匹配）🆕
    # arm64:
    #   match_url: win-arm64
```

> **注意**: `match_url` 依赖 GitHub API 返回的 assets 数据，因此 `checkver.url` 必须是 GitHub 仓库地址（`https://github.com/owner/repo`），不能是其他 URL。

### 主要配置字段

| 字段 | 说明 |
|------|------|
| `id` | Winget 包标识符（格式：Publisher.AppName） |
| `current_package.version` | 当前已知的最新版本 |
| `current_package.architecture` | 支持的架构及对应的下载信息，会自动更新 |
| `checkver.url` | [GitHub/API/Web] 版本检查的目标 URL |
| `checkver.regex` | [GitHub/API/Web] 从页面提取版本的正则表达式 |
| `checkver.method` | [API] HTTP 请求方法（GET/POST/PUT，默认 GET） |
| `checkver.headers` | [API] 自定义 HTTP 请求头 |
| `checkver.body` | [API] POST/PUT 请求体 |
| `checkver.jsonpath` | [API] 从 JSON 响应提取版本的路径，支持遍历数组 |
| `checkver.exclude_pattern` | [API] 可选，排除匹配的版本 |
| `autoupdate.version_format` | 可选，自定义 manifest 版本的格式 |
| `autoupdate.architecture.[x86/x64/arm64]` | 自动更新的下载 URL 模板 |
| `autoupdate.architecture.[x86/x64/arm64].jsonpath` | [API] 可选，从 checkver 数据提取下载 URL，支持遍历数组 |
| `autoupdate.architecture.[x86/x64/arm64].match_url` | [GitHub] 可选，从 GitHub Release assets 按文件名正则匹配下载 URL |

## PR 提交说明

所有通过本工具提交的 PR 都会包含以下说明：

> Pull request has been created with [WinGet Tracker](https://github.com/leic4u/winget-tracker) 📦

## 许可证

MIT License
