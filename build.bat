@echo off
setlocal enabledelayedexpansion

REM SixWays Sandbox — Local Image Build Script (Windows)
REM
REM Usage:
REM   build.bat              Build for amd64 (default on Windows)
REM   build.bat arm64        Build for ARM64
REM   build.bat amd64        Build for x86_64
REM   build.bat --clean      Clean slate: remove volumes, rebuild with --no-cache
REM   build.bat amd64 --clean
REM
REM Builds base/node/python/rust/go only. The external IDE extension is released
REM separately; hosted IDE and desktop sources are deferred. microVM images use
REM scripts/build-microvm.sh. This script does not publish images.

set "SCRIPT_DIR=%~dp0"
set "PLATFORM="
set "CLEAN=false"
set "CACHE_FLAG=--pull=false"

REM --- Parse arguments ---
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="arm64"   (set "PLATFORM=linux/arm64" & shift & goto parse_args)
if /i "%~1"=="aarch64" (set "PLATFORM=linux/arm64" & shift & goto parse_args)
if /i "%~1"=="amd64"   (set "PLATFORM=linux/amd64" & shift & goto parse_args)
if /i "%~1"=="x86_64"  (set "PLATFORM=linux/amd64" & shift & goto parse_args)
if /i "%~1"=="x64"     (set "PLATFORM=linux/amd64" & shift & goto parse_args)
if /i "%~1"=="--clean" (set "CLEAN=true" & shift & goto parse_args)
if /i "%~1"=="--help"  goto show_help
if /i "%~1"=="-h"      goto show_help
echo Unknown argument: %~1
exit /b 1
:args_done

REM Auto-detect platform if not specified (Windows is almost always amd64)
if "%PLATFORM%"=="" set "PLATFORM=linux/amd64"

echo.
echo   SixWays Sandbox — Local Build
echo   Platform: %PLATFORM%
echo   Clean:    %CLEAN%
echo.

REM --- Clean slate (if requested) ---
if "%CLEAN%"=="true" (
    echo [1/7] Cleaning up...
    REM Stop and remove sandbox containers
    for /f "tokens=*" %%i in ('docker ps -a --filter "name=sixways" -q 2^>nul') do (
        docker rm -f %%i >nul 2>&1
    )
    REM Remove persistent volumes
    for %%v in (sixways-sandbox-home sixways-cache-npm sixways-cache-pip sixways-cache-cargo) do (
        docker volume rm %%v >nul 2>&1 && echo   Removed volume: %%v || rem
    )
    set "CACHE_FLAG=--no-cache --pull"
    echo   Done.
) else (
    echo [1/7] Skipping cleanup ^(use --clean for full rebuild^)
)

REM --- sixways-mcp-proxy must be staged first (bash scripts/build-mcp-proxy.sh <endpoint-checkout>, e.g. from WSL) ---
if not exist "%SCRIPT_DIR%common\mcp-proxy\sixways-mcp-proxy-linux-amd64" goto mcp_proxy_missing
if not exist "%SCRIPT_DIR%common\mcp-proxy\sixways-mcp-proxy-linux-arm64" goto mcp_proxy_missing
REM --- sixways-probe likewise (bash scripts/build-probe.sh <endpoint-checkout>) ---
if not exist "%SCRIPT_DIR%common\probe\sixways-probe-linux-amd64" goto probe_missing
if not exist "%SCRIPT_DIR%common\probe\sixways-probe-linux-arm64" goto probe_missing

REM --- Build image chain ---
echo.
echo [2/7] Building base image...
docker build --platform %PLATFORM% %CACHE_FLAG% ^
    -t sixways-sandbox:base ^
    -t ghcr.io/sixways-ai/sixways-sandbox:latest ^
    -f base/Dockerfile "%SCRIPT_DIR%."
if errorlevel 1 goto build_failed

echo.
echo [3/7] Building node image...
docker build --platform %PLATFORM% %CACHE_FLAG% ^
    -t sixways-sandbox:node ^
    -t ghcr.io/sixways-ai/sixways-sandbox:node ^
    --build-arg BASE_IMAGE=sixways-sandbox:base ^
    -f node/Dockerfile "%SCRIPT_DIR%."
if errorlevel 1 goto build_failed

echo.
echo [4/7] Building python image...
docker build --platform %PLATFORM% %CACHE_FLAG% ^
    -t sixways-sandbox:python ^
    -t ghcr.io/sixways-ai/sixways-sandbox:python ^
    --build-arg BASE_IMAGE=sixways-sandbox:base ^
    -f python/Dockerfile "%SCRIPT_DIR%."
if errorlevel 1 goto build_failed

echo.
echo [5/7] Building rust and go images...
docker build --platform %PLATFORM% %CACHE_FLAG% ^
    -t sixways-sandbox:rust ^
    -t ghcr.io/sixways-ai/sixways-sandbox:rust ^
    --build-arg BASE_IMAGE=sixways-sandbox:base ^
    -f rust/Dockerfile "%SCRIPT_DIR%."
if errorlevel 1 goto build_failed
docker build --platform %PLATFORM% %CACHE_FLAG% ^
    -t sixways-sandbox:go ^
    -t ghcr.io/sixways-ai/sixways-sandbox:go ^
    --build-arg BASE_IMAGE=sixways-sandbox:base ^
    -f go/Dockerfile "%SCRIPT_DIR%."
if errorlevel 1 goto build_failed

REM --- Verify ---
echo.
echo [6/7] Verifying...
for /f "tokens=*" %%a in ('docker inspect sixways-sandbox:base --format "{{.Architecture}}"') do set "ACTUAL_ARCH=%%a"
set "EXPECTED_ARCH=%PLATFORM:linux/=%"
if not "%ACTUAL_ARCH%"=="%EXPECTED_ARCH%" (
    echo   ERROR: Expected %EXPECTED_ARCH% but got %ACTUAL_ARCH%
    goto build_failed
)
echo   Architecture: %ACTUAL_ARCH%

echo.
echo [7/7] Built CLI images:
docker images --format "  {{.Repository}}:{{.Tag}} {{.Size}}" | findstr /c:"sixways-sandbox:base " /c:"sixways-sandbox:latest " /c:"sixways-sandbox:node " /c:"sixways-sandbox:python " /c:"sixways-sandbox:rust " /c:"sixways-sandbox:go "

echo.
echo   Build complete.
echo.
exit /b 0

:build_failed
echo.
echo   BUILD FAILED. Try: build.bat --clean
exit /b 1

:show_help
echo Usage: build.bat [arm64^|amd64] [--clean]
echo.
echo   arm64/amd64   Target platform (default: amd64 on Windows)
echo   --clean       Remove volumes, rebuild with --no-cache --pull
exit /b 0

:mcp_proxy_missing
echo ERROR: common\mcp-proxy binaries are not staged. Run: bash scripts/build-mcp-proxy.sh ^<sixways-endpoint-dev checkout^>
exit /b 1

:probe_missing
echo ERROR: common\probe binaries are not staged. Run: bash scripts/build-probe.sh ^<sixways-endpoint-dev checkout^>
exit /b 1
