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

function Test-Internet {
    param([string]$Target)
    try {
        $r = Test-Connection -ComputerName $Target -Count 2 -Quiet -ErrorAction Stop
        return [bool]$r
    } catch {
        return $false
    }
}

function Get-CaptiveRedirect {
    <#
        访问 CaptiveUrl，不跟随重定向，返回 302 的 Location 头（portal.do 完整 URL）。
        如果返回 200（已认证，直接能上网）则返回 $null。
        如果连接失败（WiFi 都没连上）则返回 $null 并抛错。
    #>
    param([string]$Url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.AllowAutoRedirect = $false
        $req.Timeout = 8000
        $req.Proxy = $null
        $resp = $req.GetResponse()
        # 200 说明直接通了，不需要认证
        $resp.Close()
        return $null
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($resp) {
            $sc = [int]$resp.StatusCode
            if ($sc -eq 301 -or $sc -eq 302 -or $sc -eq 303 -or $sc -eq 307 -or $sc -eq 308) {
                $loc = $resp.Headers['Location']
                $resp.Close()
                return $loc
            }
        }
        throw
    }
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

    if ($password -eq 'YOUR_PASSWORD_HERE' -or [string]::IsNullOrWhiteSpace($password)) {
        Write-Log "密码仍为占位符，请先编辑 config.ini 填入真实校园网密码" 'ERROR'
        exit 2
    }

    # 1. 先检测外网
    if (Test-Internet -Target $pingHost) {
        # 在线。为了不刷爆日志，30 分钟写一次心跳
        $heartbeatFile = Join-Path $env:TEMP 'campus_heartbeat.ts'
        $now = [DateTime]::Now
        $shouldLog = $true
        if (Test-Path $heartbeatFile) {
            $last = [DateTime]::Parse((Get-Content $heartbeatFile -Raw).Trim())
            if (($now - $last).TotalMinutes -lt [int]$cfg['Settings']['HeartbeatMinutes']) {
                $shouldLog = $false
            }
        }
        if ($shouldLog) {
            Write-Log "外网可达（ping $pingHost 通），无需认证。"
            $now.ToString('o') | Set-Content -LiteralPath $heartbeatFile -Encoding UTF8
        }
        exit 0
    }

    Write-Log "外网不通（ping $pingHost 失败），开始尝试 Portal 重认证..."

    # 2. 捕获 captive portal 跳转
    $portalUrl = $null
    try {
        $portalUrl = Get-CaptiveRedirect -Url $captive
    } catch {
        Write-Log "访问 $captive 失败（WiFi 可能未连接）: $($_.Exception.Message)" 'WARN'
        exit 0
    }

    if (-not $portalUrl) {
        Write-Log "访问 $captive 返回 200 无跳转，但 ping 不通——可能是 DNS/ICMP 被拦，再试一次 HTTP。"
        # 再给一次机会：直接试访问外网 HTTP
        try {
            $probe = [System.Net.HttpWebRequest]::Create('http://www.baidu.com')
            $probe.Method = 'GET'; $probe.Timeout = 8000; $probe.Proxy = $null
            $probe.GetResponse().Close()
            Write-Log "HTTP 探测 baidu 成功，判定为已在线。"
            exit 0
        } catch {
            Write-Log "HTTP 探测也失败，继续走认证流程。"
        }
    }

    if (-not $portalUrl) {
        Write-Log "未捕获到 Portal 跳转，本次退出等待下次任务。" 'WARN'
        exit 0
    }

    Write-Log "捕获到 Portal 跳转: $portalUrl"

    # 3. 从跳转 URL 解析参数
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

    # 5. 认证后稍等再 ping 验证
    Start-Sleep -Seconds 3
    if (Test-Internet -Target $pingHost) {
        Write-Log "认证后外网恢复，任务完成。"
    } else {
        Write-Log "认证返回成功但 ping 仍不通，可能需要更长时间生效，下次任务再验证。" 'WARN'
    }
    exit 0

} catch {
    Write-Log "未处理异常: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
    exit 99
}
