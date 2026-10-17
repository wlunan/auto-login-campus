#requires -Version 5.1
<#
.SYNOPSIS
    河南师范大学校园网（HTU_Student）自动认证脚本
.DESCRIPTION
    检测外网连通性，不通时自动捕获 Portal 跳转并提交 quickauth.do 完成认证。
    设计为被 Windows 任务计划周期性调用，无需用户登录。
.NOTES
    凭据只从本地 config.ini 读取，不上传任何外部服务。
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

# ---------- 全局：关闭系统代理，确保内网请求直连 ----------
[System.Net.WebRequest]::DefaultWebProxy = $null
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir 'config.ini'
}

# ---------- 工具函数 ----------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $logFile = Resolve-Path -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
    if (-not $logFile) {
        $logFile = $script:LogFile
    }
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # 日志写不进去也不能影响主流程
    }
}

function Read-Ini {
    param([string]$Path)
    $ini = [ordered]@{}
    $section = 'Default'
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $ini.Contains($section)) { $ini[$section] = [ordered]@{} }
            continue
        }
        $idx = $line.IndexOf('=')
        if ($idx -lt 0) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if (-not $ini.Contains($section)) { $ini[$section] = [ordered]@{} }
        $ini[$section][$key] = $val
    }
    return $ini
}

function Extract-PortalUrl {
    <#
        从被劫持的页面 HTML 里提取完整 portal.do URL（深澜页面通常有
        location.href="http://10.101.2.194:6060/portal.do?..." 或 meta refresh）。
        提取不到则返回空。
    #>
    param([string]$Body)
    if ($Body -match 'https?://[^"''<>\s]*portal\.do[^"''<>\s]*') {
        return $Matches[0]
    }
    if ($Body -match '(?:meta[^>]*refresh[^>]*content="[^"]*url\s*=\s*)?([^"''<>\s]*portal\.do[^"''<>\s]*)') {
        $u = $Matches[1]
        if ($u -match '^https?://') { return $u }
    }
    return ''
}

function Http-Probe {
    <#
        对单个 URL 做 HTTP 探测（不跟随重定向），并检查响应是否被 BRAS 劫持成认证页。
        返回 @{Status='ok'|'captive'|'fail'; Location='portal地址'}
        - ok: 正常访问（2xx 且页面无 portal 特征；或 3xx 但跳转目标不是认证页）
        - captive: 被劫持到认证页（深澜两种劫持方式都会命中：
            a) 3xx + Location 指向 portal；b) 200 + 页面 HTML 含 portal.do 特征）
        - fail: 连接失败（无网络）
    #>
    param([string]$Url)
    $portalMark = 'portal\.do|quickauth|wlanuserip|10\.101\.2\.194|srun_portal|login\.do|userid'

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.AllowAutoRedirect = $false
        $req.Timeout = 8000
        $req.Proxy = $null
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        if ($code -ge 200 -and $code -lt 300) {
            # 关键：200 也可能是被劫持的认证页 HTML（深澜透明劫持），必须读响应体检查
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $buf = New-Object char[] 8192
                $read = $sr.Read($buf, 0, 8192)
                $body = -join $buf[0..([Math]::Max(0, $read - 1))]
                $sr.Close()
            } catch {
                $body = ''
            } finally {
                $resp.Close()
            }
            if ($body -match $portalMark) {
                $p = Extract-PortalUrl -Body $body
                if (-not $p) { $p = $Url }
                return @{ Status = 'captive'; Location = $p }
            }
            return @{ Status = 'ok'; Location = '' }
        }
        if ($code -ge 300 -and $code -lt 400) {
            # AllowAutoRedirect=false 时 3xx 是正常响应（不抛异常）
            $loc = $resp.Headers['Location']
            $resp.Close()
            if ($loc -match $portalMark) {
                return @{ Status = 'captive'; Location = $loc }
            }
            # 跳转但非认证页（如 http→https 正常跳转），说明能上网
            return @{ Status = 'ok'; Location = '' }
        }
        $resp.Close()
        return @{ Status = 'ok'; Location = '' }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($resp) {
            $code = [int]$resp.StatusCode
            if ($code -ge 300 -and $code -lt 400) {
                $loc = $resp.Headers['Location']
                $resp.Close()
                if ($loc -match $portalMark) {
                    return @{ Status = 'captive'; Location = $loc }
                }
                # 跳转但非认证页（如 http→https 正常跳转），说明能上网
                return @{ Status = 'ok'; Location = '' }
            }
            $resp.Close()
        }
        return @{ Status = 'fail'; Location = '' }
    } catch {
        return @{ Status = 'fail'; Location = '' }
    }
}

function Get-NetworkStatus {
    <#
        判断当前网络状态。
        返回 @{Status='online'|'captive'|'offline'; PortalUrl='认证入口URL'}
        - online: 能正常访问外网
        - captive: HTTP 被 BRAS 劫持到认证页（200+HTML 或 3xx），需要认证
        - offline: 连接失败，无网络
    #>
    param([string]$CaptiveUrl, [string]$FallbackUrl)
    foreach ($url in @($CaptiveUrl, $FallbackUrl)) {
        if (-not $url) { continue }
        $r = Http-Probe -Url $url
        if ($r.Status -eq 'ok') {
            return @{ Status = 'online'; PortalUrl = '' }
        }
        if ($r.Status -eq 'captive') {
            return @{ Status = 'captive'; PortalUrl = $r.Location }
        }
        # fail: 尝试下一个探测地址
    }
    return @{ Status = 'offline'; PortalUrl = '' }
}

function Get-QueryParams {
    param([string]$Url)
    $u = [System.Uri]$Url
    $qs = [System.Web.HttpUtility]::ParseQueryString($u.Query)
    $dict = [ordered]@{}
    foreach ($k in $qs.AllKeys) { $dict[$k] = $qs[$k] }
    return $dict
}

function Submit-QuickAuth {
    <#
        向 Portal 服务器 GET /quickauth.do 提交认证。
        返回服务器 JSON 对象。
    #>
    param(
        [string]$PortalBase,
        [string]$Path,
        [hashtable]$Params
    )
    $query = ($Params.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f [System.Uri]::EscapeDataString($_.Key), [System.Uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    $url = "$PortalBase$Path`?$query"

    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'GET'
    $req.Timeout = 10000
    $req.Proxy = $null
    $req.Accept = 'application/json, text/javascript, */*; q=0.01'
    $req.Referer = $PortalBase + '/portal.do'
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'

    try {
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        Write-Log "quickauth.do response: $body"
        try {
            return ($body | ConvertFrom-Json)
        } catch {
            Write-Log "响应不是合法 JSON: $body" 'WARN'
            return $null
        }
    } catch {
        Write-Log "quickauth.do 请求异常: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

# ---------- 主流程 ----------
try {
    Add-Type -AssemblyName System.Web

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "配置文件不存在: $ConfigPath" 'ERROR'
        exit 1
    }

    $cfg = Read-Ini -Path $ConfigPath
    $script:LogFile = Join-Path $scriptDir $cfg['Settings']['LogFile']
    $logDir = Split-Path -Parent $script:LogFile
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

    $username = $cfg['Auth']['Username']
    $password = $cfg['Auth']['Password']
    $suffix   = $cfg['Auth']['Suffix']
    $pingHost = $cfg['Network']['PingHost']
    $captive  = $cfg['Network']['CaptiveUrl']
    $portalBase = $cfg['Network']['PortalBase']
    $quickAuth  = $cfg['Network']['QuickAuthPath']
    $retryWait  = [int]$cfg['Settings']['RetryInterval']
    $maxRetries = [int]$cfg['Settings']['MaxRetries']
    $fallback   = $cfg['Network']['FallbackUrl']
    # 日志模式: heartbeat=在线时按心跳间隔写日志(防刷屏); normal=每次运行都写一条
    $logMode = [string]$cfg['Settings']['LogMode']
    if ($logMode -ne 'normal') { $logMode = 'heartbeat' }

    if ($password -eq 'YOUR_PASSWORD_HERE' -or [string]::IsNullOrWhiteSpace($password)) {
        Write-Log "密码仍为占位符，请先编辑 config.ini 填入真实校园网密码" 'ERROR'
        exit 2
    }

    # 1. HTTP 探测判断网络状态（ping 不可靠：校园网 BRAS 放行 ICMP 但拦截 HTTP，ping 通不代表已认证）
    $ns = Get-NetworkStatus -CaptiveUrl $captive -FallbackUrl $fallback

    if ($ns.Status -eq 'online') {
        $shouldLog = $true
        $now = [DateTime]::Now
        if ($logMode -eq 'heartbeat') {
            # 心跳模式：按 HeartbeatMinutes 间隔写一条，避免刷爆日志
            $heartbeatFile = Join-Path $env:TEMP 'campus_heartbeat.ts'
            if (Test-Path $heartbeatFile) {
                $last = [DateTime]::Parse((Get-Content $heartbeatFile -Raw).Trim())
                if (($now - $last).TotalMinutes -lt [int]$cfg['Settings']['HeartbeatMinutes']) {
                    $shouldLog = $false
                }
            }
        }
        if ($shouldLog) {
            $modeNote = if ($logMode -eq 'normal') { '（normal 模式每次记录）' } else { '' }
            Write-Log "外网可达（HTTP 探测通过），无需认证。$modeNote"
            if ($logMode -eq 'heartbeat') {
                $now.ToString('o') | Set-Content -LiteralPath $heartbeatFile -Encoding UTF8
            }
        }
        exit 0
    }

    if ($ns.Status -eq 'offline') {
        Write-Log "HTTP 探测失败，疑似无网络连接（WiFi 未连接或 DHCP 未完成）。ping $pingHost 辅助结果: $([bool](Test-Connection -ComputerName $pingHost -Count 1 -Quiet -ErrorAction SilentlyContinue))。本次退出，等待下次任务。" 'WARN'
        exit 0
    }

    # captive：未认证，HTTP 被 BRAS 劫持到认证页（200+HTML 或 3xx）
    Write-Log "检测到未认证（HTTP 被劫持到认证页），开始自动认证..."
    $portalUrl = $ns.PortalUrl
    Write-Log "捕获到 Portal 跳转: $portalUrl"

    # 3. 从跳转 URL 解析参数（wlanuserip/wlanacname/mac/vlan 等）
    $params = Get-QueryParams -Url $portalUrl
    # 补充认证参数
    $params['userid'] = $username + $suffix
    $params['passwd'] = $password
    # ssid 从环境补
    if (-not $params.Contains('ssid')) { $params['ssid'] = 'HTU_Student' }

    # 4. 重试提交
    $ok = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        Write-Log "第 $i/$maxRetries 次提交 quickauth.do ..."
        $json = Submit-QuickAuth -PortalBase $portalBase -Path $quickAuth -Params $params
        if ($json -and "$($json.code)" -eq '0') {
            Write-Log "认证成功！message=$($json.message)"
            $ok = $true
            break
        }
        $msg = if ($json) { $json.message } else { '无响应' }
        Write-Log "认证未成功（code=$($json.code) message=$msg），${retryWait}s 后重试。" 'WARN'
        Start-Sleep -Seconds $retryWait
    }

    if (-not $ok) {
        Write-Log "达到最大重试次数，本次认证失败。等待下次任务触发。" 'ERROR'
        exit 3
    }

    # 5. 认证后验证
    Start-Sleep -Seconds 3
    $verify = Get-NetworkStatus -CaptiveUrl $captive -FallbackUrl $fallback
    if ($verify.Status -eq 'online') {
        Write-Log "认证后外网恢复，任务完成。"
    } else {
        Write-Log "认证返回成功但 HTTP 探测仍不通（$($verify.Status)），可能需要更长时间生效，下次任务再验证。" 'WARN'
    }
    exit 0

} catch {
    Write-Log "未处理异常: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
    exit 99
}
