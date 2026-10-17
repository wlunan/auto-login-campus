#requires -Version 5.1
<#
.SYNOPSIS
    校园网认证保活守护循环（启动文件夹版本）
.DESCRIPTION
    开机登录后由启动文件夹拉起，每 60 秒调用一次 auto_login.ps1。
    单实例互斥，避免重复启动。
    不需要管理员权限。
.NOTES
    等价于任务计划的"每1分钟"行为；任务计划装好后可停用本脚本。
#>

# 单实例互斥锁
$mutex = New-Object System.Threading.Mutex($false, 'Global\CampusAutoLoginKeepAlive')
if (-not $mutex.WaitOne(0)) {
    # 已有实例在运行
    exit 0
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$mainScript = Join-Path $scriptDir 'auto_login.ps1'
$logFile = Join-Path (Split-Path $scriptDir -Parent) 'logs\keepalive_loop.log'

function Write-LoopLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
}

try {
    Write-LoopLog "守护循环启动，每 60 秒检查一次。"
    $checkCount = 0
    while ($true) {
        $checkCount++
        try {
            $p = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-NonInteractive','-File',$mainScript) `
                -WindowStyle Hidden -Wait -ErrorAction Stop
        } catch {
            Write-LoopLog "调用 auto_login.ps1 失败: $($_.Exception.Message)"
        }
        # 每 10 次（约10分钟）写一条计数日志，方便确认循环活着
        if ($checkCount % 10 -eq 0) {
            Write-LoopLog "已完成 $checkCount 次检查（每60秒一次）。"
        }
        Start-Sleep -Seconds 60
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
