@echo off
cd /d %~dp0
copy _config.yml _config.yml.bak
git pull origin master
exit
