# setup.ps1 — 신규 Windows PC 1회 셋업.
#
# 동작:
#   1) $env:TS_KEY / $env:PMS_AGENT_MQTT_PASSWORD 확인 (one-liner 에서 미리 export)
#   2) OpenSSH Server 설치 (리포 MSI 우선, fallback 빌트인 capability)
#   3) 리포의 administrators_authorized_keys 를 C:\ProgramData\ssh\ 에 배치
#   4) Tailscale 설치 (리포의 .exe) + tailscale up --unattended --reset
#   5) nssm 설치 (C:\nssm) + PATH 등록 + pms-agent 서비스 등록
#      + 시스템 환경변수 PMS_AGENT_MQTT_PASSWORD
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

# ── 1. 환경변수 확인 (one-liner 에서 미리 export) ──────────────────
$tsAuthKey = $env:TS_KEY
$mqttPwd   = $env:PMS_AGENT_MQTT_PASSWORD
if (-not $tsAuthKey) {
  throw "환경변수 TS_KEY 미설정 — `$env:TS_KEY='tskey-...' 필요"
}
if (-not $mqttPwd) {
  throw "환경변수 PMS_AGENT_MQTT_PASSWORD 미설정 — `$env:PMS_AGENT_MQTT_PASSWORD='...' 필요"
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

# ── 5. nssm 설치 (C:\nssm) + PATH 추가 ─────────────────────────────
Write-Host "==> nssm 설치 (C:\nssm)..." -ForegroundColor Cyan
$nssmDir = "C:\nssm"
$nssmExe = "$nssmDir\nssm.exe"
New-Item -ItemType Directory -Path $nssmDir -Force | Out-Null
Invoke-WebRequest -UseBasicParsing "$base/nssm.exe" -OutFile $nssmExe
# 시스템 PATH 에 C:\nssm 등록 (이미 있으면 skip)
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if (($machinePath -split ';') -notcontains $nssmDir) {
  [Environment]::SetEnvironmentVariable("Path", "$machinePath;$nssmDir", "Machine")
  Write-Host "    PATH 에 $nssmDir 추가" -ForegroundColor Yellow
}
$env:Path = $env:Path + ";$nssmDir"

# ── 6. pms-agent 서비스 등록 (nssm) + 환경변수 ──────────────────────
Write-Host "==> pms-agent 서비스 등록..." -ForegroundColor Cyan
$svcName = "pms-agent"
$svcApp  = "C:\pms-agent\pms-agent.exe"
$svcArgs = "-config C:\pms-agent\config.yaml"
# 기존 서비스 있으면 한 번 정지 후 재설정 (idempotent)
if (Get-Service $svcName -EA SilentlyContinue) {
  Write-Host "    이미 등록됨 — 재설정" -ForegroundColor DarkGray
  & $nssmExe stop  $svcName 2>$null | Out-Null
  & $nssmExe set   $svcName Application $svcApp     | Out-Null
  & $nssmExe set   $svcName AppParameters $svcArgs  | Out-Null
} else {
  & $nssmExe install $svcName $svcApp $svcArgs      | Out-Null
}
& $nssmExe set $svcName Start SERVICE_AUTO_START    | Out-Null
& $nssmExe set $svcName AppDirectory "C:\pms-agent" | Out-Null

# 시스템 환경변수 PMS_AGENT_MQTT_PASSWORD (one-liner 의 값을 Machine scope 으로 영속화)
[Environment]::SetEnvironmentVariable("PMS_AGENT_MQTT_PASSWORD", $mqttPwd, "Machine")
Write-Host "    PMS_AGENT_MQTT_PASSWORD 환경변수 등록 (Machine scope)" -ForegroundColor Yellow

# 서비스 시작은 운영자가 pms-agent.exe 배포 후 직접 (nssm start pms-agent)

# ── 결과 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 완료 ===" -ForegroundColor Green
Write-Host ("sshd      : " + (Get-Service sshd).Status)
Write-Host ("pms-agent : " + (Get-Service $svcName -EA SilentlyContinue).Status)
& $tsExe status | Select-Object -First 3
