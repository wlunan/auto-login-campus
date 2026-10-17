# 查询任务最近运行历史
$out = 'E:\06DateClass\20261017-自动连接校园网\logs\admin_query2.txt'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("===== Task Info: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====")
$i = Get-ScheduledTaskInfo -TaskName 'CampusAutoLogin'
[void]$sb.AppendLine("LastRunTime=$($i.LastRunTime) LastTaskResult=$($i.LastTaskResult) NextRunTime=$($i.NextRunTime) MissedRuns=$($i.NumberOfMissedRuns)")
$t = Get-ScheduledTask -TaskName 'CampusAutoLogin'
[void]$sb.AppendLine("State=$($t.State)")
foreach ($tr in $t.Triggers) { [void]$sb.AppendLine("Trigger=$($tr.CimClass.CimClassName) Delay=$($tr.Delay) RepetitionInterval=$($tr.Repetition.Interval) RepetitionDuration=$($tr.Repetition.Duration)") }
# 事件日志里 CampusAutoLogin 的运行记录
try {
    $events = Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 200 -ErrorAction Stop | Where-Object { $_.Message -match 'CampusAutoLogin' }
    [void]$sb.AppendLine("===== 任务调度事件 =====")
    $events | Select-Object -First 15 | ForEach-Object {
        [void]$sb.AppendLine("$($_.TimeCreated) [ID $($_.Id)] $((($_.Message -split "`n")[0]) -replace '\s+',' ' )")
    }
} catch { [void]$sb.AppendLine("事件日志读取失败: $($_.Exception.Message)") }
[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
