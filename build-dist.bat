@echo off
mkdir bin\dist
odin build sandbox/src -strict-style -collection:sm=engine/src -out:bin/dist/Sandbox.exe -target:windows_amd64 -keep-temp-files -o:speed -show-timings -show-system-calls

mkdir dist
copy /b bin\dist\Sandbox.exe dist\Sandbox.exe

mkdir dist\engine\res\
xcopy engine\res\* dist\engine\res\ /E/H