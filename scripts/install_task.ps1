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
# 本次安装开始时间：刚重新注册时 Get-ScheduledTaskInfo 可能返回"已删除的旧任务"的缓存，
# 早于这个时间的"上次运行时间"一律不可信
$installStart = Get-Date

function Write-Install {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $installLog -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
}

function Get-InstallVerdict {
    <#
        根据注册后的任务状态与"下次运行时间"判断安装结果，供退出码与结论文案使用。
        纯函数：不读系统状态，便于 tests 用假数据回归（注册动作本身要管理员，测不了）。
        返回 @{ ExitCode = 0|2; Problems = @('...') }
          - 0: 任务 Ready 且下次运行时间在未来
          - 2: 已注册但需人工核对（状态非 Ready / 没有未来的下次运行时间 / 读不到信息）
    #>
    param(
        [string]$State,
        $NextRunTime = $null,
        [bool]$InfoAvailable = $true,
        [datetime]$Now = (Get-Date)
    )
    $problems = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($State)) {
        $problems.Add('读取不到任务（通常是没在管理员 PowerShell 里运行）')
    } elseif ($State -notin @('Ready', 'Running', 'Queued')) {
        # Running 是刚刚 Start-ScheduledTask 触发的测试运行，属正常，不能当失败
        $problems.Add("任务当前状态是 $State，不是 Ready/运行中（可能被禁用）")
    }

    if (-not $InfoAvailable) {
        $problems.Add('读不到任务运行信息（权限不足），无法确认触发器是否生效')
    } elseif (-not $NextRunTime -or $NextRunTime -le $Now) {
        $problems.Add('没有排定未来的下次运行时间，触发器未生效（"装上了但永不运行"）')
    }

    return @{
        ExitCode = if ($problems.Count -gt 0) { 2 } else { 0 }
        Problems = $problems
    }
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

Write-Install "任务计划 $taskName 已注册。"
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

# 结果判定：0=完全成功；2=已注册但需人工核对（触发器/状态异常）；1=注册失败（前面已 exit 1）
# ！！刚注册 + 刚触发测试运行时，任务计划服务要过几秒才重算排定时间，
#   直接读会拿到 NextRunTime=空（实测踩过：17:04 注册却读到"（无）"，其实任务正常）。
#   所以这里最多等 20 秒，等到未来时间就立刻继续，避免误报"触发器未生效"。
$info = $null
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    if ($info -and $info.NextRunTime -and $info.NextRunTime -gt (Get-Date)) { break }
    Start-Sleep -Seconds 2
}

$t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$state = if ($t) { [string]$t.State } else { '' }
if ($state -eq 'Running') {
    Write-Install "任务状态: Running（刚触发的测试运行正在执行，属正常）"
} elseif ($state) {
    Write-Install "任务状态: $state"
}

# 关键校验：下次运行时间必须是一个未来时间，否则说明触发器没生效（"装上了但永不运行"）
if ($info) {
    if ($info.NextRunTime -and $info.NextRunTime -gt (Get-Date)) {
        Write-Install "  下次运行时间: $($info.NextRunTime)"
        Write-Install "  触发器生效，任务已排定在 $($info.NextRunTime) 自动运行。"
    } else {
        Write-Install "  下次运行时间: （等待 20s 仍未刷新）"
    }
    # 只有本次安装之后的运行时间才可信（刚注册时可能读到已删除旧任务的缓存值）
    if ($info.LastRunTime -and $info.LastRunTime -ge $installStart) {
        Write-Install "  上次运行时间: $($info.LastRunTime)（结果码: $($info.LastTaskResult)）"
    } else {
        Write-Install "  上次运行时间: （暂无本次安装后的执行记录）"
    }
}

$verdict = Get-InstallVerdict -State $state -NextRunTime $(if ($info) { $info.NextRunTime } else { $null }) -InfoAvailable ([bool]$info)
$exitCode = $verdict.ExitCode
$problems = $verdict.Problems

if ($problems.Count -gt 0) {
    $exitCode = 2
    Write-Install "===== 结论: 任务已注册，但需人工核对 $($problems.Count) 项 ====="
    foreach ($p in $problems) { Write-Install "  ! $p" }
    # 每行单独输出且保持短：控制台重定向时会按窗口宽度硬换行，长中文行会被截断成乱码
    Write-Install "处理建议:"
    Write-Install "  1) 打开「任务计划程序」，找到 $taskName"
    Write-Install "  2) 「触发器」页签看是否有未来的下次运行时间"
    Write-Install "  3) 「常规」页签确认已勾选「启用」"
    Write-Install "  4) 核对完重跑本脚本，结论应变为「安装成功」"
} else {
    Write-Install "===== 结论: 安装成功，任务已启用并每分钟自动运行 ====="
    Write-Install "下一步: 等 1~2 分钟，用下面命令确认脚本真的在跑："
    Write-Install "  Get-Content $(Join-Path $projectRoot 'logs\auto_login.log') -Tail 20"
}
Write-Install "安装日志: $installLog"
Write-Install "运行日志: $(Join-Path $projectRoot 'logs\auto_login.log')"
exit $exitCode
