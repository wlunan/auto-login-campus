#requires -Version 5.1
<#
.SYNOPSIS
    回归测试：验证 install_task.ps1 的 Get-InstallVerdict 判定逻辑。
.DESCRIPTION
    安装动作本身必须管理员，无法在测试里跑；但"装完算不算成功"的判定是纯函数，
    用假数据回归即可覆盖三种结果（0=成功 / 2=需人工核对），避免出现
    "触发器没生效却报 Install OK" 这类假成功。
.USAGE
    powershell -ExecutionPolicy Bypass -File scripts\tests\test_install_verdict.ps1
#>

$scriptPath = Join-Path $PSScriptRoot '..\install_task.ps1'

$tokens = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$err)
if ($err -and $err.Count -gt 0) {
    Write-Host '脚本语法错误，无法测试:' -ForegroundColor Red
    $err | ForEach-Object { Write-Host $_.Message }
    exit 1
}
# 只执行函数定义，不执行"管理员检查 / 注册任务"等顶层代码
$funcAsts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcAsts) { Invoke-Expression $f.Extent.Text }
Write-Host "已从 install_task.ps1 加载 $($funcAsts.Count) 个函数（与正式版同源码）"

$pass = 0; $fail = 0
function Check {
    param([string]$Name, [bool]$Cond)
    if ($Cond) { $script:pass++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "[FAIL] $Name" -ForegroundColor Red }
}

$now = Get-Date '2026-10-24 12:00:00'

# 用例1：状态 Ready + 未来的下次运行时间 → 成功
$v1 = Get-InstallVerdict -State 'Ready' -NextRunTime $now.AddMinutes(1) -InfoAvailable $true -Now $now
Check "Ready+未来运行时间 → ExitCode=0 (实际: $($v1.ExitCode))" ($v1.ExitCode -eq 0)
Check "Ready+未来运行时间 → 无问题项 (实际: $($v1.Problems.Count))" ($v1.Problems.Count -eq 0)

# 用例1b：刚触发测试运行时状态是 Running，属正常，不能判成失败
$v1b = Get-InstallVerdict -State 'Running' -NextRunTime $now.AddMinutes(1) -InfoAvailable $true -Now $now
Check "Running+未来运行时间 → ExitCode=0 (实际: $($v1b.ExitCode))" ($v1b.ExitCode -eq 0)

# 用例2：没有下次运行时间（触发器未生效）→ 2，且必须报触发器问题
$v2 = Get-InstallVerdict -State 'Ready' -NextRunTime $null -InfoAvailable $true -Now $now
Check "Ready+无下次运行时间 → ExitCode=2 (实际: $($v2.ExitCode))" ($v2.ExitCode -eq 2)
Check '无下次运行时间 → 问题项提到触发器' ([bool]($v2.Problems -match '触发器'))

# 用例3：下次运行时间已过期 → 2
$v3 = Get-InstallVerdict -State 'Ready' -NextRunTime $now.AddMinutes(-5) -InfoAvailable $true -Now $now
Check "Ready+过期运行时间 → ExitCode=2 (实际: $($v3.ExitCode))" ($v3.ExitCode -eq 2)

# 用例4：任务被禁用 → 2，且问题项要说出状态
$v4 = Get-InstallVerdict -State 'Disabled' -NextRunTime $now.AddMinutes(1) -InfoAvailable $true -Now $now
Check "Disabled → ExitCode=2 (实际: $($v4.ExitCode))" ($v4.ExitCode -eq 2)
Check 'Disabled → 问题项包含 Disabled' ([bool]($v4.Problems -match 'Disabled'))

# 用例5：读不到任务（非管理员 / 任务不存在）→ 2
$v5 = Get-InstallVerdict -State '' -NextRunTime $null -InfoAvailable $false -Now $now
Check "读不到任务 → ExitCode=2 (实际: $($v5.ExitCode))" ($v5.ExitCode -eq 2)
Check '读不到任务 → 问题项提到管理员' ([bool]($v5.Problems -match '管理员'))

# 用例6：任务 Ready 但读不到运行信息 → 2（无法确认触发器，不能算成功）
$v6 = Get-InstallVerdict -State 'Ready' -NextRunTime $null -InfoAvailable $false -Now $now
Check "Ready+读不到运行信息 → ExitCode=2 (实际: $($v6.ExitCode))" ($v6.ExitCode -eq 2)
Check '读不到运行信息 → 问题项提到权限' ([bool]($v6.Problems -match '权限'))

# 用例7：问题项是列表，可枚举（主流程会逐条打印）
Check 'Problems 可枚举且元素为字符串' (($v5.Problems | ForEach-Object { $_ -is [string] }) -notcontains $false)

Write-Host "`n===== 结果: $pass 通过, $fail 失败 ====="
if ($fail -gt 0) { exit 1 } else { exit 0 }
