#requires -Version 5.1
<#
.SYNOPSIS
    卸载 Windows 任务计划 CampusAutoLogin（回滚用）。
#>
$taskName = 'CampusAutoLogin'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "已删除任务计划 $taskName" -ForegroundColor Green
} else {
    Write-Host "任务计划 $taskName 不存在，无需卸载。" -ForegroundColor Yellow
}
Write-Host "注意：脚本文件和日志仍保留在项目目录中，可手动删除。" -ForegroundColor Gray
