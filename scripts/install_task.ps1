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

if (-not (Test-Path -LiteralPath $mainScript)) {
    Write-Host "找不到主脚本: $mainScript" -ForegroundColor Red
    exit 1
}

# 如果任务已存在，先删除
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "发现已存在的任务 $taskName，先删除..." -ForegroundColor Yellow
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

Write-Host "任务计划 $taskName 安装完成。" -ForegroundColor Green
Write-Host "  - 触发：开机后 30 秒开始，每 1 分钟执行一次" -ForegroundColor Gray
Write-Host "  - 权限：SYSTEM（不依赖用户登录）" -ForegroundColor Gray
Write-Host "  - 脚本：$mainScript" -ForegroundColor Gray
Write-Host ""
Write-Host "立即测试运行一次..." -ForegroundColor Cyan
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName, State | Format-List
Write-Host "查看日志: $workDir\..\logs\auto_login.log" -ForegroundColor Cyan
