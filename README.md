# vpn-ssh-setup

신규 Windows PC 1회 셋업 — Tailscale + OpenSSH Server + 운영 SSH 키.

## 사용법

각 PC 에서 **관리자 PowerShell** 열고 한 줄 실행 (TS_KEY / MQTT 비밀번호는 발급받은 값으로 교체):

```powershell
$env:TS_KEY="tskey-auth-..."; $env:PMS_AGENT_MQTT_PASSWORD="..."; irm https://raw.githubusercontent.com/rosenari92/vpn-ssh-setup/main/setup.ps1 | iex
```

## 구성

| 파일 | 용도 | git |
|---|---|---|
| `setup.ps1` | 1회 셋업 스크립트 (raw URL 로 실행) | ✅ |
| `update-keys.ps1` | SSH 공개키만 갱신 (재실행 안전) | ✅ |
| `administrators_authorized_keys` | 관리자 그룹용 SSH 공개키 모음 (공개 OK) | ✅ |
| `OpenSSH-Win64-v10.0.0.0.msi` | OpenSSH Server 설치파일 (리포 MSI 우선) | ✅ |
| `tailscale-setup-1.98.4.exe` | Tailscale 설치파일 | ✅ |
| `nssm.exe` | pms-agent 서비스 등록용 | ✅ |
| `.env` | `TS_KEY` 보관 (로컬 메모) | ❌ |
| `.description` | one-liner 메모 (로컬) | ❌ |

## 키만 갱신 (이미 셋업된 PC)

```powershell
irm https://raw.githubusercontent.com/rosenari92/vpn-ssh-setup/main/update-keys.ps1 | iex
```

## 셋업 흐름

1. `$env:TS_KEY` 확인
2. **OpenSSH Server** 설치 (빌트인 우선, 실패 시 리포 MSI) + 서비스 자동시작 + 방화벽 + 기본 셸 PowerShell
3. **administrators_authorized_keys** → `C:\ProgramData\ssh\` 배치 + ACL (`Administrators:F`, `SYSTEM:F`)
4. **Tailscale** 설치 → `tailscale up --auth-key=... --hostname=$COMPUTERNAME --accept-routes --accept-dns=false --unattended --reset` → 자동 업데이트 끔
5. **nssm** → `C:\nssm\nssm.exe` 배치 + 시스템 PATH 추가
6. **pms-agent 서비스** (nssm) — Application=`C:\pms-agent\pms-agent.exe`, AppParameters=`-config C:\pms-agent\config.yaml`, Start=Auto. 시스템 환경변수 `PMS_AGENT_MQTT_PASSWORD=efmqtt1!`. `pms-agent.exe` 가 아직 없으면 서비스만 등록되고 시작 실패는 무시.

## 수동 확인

```powershell
Get-Service sshd
tailscale status
```

## 주의

- `administrators_authorized_keys` 는 관리자 그룹 멤버의 인증 키. 일반 계정 SSH 접속이 필요하면 `~/.ssh/authorized_keys` 별도 등록 필요.
- `TS_KEY` 만료 (기본 90일) — 만료 시 Tailscale Admin Console 에서 재발급.
- Tailscale 자동 업데이트는 끔 (오버레이 끊김 사례 회피). 보안 패치는 수동.
