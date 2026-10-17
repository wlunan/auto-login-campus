# 提权：清心跳 + 触发任务 + 验证日志全链路
$out = 'E:\06DateClass\20261017-自动连接校园网\logs\admin_trigger_test.txt'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("===== Trigger Test: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====")

# 1. 清理心跳文件（用户和 SYSTEM TEMP）
Remove-Item "$env:TEMP\campus_heartbeat.ts" -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\campus_heartbeat.ts' -Force -ErrorAction SilentlyContinue
[void]$sb.AppendLine("心跳文件已清理 (TEMP=$env:TEMP)")

# 2. 触发任务
try {
    Start-ScheduledTask -TaskName 'CampusAutoLogin'
    [void]$sb.AppendLine("任务已触发")
} catch {
    [void]$sb.AppendLine("触发失败: $($_.Exception.Message)")
}

# 3. 等待脚本运行
Start-Sleep -Seconds 10

# 4. 读日志尾部
$log = 'E:\06DateClass\20261017-自动连接校园网\logs\auto_login.log'
if (Test-Path $log) {
    [void]$sb.AppendLine("日志最新4行:")
    Get-Content $log -Tail 4 | ForEach-Object { [void]$sb.AppendLine("  $_") }
} else {
    [void]$sb.AppendLine("日志文件不存在!")
}

# 5. 任务运行信息
$i = Get-ScheduledTaskInfo -TaskName 'CampusAutoLogin' -ErrorAction SilentlyContinue
[void]$sb.AppendLine("LastRun=$($i.LastRunTime) Result=$($i.LastTaskResult) Next=$($i.NextRunTime)")

[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
