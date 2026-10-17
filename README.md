# 河南师范大学校园网自动连接方案

[10.101.2.194:6060/portal.do?wlanuserip=10.104.0.10&amp;wlanacname=HSD-BRAS-2&amp;mac=aa:bb:cc:dd:ee:ff&amp;vlan=19953605&amp;hostname=desktop-example&amp;rand=1e45325ef8fad5e&amp;url=http%3A%2F%2F1.1.1.1](http://10.101.2.194:6060/portal.do?wlanuserip=10.104.0.10&wlanacname=HSD-BRAS-2&mac=aa:bb:cc:dd:ee:ff&vlan=19953605&hostname=desktop-example&rand=1e45325ef8fad5e&url=http%3A%2F%2F1.1.1.1)

## 项目目标

办公室工位电脑（某品牌笔记本，Windows 11）连接 HTU_Student 校园网，在以下场景下自动恢复网络和远程控制（GameViewer），无需到现场：

- 电脑重启 / 断电恢复
- 校园网认证过期 / 被踢下线
- 突然断网后恢复

## 方案概览

采用**电脑端保底方案（方案A）**，不刷路由器、不改 BIOS：

1. **GameViewer 远程服务**已配置为 LocalSystem 自动启动（现状），Windows 账号无密码开机自动登录，保证网络通了就能被远程连上。
2. **自动认证脚本** `scripts/auto_login.ps1`：
   - 每 1 分钟 HTTP 探测外网（`1.1.1.1`，**不用 ping**：BRAS 放行 ICMP 但拦截 HTTP，ping 通不代表已认证）
   - 被劫持时自动捕获 Portal 跳转，向 `http://10.101.2.194:6060/quickauth.do` 提交账号密码
   - 失败重试、写日志、绕开系统代理、日志超 5MB 自动归档
3. **Windows 任务计划** `CampusAutoLogin`（当前启用方案）：
   - 主体 SYSTEM，开机后 30 秒启动，每 1 分钟执行一次
   - 不依赖用户登录
   - 安装：管理员运行 `install_task.ps1`

> 备用方案：`scripts/keepalive_loop.ps1` + 启动文件夹快捷方式（免管理员）。
> 曾在任务计划无法安装时使用，任务计划安装成功后已停用，脚本保留备用。

## 目录结构

```
20261017-自动连接校园网/
├── README.md                    # 本文件
├── .gitignore
├── scripts/
│   ├── config.ini               # 配置（账号密码，密码需手动填写）
│   ├── auto_login.ps1           # 主认证脚本
│   ├── install_task.ps1          # 安装任务计划（需管理员）
│   ├── uninstall_task.ps1        # 卸载任务计划（回滚）
│   ├── keepalive_loop.ps1        # 备用：启动文件夹守护循环（免管理员，已停用）
│   ├── run_install_admin.bat     # 一键管理员安装入口
│   └── tests/
│       └── test_captive_detection.ps1   # 探测逻辑回归测试
├── docs/
│   ├── 01-现状报告.md
│   ├── 02-方案设计.md
│   ├── 03-操作记录.md
│   ├── 04-回滚步骤.md
│   └── 05-原理说明.md            # 系统原理与认证流程详解
└── logs/
    └── auto_login.log           # 运行日志（git 忽略）
```

## 快速开始

### 1. 填写校园网密码

编辑 `scripts/config.ini`，把 `Password = YOUR_PASSWORD_HERE` 改成你的真实校园网密码。

### 2. 安装任务计划（需要管理员）

右键「以管理员身份运行」 PowerShell，执行：

```powershell
cd E:\06DateClass\20261017-自动连接校园网\scripts
.\install_task.ps1
```

### 3. 查看日志

```powershell
Get-Content E:\06DateClass\20261017-自动连接校园网\logs\auto_login.log -Tail 20 -Wait
```

### 4. 可调配置（改 `scripts\config.ini`，改完下一分钟自动生效，无需重装）

| 配置项                             | 默认          | 说明                                                                      |
| ---------------------------------- | ------------- | ------------------------------------------------------------------------- |
| `ProbeIntervalMinutes`           | `1`         | 探测间隔（分钟）。`1`=每分钟，`5`=每5分钟，`0`=任务每次触发都探测   |
| `LogMode`                        | `normal`    | `normal`=每次探测写一条日志；`heartbeat`=在线时按心跳间隔写（防刷屏） |
| `HeartbeatMinutes`               | `30`        | 仅 heartbeat 模式生效：在线时多少分钟写一条心跳                           |
| `RetryInterval` / `MaxRetries` | `5` / `3` | 单次认证失败后的重试间隔（秒）与最多重试次数                              |
| `Ssid`（`[Network]`）           | `HTU_Student` | 提交认证时上报的 SSID，换校区/换 SSID 时改这里，无需改代码              |

> 说明：任务计划本身保持每 1 分钟触发一次，脚本读 `ProbeIntervalMinutes` 自行节流——未到间隔的运行会静默跳过，不占资源。

## 测试验收（怎么测）

> ⚠️ **最重要前提：测试时电脑必须连的是校园网 `HTU_Student`，绝不能是手机热点！**
> 手机热点（如 Redmi K70 Ultra）网络里，校园网认证服务器 `10.101.2.194` 根本不可达，脚本无法认证。
> 确认方法：运行 `netsh wlan show interfaces`，看 `SSID` 那行是不是 `HTU_Student`。
> 若电脑断开校园网后自动连了手机热点，手动切回：
>
> ```powershell
> netsh wlan connect name="HTU_Student" ssid="HTU_Student"
> ```

### 场景 1：断网自动重认证（最常用）

1. 确认当前连的是 `HTU_Student`（见上方前提）
2. 打开日志实时窗口：
   ```powershell
   Get-Content E:\06DateClass\20261017-自动连接校园网\logs\auto_login.log -Tail 30 -Wait
   ```
3. 点右下角 WiFi → **断开 `HTU_Student`**
4. 等 10 秒，**重新连接 `HTU_Student`**（连的时候看清 SSID，别连成手机热点）
5. 观察日志，**1 分钟内**应依次出现：
   ```
   [INFO] 检测到未认证（HTTP 被劫持到认证页），开始自动认证...
   [INFO] 捕获到 Portal 跳转: http://10.101.2.194:6060/portal.do?...
   [INFO] 第 1/3 次提交 quickauth.do ...
   [INFO] 认证成功！message=...
   ```
6. 验证：能打开网页 + 用另一台设备通过 GameViewer 能连上这台电脑

### 场景 2：重启电脑

1. 重启电脑
2. 开机后自动进桌面（账号无密码），任务计划在开机 30 秒后启动，每 1 分钟检测
3. 等 1~2 分钟，用另一台设备通过 GameViewer 连接
4. 判断标准：远端能连上 = 通过；连不上就查日志

### 场景 3：认证过期（可选）

1. 浏览器打开认证页 `http://10.101.2.194:6060/portal.do`，找到"注销/下线"按钮点掉
2. 或等校园网自然踢下线
3. 观察日志是否 1 分钟内自动重新认证

### 场景 4：手动主动执行（不用等任务计划）

脚本不依赖任务计划，可以随时手工跑一次。典型用途：**Wi-Fi 已连上 `HTU_Student` 但尚未认证**，想立刻验证一次真实登录，不必断开重连或干等 1 分钟。

```powershell
cd E:\06DateClass\20261017-自动连接校园网\scripts
powershell -NoProfile -ExecutionPolicy Bypass -File .\auto_login.ps1
"exit=$LASTEXITCODE"
Get-Content E:\06DateClass\20261017-自动连接校园网\logs\auto_login.log -Tail 30
```

⚠️ **必须用 `-File` 方式运行**，不要复制代码粘贴到控制台、也不要点号加载（`. .\auto_login.ps1`）。脚本靠 `$PSScriptRoot` 定位 `config.ini` 和日志目录，只有 `-File` 才会正确赋值；点号加载会直接执行整个主流程。

#### 手动跑"看起来没反应"的三个正常原因

1. **脚本从不往控制台打印** —— 全文只有 `Write-Log` 写文件，终端空白是正常的，必须看日志文件。
2. **可能被探测节流静默跳过**（`ProbeIntervalMinutes=1`）—— 跳过时不写任何日志、直接 `exit 0`。
3. **`exit 0` 有歧义** —— 既表示"认证成功"，也表示"本来就在线""无网络提前退出""被节流跳过"。

第 2 点补充：SYSTEM 任务的戳在 `C:\Windows\Temp`，你手动跑用的是 `C:\Users\<你>\AppData\Local\Temp`，**两套互不干扰**，所以任务计划刚跑过不会挡住你测试；但你自己连续跑两次，第二次会被上一次挡住。保险起见先清一次：

```powershell
Remove-Item "$env:TEMP\campus_probe.ts","$env:TEMP\campus_heartbeat.ts" -Force -ErrorAction SilentlyContinue
```

真正有区分度的是其余退出码：

| 退出码 | 含义                                       |
| ------ | ------------------------------------------ |
| `0`  | 在线无需认证 / 认证成功 / offline 提前退出 |
| `1`  | `config.ini` 不存在或缺少 `[Network]` 必填项 |
| `2`  | 密码仍是 `YOUR_PASSWORD_HERE` 占位符     |
| `3`  | 认证失败（重试次数耗尽）                   |
| `99` | 未处理异常                                 |

判断成功应以日志出现 `认证成功！message=...` 为准，不能只看退出码。

#### 只测探测判定、不提交认证

想先确认"能不能正确识别出被劫持"，而不想真的登进去。注意**不能点号加载**（会执行主流程），正确做法是从源码里只提取函数定义：

```powershell
$p = 'E:\06DateClass\20261017-自动连接校园网\scripts\auto_login.ps1'
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e)
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

Get-NetworkStatus -CaptiveUrl 'http://1.1.1.1' -FallbackUrl 'http://www.msftconnecttest.com/connecttest.txt'
Http-Probe -Url 'http://1.1.1.1'
```

未认证状态下应返回 `Status = captive`，且 `PortalUrl` 是那串 `portal.do?wlanuserip=...`。这一步验证的是最脆弱的部分（劫持识别 + URL 提取），且完全不碰账号密码。

#### 测失败路径（不动真实配置）

用 `-ConfigPath` 指向一份密码故意写错的副本，可完整验证"重试 3 次 → 写 WARN → `exit 3`"的链路（约 15 秒）：

```powershell
Copy-Item .\config.ini .\config.test.ini
# 把 config.test.ini 里的 Password 改成错的
powershell -NoProfile -ExecutionPolicy Bypass -File .\auto_login.ps1 -ConfigPath .\config.test.ini
```

测完删除 `config.test.ini`，避免误提交。

> 手动执行是安全的：不会重新注册任务计划、不改任何系统状态。唯一副作用是认证成功后会写一次 `$probeStamp`，最多让 SYSTEM 任务下次触发延后 1 分钟，无害。
> 但手动跑成功只证明协议链路通，**不等于 SYSTEM 上下文也通**。最终验收仍应执行下面这条，再核对日志：
>
> ```powershell
> Start-ScheduledTask -TaskName CampusAutoLogin   # 需管理员
> ```

### 判断标准（三个都满足 = 通过）

- 日志出现 `认证成功！`
- 浏览器能正常打开网页
- 远端设备 GameViewer 能连上电脑

校园网未认证时有**两类劫持表现**：3xx 跳转到认证页，或直接返回 200/403 + 认证页 HTML（深澜透明劫持；部分 BRAS 用 403 承载认证页）。脚本对两类都识别——只要响应里出现 `portal.do` / `quickauth` / `wlanuserip` 特征，就判定未认证并自动提交；若提不出参数，会主动 GET `portal.do` 兜底，拿不到必要参数则明确报错而不是硬提交。可先跑回归测试确认探测逻辑正常：

```powershell
powershell -ExecutionPolicy Bypass -File E:\06DateClass\20261017-自动连接校园网\scripts\tests\test_captive_detection.ps1
```

预期输出：`11 通过, 0 失败`

### 注意事项

- 日志在 `LogMode=heartbeat` 下在线时 30 分钟才写一条心跳（防刷屏），默认 `normal` 每次探测都写一条；**断网瞬间一定会写详细日志**，所以盯日志要在"断开 WiFi 后立刻"看
- 日志超过 5MB 会自动归档为 `auto_login.log.1`（只保留一份历史），不用担心长期运行把日志撑爆
- 断开重连后若拿到新 IP（DHCP 重新分配），属正常，脚本会从 302 跳转动态获取新 IP
- 如果日志 1 分钟内没动静，先确认任务计划在跑：
  ```powershell
  Get-ScheduledTaskInfo -TaskName CampusAutoLogin
  ```

## 回滚

以管理员运行 `scripts\uninstall_task.ps1` 即可移除任务计划，脚本文件保留在目录中可手动删除。

## 关键信息

| 项目        | 值                                    |
| ----------- | ------------------------------------- |
| 校园网 SSID | HTU_Student                           |
| 认证方式    | Web Portal（深澜/Srun quickauth.do）  |
| 认证服务器  | http://10.101.2.194:6060              |
| 账号后缀    | 学生 `@htu`，教职工 `@htu.edu.cn` |
| 远程软件    | 网易 GameViewer（UU 远程）            |
| 无需验证码  | 是（模板 noTec）                      |
