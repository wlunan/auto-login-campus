# 提权实验：以 SYSTEM 上下文运行认证脚本，验证执行与日志写入
$out = 'E:\06DateClass\20261017-自动连接校园网\logs\admin_probe.txt'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("===== Probe: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====")
[void]$sb.AppendLine("Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)")
[void]$sb.AppendLine("TEMP: $env:TEMP")

# 1. 测试 E:\ 盘写权限（SYSTEM 上下文）
try {
    $testFile = 'E:\06DateClass\20261017-自动连接校园网\logs\_probe_write_test.txt'
    [System.IO.File]::WriteAllText($testFile, 'ok', (New-Object System.Text.UTF8Encoding($true)))
    [void]$sb.AppendLine("E盘写入测试: OK")
} catch {
    [void]$sb.AppendLine("E盘写入测试: FAIL - $($_.Exception.Message)")
}

# 2. 运行认证脚本（SYSTEM 上下文）
$script = 'E:\06DateClass\20261017-自动连接校园网\scripts\auto_login.ps1'
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-NonInteractive','-File',$script) -Wait -PassThru
[void]$sb.AppendLine("auto_login.ps1 退出码: $($p.ExitCode)")

# 3. 检查日志尾部
$log = 'E:\06DateClass\20261017-自动连接校园网\logs\auto_login.log'
if (Test-Path $log) {
    $tail = Get-Content $log -Tail 3
    [void]$sb.AppendLine("日志最新3行:")
    foreach ($l in $tail) { [void]$sb.AppendLine("  $l") }
} else {
    [void]$sb.AppendLine("日志文件不存在!")
}

[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
