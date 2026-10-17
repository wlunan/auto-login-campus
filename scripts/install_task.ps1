#requires -Version 5.1
<#
.SYNOPSIS
    安装 Windows 任务计划：开机自启 + 每 1 分钟保活检测校园网认证。
.DESCRIPTION
    以 SYSTEM 权限运行，不依赖用户登录。
    可重复执行（已存在同名任务会先删除再重建）。
#>

$ErrorActionPreference = 'Stop'

$taskName = 'CampusAutoLogin'
$scriptDir = $PSScriptRoot
$mainScript = Join-Path $scriptDir 'auto_login.ps1'
$workDir = $scriptDir
$installLog = Join-Path (Split-Path $scriptDir -Parent) 'logs\install_task.log'

function Write-Install {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $installLog -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
}

# 前置检查：注册 SYSTEM 任务必须管理员，否则只会拿到 access denied 原始报错
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '需要管理员权限。请右键「以管理员身份运行」PowerShell 后再执行本脚本，' -ForegroundColor Red
    Write-Host '或直接双击 scripts\run_install_admin.bat（会自动提权）。' -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path -LiteralPath $mainScript)) {
    Write-Install "找不到主脚本: $mainScript"
    exit 1
}

# 如果任务已存在，先删除
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Install "发现已存在的任务 $taskName，先删除..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# 触发器：开机启动延迟 30 秒，之后每 1 分钟重复（不设 Duration = 无限）
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT30S'
$repTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
$trigger.Repetition = $repTrigger.Repetition

# 操作：隐藏窗口运行 PowerShell 脚本
$argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$mainScript`""
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $argLine `
    -WorkingDirectory $workDir

# 设置：SYSTEM 权限、最高权限、不 batter 提示、电源插电时也跑
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description '河南师大校园网(HTU_Student)断网自动重认证保活，每1分钟检测，SYSTEM权限运行' | Out-Null

Write-Install "任务计划 $taskName 安装完成。"
Write-Install "  - 触发：开机后 30 秒开始，每 1 分钟执行一次"
Write-Install "  - 权限：SYSTEM（不依赖用户登录）"
Write-Install "  - 脚本：$mainScript"
Write-Install "立即测试运行一次..."
try {
    Start-ScheduledTask -TaskName $taskName
    Write-Install "已触发测试运行。"
} catch {
    Write-Install "触发测试运行失败: $($_.Exception.Message)"
}
Start-Sleep -Seconds 3
$t = Get-ScheduledTask -TaskName $taskName
Write-Install "任务状态: $($t.State)"
Write-Install "查看日志: $workDir\..\logs\auto_login.log"
