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
   - 每 1 分钟 ping 223.5.5.5 检测外网
   - 不通时自动捕获 Portal 跳转，向 `http://10.101.2.194:6060/quickauth.do` 提交账号密码
   - 失败重试、写日志、绕开系统代理
3. **Windows 任务计划** `CampusAutoLogin`：开机后 30 秒启动，每 1 分钟执行一次，SYSTEM 权限运行。

## 目录结构

```
20261017-自动连接校园网/
├── README.md                    # 本文件
├── .gitignore
├── scripts/
│   ├── config.ini               # 配置（账号密码，密码需手动填写）
│   ├── auto_login.ps1           # 主认证脚本
│   ├── install_task.ps1          # 安装任务计划（需管理员）
│   └── uninstall_task.ps1        # 卸载任务计划（回滚）
├── docs/
│   ├── 01-现状报告.md
│   ├── 02-方案设计.md
│   ├── 03-操作记录.md
│   └── 04-回滚步骤.md
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
