# update-keys.ps1 — administrators_authorized_keys 만 갱신.
#
# setup.ps1 의 3단계와 동일하지만 OpenSSH/Tailscale/nssm 은 건드리지 않음.
# 키 추가/제거 후 각 PC 에서 한 줄로 동기화할 때 사용.
#
# 실행 (관리자 PowerShell):
#   irm https://raw.githubusercontent.com/rosenari92/vpn-ssh-setup/main/update-keys.ps1 | iex

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrators")) {
  throw "관리자 PowerShell 에서 실행하세요."
}

$base       = "https://raw.githubusercontent.com/rosenari92/vpn-ssh-setup/main"
$sshDataDir = "$env:ProgramData\ssh"
$authFile   = "$sshDataDir\administrators_authorized_keys"

New-Item -ItemType Directory -Path $sshDataDir -Force | Out-Null
Write-Host "==> administrators_authorized_keys 갱신..." -ForegroundColor Cyan
Invoke-WebRequest -UseBasicParsing "$base/administrators_authorized_keys" -OutFile $authFile
icacls $authFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

if (Get-Service sshd -EA SilentlyContinue) { Restart-Service sshd }

Write-Host ""
Write-Host "=== 완료 ===" -ForegroundColor Green
Write-Host "갱신: $authFile"
Write-Host "키 수: $((Get-Content $authFile | Where-Object { $_ -match '\S' }).Count)"
