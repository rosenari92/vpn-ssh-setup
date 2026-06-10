# setup.ps1 — 신규 Windows PC 1회 셋업.
#
# 동작:
#   1) $env:TS_KEY 확인 (one-liner 에서 미리 export)
#   2) OpenSSH Server 설치 (빌트인 Add-WindowsCapability 우선, 실패 시 리포 MSI)
#   3) 리포의 administrators_authorized_keys 를 C:\ProgramData\ssh\ 에 배치
#   4) Tailscale 설치 (리포의 .exe) + tailscale up --unattended --reset
#
# 실행: 관리자 PowerShell 에서 .description 의 one-liner 사용 (TS_KEY 포함).

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrators")) {
  throw "관리자 PowerShell 에서 실행하세요."
}

$base = "https://raw.githubusercontent.com/rosenari92/vpn-ssh-setup/main"
$tmp  = "$env:TEMP\vpn-ssh-setup"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Host "==> host=$env:COMPUTERNAME user=$env:USERNAME" -ForegroundColor Cyan

# ── 1. TS_KEY 확인 (one-liner 에서 $env:TS_KEY 로 전달) ─────────────
$tsAuthKey = $env:TS_KEY
if (-not $tsAuthKey) {
  throw "환경변수 TS_KEY 미설정 — `$env:TS_KEY='tskey-...'; irm <url>/setup.ps1 | iex` 형태로 실행하세요."
}

# ── 2. OpenSSH Server 설치 (리포 MSI 우선, 실패 시 빌트인 capability) ─
Write-Host "==> OpenSSH Server 설치..." -ForegroundColor Cyan
if (Get-Service sshd -EA SilentlyContinue) {
  Write-Host "    이미 설치됨 — skip" -ForegroundColor DarkGray
} else {
  $installed = $false
  try {
    $msi = "$tmp\OpenSSH-Win64.msi"
    Invoke-WebRequest -UseBasicParsing "$base/OpenSSH-Win64-v10.0.0.0.msi" -OutFile $msi
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msi`" /qn /norestart ADDLOCAL=Server"
    $installed = $true
  } catch {
    Write-Host "    리포 MSI 실패 — 빌트인 capability fallback..." -ForegroundColor Yellow
  }
  if (-not $installed) {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
  }
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -EA SilentlyContinue)) {
  New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# 기본 셸 = PowerShell
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Force `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -PropertyType String | Out-Null

# ── 3. administrators_authorized_keys 배치 ─────────────────────────
# Windows OpenSSH 는 관리자 그룹 멤버의 키를 ProgramData\ssh\administrators_authorized_keys
# 에서만 읽음 (sshd_config 의 Match Group administrators 룰).
Write-Host "==> administrators_authorized_keys 배치..." -ForegroundColor Cyan
$sshDataDir = "$env:ProgramData\ssh"
New-Item -ItemType Directory -Path $sshDataDir -Force | Out-Null
$authFile = "$sshDataDir\administrators_authorized_keys"
Invoke-WebRequest -UseBasicParsing "$base/administrators_authorized_keys" -OutFile $authFile
icacls $authFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
Restart-Service sshd

# ── 4. Tailscale 설치 (리포의 exe) ──────────────────────────────────
if (-not (Test-Path "C:\Program Files\Tailscale\tailscale.exe")) {
  Write-Host "==> Tailscale 설치..." -ForegroundColor Cyan
  $tsInst = "$tmp\tailscale-setup.exe"
  Invoke-WebRequest -UseBasicParsing "$base/tailscale-setup-1.98.4.exe" -OutFile $tsInst
  Start-Process $tsInst -Wait -ArgumentList "/quiet"
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
              [Environment]::GetEnvironmentVariable("Path","User")
} else {
  Write-Host "==> Tailscale 이미 설치됨" -ForegroundColor DarkGray
}

# ── 5. Tailscale up + 자동 업데이트 끔 ──────────────────────────────
Write-Host "==> Tailscale up (hostname=$env:COMPUTERNAME)..." -ForegroundColor Cyan
$tsExe = "C:\Program Files\Tailscale\tailscale.exe"
& $tsExe up --auth-key="$tsAuthKey" --hostname="$env:COMPUTERNAME" --accept-routes --accept-dns=$false --unattended --reset
try { & $tsExe set --auto-update=false } catch { Write-Host "    (auto-update 끔 미지원 — 무시)" -ForegroundColor DarkGray }

# ── 결과 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 완료 ===" -ForegroundColor Green
Write-Host ("sshd      : " + (Get-Service sshd).Status)
& $tsExe status | Select-Object -First 3
