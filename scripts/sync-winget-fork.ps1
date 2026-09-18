# 将 fork 的 winget-pkgs 仓库主分支同步到上游 microsoft/winget-pkgs
#
# 用途：在 Action 开始时先消除 fork 与上游的差异，避免 komac 因 fork 落后于上游
#       而无法基于最新提交创建更新分支，导致后续流程失败。
# 逻辑：1. 调用 merge-upstream API 让 fork 主分支快进合并到上游
#       2. 若主分支已分叉（API 返回 409）或合并结果与上游不一致，则强制重置到上游最新提交
#       3. 轮询验证 fork 主分支已与上游一致
# 说明：失败时抛出异常（throw）以中断 Action，跳过场景（无 token / 无 fork）不视为失败

param(
    [string]$ForkOwner,
    [string]$Branch = "master",
    [string]$UpstreamRepo = "microsoft/winget-pkgs"
)

$ErrorActionPreference = "Stop"

if (-not $env:WINGET_TOKEN) {
    Write-Host "Warning: WINGET_TOKEN not set, skipping winget-pkgs fork sync" -ForegroundColor Yellow
    return
}

$headers = @{
    Authorization          = "Bearer $env:WINGET_TOKEN"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function Invoke-GitHubApi {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Body
    )

    $params = @{ Uri = $Uri; Method = $Method; Headers = $headers }
    if ($Body) {
        $params.Body = $Body | ConvertTo-Json -Compress
        $params.ContentType = "application/json"
    }

    return Invoke-RestMethod @params
}

function Get-BranchHeadSha {
    param(
        [string]$Repo,
        [string]$BranchName
    )

    return (Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repo/git/ref/heads/$BranchName").object.sha
}

function Wait-ForkInSync {
    param(
        [string]$Repo,
        [string]$BranchName,
        [string]$TargetSha,
        [int]$Attempts,
        [int]$IntervalSeconds
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        Start-Sleep -Seconds $IntervalSeconds
        $currentSha = Get-BranchHeadSha -Repo $Repo -BranchName $BranchName
        if ($currentSha -eq $TargetSha) {
            return $true
        }
        Write-Host "  Waiting for fork branch to update ($i/$Attempts): fork=$currentSha"
    }

    return $false
}

# 1. 确定 fork 所有者：默认为 token 所属账号（komac 使用的是同一账号下的 fork）
if (-not $ForkOwner) {
    $ForkOwner = (Invoke-GitHubApi -Uri "https://api.github.com/user").login
}
$forkRepo = "$ForkOwner/winget-pkgs"
Write-Host "Fork repository: $forkRepo (branch: $Branch)" -ForegroundColor Cyan

# 2. 确认 fork 主分支可访问；fork 不存在时跳过，交由 komac 自行处理
try {
    $forkSha = Get-BranchHeadSha -Repo $forkRepo -BranchName $Branch
} catch {
    Write-Host "Warning: Cannot access $forkRepo/$Branch, skipping fork sync" -ForegroundColor Yellow
    return
}

# 3. 获取上游主分支最新提交
$upstreamSha = Get-BranchHeadSha -Repo $UpstreamRepo -BranchName $Branch
Write-Host "Upstream $UpstreamRepo/$Branch is at $upstreamSha"

if ($forkSha -eq $upstreamSha) {
    Write-Host "Fork $forkRepo/$Branch is already up to date" -ForegroundColor Green
    return
}

Write-Host "Fork is out of sync with upstream (fork=$forkSha), syncing..." -ForegroundColor Cyan

# 4.1 优先使用 merge-upstream 快进合并（不会丢弃 fork 上的提交）
$merged = $false
try {
    $result = Invoke-GitHubApi -Method Post -Uri "https://api.github.com/repos/$forkRepo/merge-upstream" -Body @{ branch = $Branch }
    Write-Host "  merge-upstream: $($result.message)"
    $merged = $true
} catch {
    $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    if ($statusCode -eq 409) {
        # 409 表示 fork 主分支已分叉，无法快进合并
        Write-Host "  Fork branch has diverged from upstream (HTTP 409)" -ForegroundColor Yellow
    } else {
        Write-Host "  merge-upstream failed (HTTP $statusCode): $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host "  API response: $($_.ErrorDetails.Message)" -ForegroundColor Red
        }
        throw
    }
}

$inSync = $merged -and (Wait-ForkInSync -Repo $forkRepo -BranchName $Branch -TargetSha $upstreamSha -Attempts 3 -IntervalSeconds 3)

# 4.2 合并失败或结果与上游不一致时，强制将主分支重置到上游最新提交
if (-not $inSync) {
    Write-Host "  Force resetting $forkRepo/$Branch to upstream commit $upstreamSha..." -ForegroundColor Yellow
    Invoke-GitHubApi -Method Patch -Uri "https://api.github.com/repos/$forkRepo/git/refs/heads/$Branch" -Body @{ sha = $upstreamSha; force = $true } | Out-Null
    $inSync = Wait-ForkInSync -Repo $forkRepo -BranchName $Branch -TargetSha $upstreamSha -Attempts 6 -IntervalSeconds 5
}

if ($inSync) {
    Write-Host "Fork $forkRepo/$Branch is now in sync with upstream ($upstreamSha)" -ForegroundColor Green
} else {
    Write-Host "Warning: Fork $forkRepo/$Branch may still be out of sync with upstream" -ForegroundColor Yellow
}
