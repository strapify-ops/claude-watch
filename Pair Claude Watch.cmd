@echo off
rem Shows a 6-digit code to type into Claude Watch on the watch.
start "" pythonw "%~dp0watcher\claude_watch.py" --pair --relay https://claude-watch.167-233-232-19.sslip.io
