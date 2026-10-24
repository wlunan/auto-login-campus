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
$projectRoot = Split-Path $scriptDir -Parent
$installLog = Join-Path $projectRoot 'logs\install_task.log'

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

# 触发器（两个）：
#   1) 主触发器 -Once：立即开始 + 每 1 分钟重复（无限）。
#      ！！不要写 -RepetitionDuration ([TimeSpan]::MaxValue)：PS 5.1 会把它序列化成
#      P99999999DT23H59M59S，Task Scheduler 判定超出范围，Register-ScheduledTask
#      直接报 0x80041318（XML 值格式错误或超出范围），任务根本注册不上。
#      不传 Duration 时生成的 XML 里没有 <Duration> 节点，才是真正的"无限重复"。
#      不能只靠 -AtStartup：它的重复要等"开机事件"发生后才开始计时，
#      任务在开机之后注册时，本次开机内永远不会触发（实际踩过：任务一直不自动执行，下次运行时间始终为空）。
#   2) -AtStartup：重启后 30 秒补一次，让开机场景更快恢复。
$onceTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) `
    -RepetitionInterval (New-TimeSpan -Minutes 1)

$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT30S'
$bootTrigger.Repetition = $onceTrigger.Repetition

# 操作：隐藏窗口运行 PowerShell 脚本
$argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$mainScript`""
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $argLine `
    -WorkingDirectory $workDir

# 设置：SYSTEM 权限、最高权限、不 batter 提示、电源插电时也跑
# ！！不要加 -RunOnlyIfNetworkAvailable：完全断网（WiFi 没连上）时该条件不成立，
#   任务压根不会启动，脚本里的"扫描并自动连接 WiFi"逻辑就永远没机会执行。
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

try {
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger @($onceTrigger, $bootTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description '河南师大校园网(HTU_Student)断网自动重认证保活，每1分钟检测，SYSTEM权限运行' | Out-Null
} catch {
    # 注册失败必须停下：否则后面 Start/Get-ScheduledTask 全是"找不到任务"的连环报错，掩盖真正原因
    Write-Install "注册任务失败: $($_.Exception.Message)"
    Write-Install "  - 0x80041318 = 任务 XML 值越界（如重复时长设为 MaxValue）"
    Write-Install "  - 0x80070005 = 权限不足，请用管理员 PowerShell 运行"
    exit 1
}

Write-Install "任务计划 $taskName 安装完成。"
Write-Install "  - 触发：立即开始 + 每 1 分钟执行一次；重启后 30 秒继续"
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
$t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($t) {
    Write-Install "任务状态: $($t.State)"
} else {
    Write-Install "读取任务状态失败（可能权限不足），请手动在任务计划程序中核对。"
}

# 关键校验：下次运行时间必须是一个未来时间，否则说明触发器没生效
$info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
if ($info) {
    Write-Install "  下次运行时间: $($info.NextRunTime)"
    Write-Install "  上次运行时间: $($info.LastRunTime)（结果: $($info.LastTaskResult)）"
    if (-not $info.NextRunTime -or $info.NextRunTime -le (Get-Date)) {
        Write-Install "警告：任务没有排定的下次运行时间，触发器未生效！请打开任务计划程序核对触发器设置。"
    } else {
        Write-Install "  触发器生效，任务已排定在 $($info.NextRunTime) 自动运行。"
    }
} else {
    Write-Install "无法读取任务信息（需要管理员权限），请手动核对任务计划程序中的「下次运行时间」。"
}
Write-Install "查看日志: $(Join-Path $projectRoot 'logs\auto_login.log')"
