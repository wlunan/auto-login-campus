#requires -Version 5.1
<#
.SYNOPSIS
    回归测试：验证 auto_login.ps1 的 Http-Probe / Get-NetworkStatus 能识别
    深澜 BRAS 的两种劫持方式：
      A) 3xx + Location 指向 portal
      B) 200 + 页面 HTML 含 portal.do 特征（透明劫持，之前漏判的根因）
    通过本地 HttpListener 模拟，不需要真实校园网。
.USAGE
    powershell -ExecutionPolicy Bypass -File scripts\tests\test_captive_detection.ps1
#>

$scriptPath = Join-Path $PSScriptRoot '..\auto_login.ps1'

# 1) 从 auto_login.ps1 提取全部函数定义（只定义函数，不执行主流程）
$tokens = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$err)
if ($err -and $err.Count -gt 0) {
    Write-Host "脚本语法错误，无法测试:" -ForegroundColor Red
    $err | ForEach-Object { Write-Host $_.Message }
    exit 1
}
$funcAsts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcAsts) { Invoke-Expression $f.Extent.Text }
Write-Host "已从 auto_login.ps1 加载 $($funcAsts.Count) 个函数（与正式版同源码）"

# 2) 起本地 HTTP 服务器模拟两类响应（在 job 进程内创建 listener，避免对象跨进程失败）
$readyFile = Join-Path $env:TEMP 'captive_test_ready.txt'
Remove-Item $readyFile -Force -ErrorAction SilentlyContinue
$job = Start-Job -ArgumentList 'http://127.0.0.1:8899/', $readyFile {
    param($prefix, $ready)
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add($prefix)
    $l.Start()
    Set-Content -LiteralPath $ready -Value '1'
    while ($l.IsListening) {
        $ctx = $l.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        if ($path -eq '/portalpage') {
            # 模拟 B: 200 + 认证页 HTML（深澜透明劫持）
            $html = '<html><head><meta charset="utf-8"></head><body>
                <script>window.location.href="http://10.101.2.194:6060/portal.do?wlanuserip=10.104.0.10&wlanacname=HSD-BRAS-2&mac=aa:bb:cc:dd:ee:ff&vlan=19953605&hostname=desktop-example";</script>
                <form><input name="userid"><input name="passwd"></form>
                </body></html>'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'text/html'
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } elseif ($path -eq '/redirect') {
            # 模拟 A: 302 到 portal
            $ctx.Response.StatusCode = 302
            $ctx.Response.RedirectLocation = 'http://10.101.2.194:6060/portal.do?wlanuserip=10.104.0.10'
        } elseif ($path -eq '/normal') {
            # 正常页面
            $html = '<html><body>hello world</body></html>'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'text/html'
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } elseif ($path -eq '/forbidden') {
            # 模拟 C: 403 + 认证页 HTML（部分 BRAS 用 403 承载劫持页）
            $html = '<html><body><script>window.location.href="http://10.101.2.194:6060/portal.do?wlanuserip=10.104.0.10&wlanacname=HSD-BRAS-2";</script></body></html>'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $ctx.Response.StatusCode = 403
            $ctx.Response.ContentType = 'text/html'
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } elseif ($path -eq '/forbidden-plain') {
            # 403 且无认证页特征：判定不出是否劫持，按 fail 处理
            $html = '<html><body>forbidden</body></html>'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $ctx.Response.StatusCode = 403
            $ctx.Response.ContentType = 'text/html'
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $ctx.Response.StatusCode = 404
        }
        $ctx.Response.Close()
    }
}

# 等待 listener 就绪（最多 5 秒）
$ready = $false
for ($i = 0; $i -lt 50; $i++) {
    if (Test-Path $readyFile) { $ready = $true; break }
    Start-Sleep -Milliseconds 100
}
if (-not $ready) {
    Write-Host 'HTTP 模拟服务器未能就绪' -ForegroundColor Red
    Stop-Job $job | Out-Null; Remove-Job $job -Force
    exit 1
}
Remove-Item $readyFile -Force -ErrorAction SilentlyContinue

$pass = 0; $fail = 0
function Check {
    param([string]$Name, [bool]$Cond)
    if ($Cond) { $script:pass++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "[FAIL] $Name" -ForegroundColor Red }
}

# 3) 用例
# 用例1: 200 + portal HTML → captive，且提取出完整 portal URL
$r1 = Http-Probe -Url 'http://127.0.0.1:8899/portalpage'
Check "200+portalHTML 判定 captive (实际: $($r1.Status))" ($r1.Status -eq 'captive')
Check "提取到 portal URL (实际: $($r1.Location))" ($r1.Location -match 'portal\.do\?wlanuserip=10\.104\.176\.86')

# 用例2: 302 → portal → captive
$r2 = Http-Probe -Url 'http://127.0.0.1:8899/redirect'
Check "302→portal 判定 captive (实际: $($r2.Status))" ($r2.Status -eq 'captive')

# 用例3: 200 + 正常 HTML → ok
$r3 = Http-Probe -Url 'http://127.0.0.1:8899/normal'
Check "200+正常HTML 判定 ok (实际: $($r3.Status))" ($r3.Status -eq 'ok')

# 用例4: 连接失败 → fail
$r4 = Http-Probe -Url 'http://127.0.0.1:8898/'
Check "连接失败 判定 fail (实际: $($r4.Status))" ($r4.Status -eq 'fail')

# 用例5: Get-NetworkStatus 综合：captive 探测优先于 fallback
$ns = Get-NetworkStatus -CaptiveUrl 'http://127.0.0.1:8899/portalpage' -FallbackUrl 'http://127.0.0.1:8899/normal'
Check "Get-NetworkStatus 返回 captive (实际: $($ns.Status))" ($ns.Status -eq 'captive')

# 用例6: 全 fail → offline
$ns2 = Get-NetworkStatus -CaptiveUrl 'http://127.0.0.1:8898/' -FallbackUrl 'http://127.0.0.1:8897/'
Check "全部失败 返回 offline (实际: $($ns2.Status))" ($ns2.Status -eq 'offline')

# 用例7: 403 + 认证页 HTML → captive（修复前会被当成 fail/offline，永不触发认证）
$r7 = Http-Probe -Url 'http://127.0.0.1:8899/forbidden'
Check "403+portalHTML 判定 captive (实际: $($r7.Status))" ($r7.Status -eq 'captive')

# 用例8: 403 且无认证特征 → fail
$r8 = Http-Probe -Url 'http://127.0.0.1:8899/forbidden-plain'
Check "403+普通HTML 判定 fail (实际: $($r8.Status))" ($r8.Status -eq 'fail')

# 用例9: 时间戳文件损坏时必须返回 null 并删除文件（否则脚本会永久失败）
$stamp = Join-Path $env:TEMP 'campus_probe_corrupt_test.ts'
Set-Content -LiteralPath $stamp -Value 'not-a-timestamp' -Encoding UTF8
$bad = Read-TimestampFile -Path $stamp
Check "损坏时间戳返回 null (实际: $($null -eq $bad))" ($null -eq $bad)
Check "损坏时间戳文件被删除 (实际存在: $(Test-Path $stamp))" (-not (Test-Path -LiteralPath $stamp))

Stop-Job $job | Out-Null; Remove-Job $job -Force

Write-Host "`n===== 结果: $pass 通过, $fail 失败 ====="
if ($fail -gt 0) { exit 1 } else { exit 0 }
