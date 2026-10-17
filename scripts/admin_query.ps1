$out = 'E:\06DateClass\20261017-自动连接校园网\logs\admin_query.txt'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("===== Task Detail =====")
$t = Get-ScheduledTask -TaskName 'CampusAutoLogin'
[void]$sb.AppendLine("TaskName=$($t.TaskName) State=$($t.State) Author=$($t.Author)")
[void]$sb.AppendLine("===== Run Info =====")
$i = Get-ScheduledTaskInfo -TaskName 'CampusAutoLogin'
[void]$sb.AppendLine("LastRunTime=$($i.LastRunTime) LastTaskResult=$($i.LastTaskResult) NextRunTime=$($i.NextRunTime) MissedRuns=$($i.NumberOfMissedRuns)")
[void]$sb.AppendLine("===== Trigger =====")
foreach ($tr in $t.Triggers) { [void]$sb.AppendLine("Type=$($tr.CimClass.CimClassName) Enabled=$($tr.Enabled) StartBoundary=$($tr.StartBoundary) Repetition=$($tr.Repetition) Delay=$($tr.Delay)") }
[void]$sb.AppendLine("===== Action =====")
foreach ($ac in $t.Actions) { [void]$sb.AppendLine("Execute=$($ac.Execute) Args=$($ac.Arguments) WorkDir=$($ac.WorkingDirectory)") }
[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
