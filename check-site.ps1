# site-resource.ps1 — 사이트(현장 PC)의 자원 상태 한 번에 보기.
#
# 출력:
#   - 시스템 요약: hostname / OS / uptime / CPU 평균 / 메모리 사용률 / 디스크
#   - 프로세스 상위: CPU%, Memory(MB), IO(KB/s) — 임계치 이상만
#
# 호환성:
#   - PowerShell 2.0 (Win7 SP1) 까지 호환되도록 작성:
#     * Get-WmiObject 사용 (Get-CimInstance 는 PS 3.0+)
#     * New-Object PSObject (PSCustomObject 리터럴은 PS 3.0+)
#   - 단 vpn-ssh-setup 으로 SSH 셋업이 안 되는 Win7 은 사실상 접근 불가.

param(
    [switch]$Network   # 켜면 ETW(Kernel-Network) 5초 캡처로 프로세스별 송수신 KB 표시
)

$ErrorActionPreference = "SilentlyContinue"
# 한글 윈도우 기본 cp949 → ssh stdout UTF-8 로 받기 위해 강제
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ── 1) 프로세스 자원 1회 수집 (WMI — 한국어 윈도우 호환) ────────────
# Get-Counter 는 한국어 윈도우에서 카운터 이름이 현지화되어 영문 매칭 실패.
# Win32_PerfFormattedData_PerfProc_Process 는 표준 WMI 클래스라 로케일 무관.
$ProcData = Get-WmiObject Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue

# ── 2) 시스템 요약 ──────────────────────────────────────────────────
$OS         = Get-WmiObject Win32_OperatingSystem
$CS         = Get-WmiObject Win32_ComputerSystem
$CoreCount  = $CS.NumberOfLogicalProcessors
if (-not $CoreCount) { $CoreCount = 1 }
$CpuLoad    = (Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$MemFreeKB  = [int64]$OS.FreePhysicalMemory
$MemTotalKB = [int64]$OS.TotalVisibleMemorySize
$MemUsedMB  = [Math]::Round(($MemTotalKB - $MemFreeKB) / 1024, 0)
$MemTotalMB = [Math]::Round($MemTotalKB / 1024, 0)
$MemPct     = [Math]::Round((1 - $MemFreeKB / $MemTotalKB) * 100, 1)
$Uptime     = (Get-Date) - $OS.ConvertToDateTime($OS.LastBootUpTime)

# ── 3) 디스크 (DriveType=3 == Local Disk) ───────────────────────────
$Disks = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $size  = [int64]$_.Size
    $free  = [int64]$_.FreeSpace
    if ($size -gt 0) {
        New-Object PSObject -Property @{
            "Drive"    = $_.DeviceID
            "UsedGB"   = [Math]::Round(($size - $free) / 1GB, 1)
            "TotalGB"  = [Math]::Round($size / 1GB, 1)
            "Used(%)"  = [Math]::Round((1 - $free / $size) * 100, 1)
        }
    }
}

# ── 4) 프로세스별 자원 집계 (임계 이상만) ───────────────────────────
# IOOtherBytesPersec 는 컨트롤 ops (네트워크 X). 디스크/파일 IO 는 IODataBytesPersec.
$Report = $ProcData | Where-Object {
    $_.Name -notmatch "^(_Total|Idle|System|Memory Compression)$"
} | ForEach-Object {
    # PercentProcessorTime 은 전체 코어 합산 (0~CoreCount*100). 단일 코어 환산.
    $CpuPct  = [Math]::Round([double]$_.PercentProcessorTime / $CoreCount, 1)
    $MemMB   = [Math]::Round([double]$_.WorkingSetPrivate / 1MB, 1)
    $DiskKBs = [Math]::Round([double]$_.IODataBytesPersec / 1KB, 2)

    if ($CpuPct -gt 0.5 -or $MemMB -gt 10 -or $DiskKBs -gt 1) {
        New-Object PSObject -Property @{
            "Process"    = $_.Name
            "CPU(%)"     = $CpuPct
            "Mem(MB)"    = $MemMB
            "Disk(KB/s)" = $DiskKBs
        }
    }
}

# ── 5) 네트워크 인터페이스 송수신 (KB/s) ────────────────────────────
# 프로세스 단위 네트워크는 표준 Performance Counter 에 없음 (ETW 등 별도 필요) —
# 여기선 인터페이스 단위 송수신 합산. Loopback/Teredo/isatap 등 가상은 제외.
$NetData = Get-WmiObject Win32_PerfFormattedData_Tcpip_NetworkInterface
$NetReport = $NetData | Where-Object {
    $_.Name -notmatch "(?i)isatap|Loopback|Teredo|Pseudo"
} | ForEach-Object {
    $down = [Math]::Round([double]$_.BytesReceivedPersec / 1KB, 2)
    $up   = [Math]::Round([double]$_.BytesSentPersec / 1KB, 2)
    # 트래픽 거의 0 인 인터페이스 제외 (down + up < 0.1 KB/s)
    if (($down + $up) -gt 0.1) {
        New-Object PSObject -Property @{
            "Interface"  = $_.Name
            "Down(KB/s)" = $down
            "Up(KB/s)"   = $up
        }
    }
}

# ── 5) 출력 ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================ System ================"
Write-Host ("  Hostname : " + $env:COMPUTERNAME)
Write-Host ("  OS       : " + $OS.Caption.Trim() + " (Build " + $OS.BuildNumber + ")")
Write-Host ("  Uptime   : " + ("{0}d {1}h {2}m" -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes))
Write-Host ("  CPU Load : " + $CpuLoad + "%   (cores=" + $CoreCount + ")")
Write-Host ("  Memory   : " + $MemPct + "%   (" + $MemUsedMB + " / " + $MemTotalMB + " MB)")

Write-Host ""
Write-Host "================ Disks ================="
# stdin(-Command -) 모드에서 PS pipeline 자동 형식화가 끊겨 객체가 raw 로 나오는
# 케이스가 있어 Out-String 으로 명시 문자열화 후 Write-Host.
($Disks | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host

Write-Host ""
Write-Host "================ Network Interfaces (Down+Up > 0.1 KB/s) ================"
($NetReport | Sort-Object @{Expression={[double]$_."Down(KB/s)" + [double]$_."Up(KB/s)"}; Descending=$true} |
    Select-Object Interface, "Down(KB/s)", "Up(KB/s)" |
    Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host

Write-Host ""
Write-Host "================ Top Processes (CPU > 0.5% / Mem > 10MB / Disk > 1KB/s) ================"
($Report | Sort-Object "CPU(%)" -Descending | Select-Object -First 25 |
    Select-Object Process, "CPU(%)", "Mem(MB)", "Disk(KB/s)" |
    Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host

# ── 6) [-Network] ETW Kernel-Network 5초 캡처 → 프로세스별 송수신 KB ──
if ($Network) {
    Write-Host ""
    Write-Host "================ Network by Process (ETW Kernel-Network, 5s capture) ================"
    # NetEventSession cmdlet 은 Windows 8.1 (Build 9600) / Server 2012 R2 부터.
    # Win7 / Win8 RTM 에서는 모듈 자체 부재 → skip.
    if ([int]$OS.BuildNumber -lt 9600) {
        Write-Host ("  (skip) NetEventSession 미지원 — Windows 8.1(Build 9600)+ 필요. 현재 Build " + $OS.BuildNumber)
        return
    }
    $sessionName = "ChkSiteNet"
    $etl = "$env:TEMP\$sessionName.etl"
    $xml = "$env:TEMP\$sessionName.xml"
    try {
        # 이전 세션 잔재 정리
        Stop-NetEventSession   $sessionName -EA SilentlyContinue
        Remove-NetEventSession $sessionName -EA SilentlyContinue
        Remove-Item $etl, $xml -Force -EA SilentlyContinue

        # 세션 + provider + 5초 캡처
        New-NetEventSession -Name $sessionName -LocalFilePath $etl -CaptureMode SaveToFile -EA Stop | Out-Null
        Add-NetEventProvider -Name "Microsoft-Windows-Kernel-Network" -SessionName $sessionName -EA Stop | Out-Null
        Start-NetEventSession $sessionName
        Start-Sleep -Seconds 5
        Stop-NetEventSession $sessionName
        Remove-NetEventSession $sessionName

        # Get-WinEvent 로 .etl 파일 직접 읽기 (tracerpt 우회 — manifest 자동, 더 안정적)
        $events = @(Get-WinEvent -Path $etl -Oldest -EA SilentlyContinue)
        if (-not $events -or $events.Count -eq 0) {
            Write-Host ("  (.etl 파일 비어있음. size=" + (Get-Item $etl).Length + ")")
        } else {
            Write-Host ("  (events=" + $events.Count + ") 분석 중...")
            # 디버그: Event ID 분포 + 샘플 properties (한 번만 — 이상 발견 시 분석용)
            if ($env:CHKSITE_DEBUG -eq '1') {
                Write-Host "--- DEBUG: Event ID 분포 (Kernel-Network 만) ---"
                ($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-Kernel-Network" } |
                    Group-Object Id | Sort-Object Count -Descending |
                    Select-Object Count, Name | Format-Table | Out-String).TrimEnd() | Write-Host
                foreach ($dbgId in @(10, 11, 26, 27)) {
                    $sample = $events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-Kernel-Network" -and $_.Id -eq $dbgId } | Select-Object -First 1
                    if ($sample) {
                        Write-Host ("--- DEBUG: Id=$dbgId sample (PID=" + $sample.ProcessId + ", PropCount=" + $sample.Properties.Count + ") ---")
                        for ($i=0; $i -lt $sample.Properties.Count; $i++) {
                            $v = $sample.Properties[$i].Value
                            $t = if ($v) { $v.GetType().Name } else { "null" }
                            Write-Host ("  [" + $i + "] " + $t + " = " + $v)
                        }
                    }
                }
                Write-Host "--- END DEBUG ---"
            }
            # 이벤트 ID 별 Send/Recv 분류 (TCP: 10/11, UDP: 26/27)
            $sendIds = @(10, 26)
            $recvIds = @(11, 27)
            $procName = @{}
            $stats    = @{}

            # Kernel-Network Send/Recv event properties:
            #   [0] PID (uint32) - $e.ProcessId is capture-context PID (Idle=0); use Properties[0].
            #   [1] size (uint32, bytes)
            #   [2~] daddr/saddr/dport/sport etc.
            foreach ($e in $events) {
                if ($e.ProviderName -ne "Microsoft-Windows-Kernel-Network") { continue }
                $eid = [int]$e.Id
                if (-not (($sendIds + $recvIds) -contains $eid)) { continue }
                if ($e.Properties.Count -lt 2) { continue }
                $procId = [int]($e.Properties[0].Value)
                $size   = [long]($e.Properties[1].Value)
                if ($procId -le 0 -or $size -le 0) { continue }

                if (-not $stats.ContainsKey($procId)) { $stats[$procId] = @{Send=[long]0; Recv=[long]0} }
                if ($sendIds -contains $eid) { $stats[$procId].Send += $size }
                else                         { $stats[$procId].Recv += $size }
            }

            $netReport = $stats.Keys | ForEach-Object {
                $procId = $_
                if (-not $procName.ContainsKey($procId)) {
                    $p = Get-Process -Id $procId -EA SilentlyContinue
                    $procName[$procId] = if ($p) { $p.ProcessName } else { "PID:$procId" }
                }
                $sendKB = [Math]::Round($stats[$procId].Send / 1024 / 5, 2)   # 5초 → /s
                $recvKB = [Math]::Round($stats[$procId].Recv / 1024 / 5, 2)
                if ($sendKB -gt 0.05 -or $recvKB -gt 0.05) {
                    New-Object PSObject -Property @{
                        Process    = $procName[$procId]
                        PID        = $procId
                        "Down(KB/s)" = $recvKB
                        "Up(KB/s)"   = $sendKB
                    }
                }
            }

            if ($netReport) {
                ($netReport |
                    Sort-Object @{Expression={[double]$_."Down(KB/s)" + [double]$_."Up(KB/s)"}; Descending=$true} |
                    Select-Object -First 20 Process, PID, "Down(KB/s)", "Up(KB/s)" |
                    Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
            } else {
                Write-Host "  (캡처 기간 동안 트래픽 거의 없음)"
            }
        }
    } catch {
        Write-Host ("  ETW 캡처 실패: " + $_.Exception.Message)
    } finally {
        # cleanup
        Stop-NetEventSession   $sessionName -EA SilentlyContinue
        Remove-NetEventSession $sessionName -EA SilentlyContinue
        Remove-Item $etl -Force -EA SilentlyContinue
    }
}
