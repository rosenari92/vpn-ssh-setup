# install-mod-web.ps1 — mod-web.exe 를 C:\mod-web\ 에 배치.
#
# 동작:
#   1) C:\mod-web 디렉토리 생성 (없으면)
#   2) 리포의 mod-web.exe 다운로드 → C:\mod-web\mod-web.exe
#
# 실행 (관리자 PowerShell):
#   irm https://raw.githubusercontent.com/rosenari92/vpn-ssh-setup/main/install-mod-web.ps1 | iex
#
# 서비스 등록(nssm) 은 본 스크립트 범위 밖 — mod-web 동작 확인 후 운영자가 결정.

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrators")) {
  throw "관리자 PowerShell 에서 실행하세요."
}

$base = "https://raw.githubusercontent.com/rosenari92/vpn-ssh-setup/main"
$dir  = "C:\mod-web"
$exe  = "$dir\mod-web.exe"

Write-Host "==> $dir 디렉토리 준비..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $dir -Force | Out-Null

Write-Host "==> mod-web.exe 다운로드..." -ForegroundColor Cyan
Invoke-WebRequest -UseBasicParsing "$base/mod-web.exe" -OutFile $exe

Write-Host ""
Write-Host "=== 완료 ===" -ForegroundColor Green
Write-Host ("  경로: " + $exe)
Write-Host ("  크기: " + (Get-Item $exe).Length + " bytes")
Write-Host ("  버전: " + (Get-Item $exe).VersionInfo.FileVersion)
