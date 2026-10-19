@echo off
chcp 65001 >nul
D:\python3-13\python.exe "%~dp0welcome_uart_gui.py"
if errorlevel 1 pause
