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

set "SCRIPT_DIR=%~dp0"
set "EXTENSION_REPO=%SCRIPT_DIR%..\endpoint-vscode"
set "PLATFORM="
set "CLEAN=false"
set "CACHE_FLAG="

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
    echo [1/6] Cleaning up...
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
    echo [1/6] Skipping cleanup ^(use --clean for full rebuild^)
)

REM --- Build VS Code extension ---
echo.
echo [2/6] Building VS Code extension...
if exist "%EXTENSION_REPO%\package.json" (
    pushd "%EXTENSION_REPO%"
    if not exist "node_modules" (
        echo   Installing npm dependencies...
        call npm install --silent
    )
    call npm run build --silent
    call npm run package --silent
    popd

    REM Copy .vsix into sandbox extensions dir
    set "VSIX_FOUND=false"
    for %%f in ("%EXTENSION_REPO%\endpoint-*.vsix") do (
        copy /y "%%f" "%SCRIPT_DIR%devcontainer\extensions\" >nul
        echo   Copied %%~nxf to devcontainer\extensions\
        set "VSIX_FOUND=true"
    )
    if "!VSIX_FOUND!"=="false" (
        echo   WARNING: No .vsix file found after build
    )
) else (
    echo   WARNING: endpoint-vscode repo not found at %EXTENSION_REPO%
    echo   The devcontainer image will install from Open VSX at runtime instead.
)

REM --- Build image chain ---
echo.
echo [3/6] Building base image...
docker build --platform %PLATFORM% %CACHE_FLAG% --pull=false ^
    -t sixways-sandbox:base ^
    -t ghcr.io/sixways-ai/sixways-sandbox:latest ^
    -f base/Dockerfile "%SCRIPT_DIR%."
if errorlevel 1 goto build_failed

echo.
echo [4/6] Building node image...
docker build --platform %PLATFORM% %CACHE_FLAG% --pull=false ^
    -t sixways-sandbox:node ^
    -t ghcr.io/sixways-ai/sixways-sandbox:node ^
    -f node/Dockerfile "%SCRIPT_DIR%node"
if errorlevel 1 goto build_failed

echo.
echo [5/6] Building devcontainer image...
docker build --platform %PLATFORM% %CACHE_FLAG% --pull=false ^
    -t sixways-sandbox:devcontainer ^
    -f devcontainer/Dockerfile "%SCRIPT_DIR%."
if errorlevel 1 goto build_failed

REM --- Verify ---
echo.
echo [6/6] Verifying...
for /f "tokens=*" %%a in ('docker inspect sixways-sandbox:devcontainer --format "{{.Architecture}}"') do set "ACTUAL_ARCH=%%a"
echo   Architecture: %ACTUAL_ARCH%

echo.
echo   Built images:
docker images --format "  {{.Repository}}:{{.Tag}}	{{.Size}}" | findstr sixways-sandbox

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
