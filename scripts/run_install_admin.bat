@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\06DateClass\20261017-自动连接校园网\scripts\install_task.ps1" > "E:\06DateClass\20261017-自动连接校园网\logs\install_stdout.txt" 2>&1
