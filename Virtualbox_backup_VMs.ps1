# VirtualBox VM Automatic Backup Script
# This PowerShell script backs up all VirtualBox VMs and their configuration files.
# It overwrites the previous backup each time.
# Supports a dry run mode for testing.

param(
    [switch]$DryRun
)

# Set the path to VBoxManage.exe (update if VirtualBox is installed elsewhere)
$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

# Set the backup destination folder
$BackupRoot = "Z:\VM_Backup"

# Set log file path
$ScriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile = Join-Path $ScriptFolder "backup_log.txt"

# Reset the log file at the start of each run
try {
    $runHeader = "===== Backup run started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
    Set-Content -Path $LogFile -Value $runHeader -ErrorAction Stop
} catch {
    # If we can't write the header, proceed; subsequent logs may still work
}

# Function to log messages with timestamp
function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Timestamp - $Message"
    # Use a FileStream with shared Read/Write to reduce lock conflicts (e.g., when viewing the log)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($LogEntry + [Environment]::NewLine)
        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    } catch {
        # Fall back to Add-Content with retry if the file is temporarily locked
        $retries = 3
        for ($r=0; $r -lt $retries; $r++) {
            try { Add-Content -Path $LogFile -Value $LogEntry; break } catch { Start-Sleep -Milliseconds 150 }
        }
    }
    Write-Host $LogEntry
}

# Format bytes to human-readable string
function Format-Bytes {
    param([long]$Bytes)
    $sizes = 'B','KB','MB','GB','TB','PB'
    if ($Bytes -lt 1) { return "0 B" }
    $i = [math]::Floor([math]::Log($Bytes, 1024))
    if ($i -ge $sizes.Length) { $i = $sizes.Length - 1 }
    $value = $Bytes / [math]::Pow(1024, $i)
    return "{0:N1} {1}" -f $value, $sizes[$i]
}

# Get free bytes on the drive that contains the given path
function Get-DriveFreeBytes {
    param([Parameter(Mandatory)] [string]$Path)
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        $resolved = $Path
    }
    $root = [System.IO.Path]::GetPathRoot($resolved)
    if (-not $root) { return 0 }
    $driveName = $root.TrimEnd('\').TrimEnd(':')
    try {
        $psd = Get-PSDrive -Name $driveName -ErrorAction Stop
        return [int64]$psd.Free
    } catch {
        return 0
    }
}

# Copy a single file with 10% progress logging
function Copy-FileWithProgress {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )
    $srcInfo = Get-Item -LiteralPath $Source -ErrorAction Stop
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $total = [double]$srcInfo.Length
    if ($total -le 0) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        Write-Log "100%..."
        return
    }

    $bufferSize = 8MB
    $buffer = New-Object byte[] $bufferSize
    $bytesCopied = 0L
    $nextMark = 0

    Write-Log "0%..."
    $in = [System.IO.File]::OpenRead($Source)
    try {
        $out = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $out.Write($buffer, 0, $read)
                $bytesCopied += $read
                $pct = [math]::Floor(($bytesCopied / $total) * 100)
                while ($pct -ge $nextMark + 10 -and $nextMark -lt 100) {
                    $nextMark += 10
                    Write-Log "$nextMark%..."
                }
            }
        } finally {
            $out.Dispose()
        }
    } finally {
        $in.Dispose()
    }
}

# Compute relative path of a file under a base folder (case-insensitive),
# falling back to just the filename if the item is outside the base.
function Get-RelativePath {
    param(
        [Parameter(Mandatory)] [string]$BaseFolder,
        [Parameter(Mandatory)] [string]$FullPath
    )
    $baseNorm = if ($BaseFolder.EndsWith('\')) { $BaseFolder } else { "$BaseFolder\" }
    if ($FullPath.StartsWith($baseNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($baseNorm.Length)
    }
    return [System.IO.Path]::GetFileName($FullPath)
}

# Create backup folder if it doesn't exist
if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
    Write-Log "Created backup root folder: $BackupRoot"
}

# Get list of all VMs
$VMs = & $VBoxManage list vms

# Outcome counters
$successCount = 0
$failureCount = 0
$skippedCount = 0

foreach ($VM in $VMs) {
    # Extract VM name and UUID
    if ($VM -match '"(.+?)"\s+\{(.+?)\}') {
        $VMName = $matches[1]
        $VMUUID = $matches[2]

        Write-Log "Starting backup for VM: $VMName ($VMUUID)"

        try {
            $vmHadError = $false
            # Get VM info to find config file location and running state
            $VMInfo = & $VBoxManage showvminfo $VMUUID --machinereadable
            if (-not ($VMInfo -match 'CfgFile=')) {
                Write-Log "Skipping VM $VMName ($VMUUID): VM info is inaccessible or missing."
                $skippedCount++
                continue
            }
            $ConfigPath = ($VMInfo | Select-String -Pattern 'CfgFile=').ToString()
            $ConfigPath = $ConfigPath -replace 'CfgFile="','' -replace '"',''

            # Get VM folder
            $VMFolder = Split-Path $ConfigPath -Parent

            # Gather VDI files for sizing checks
            $VDIFiles = Get-ChildItem -Path $VMFolder -Filter *.vdi -Recurse
            $maxVDISize = if ($VDIFiles) { ($VDIFiles | Measure-Object Length -Maximum).Maximum } else { 0 }
            $freeLocal = Get-DriveFreeBytes -Path $VMFolder
            $safetyMargin = [int64](200MB)
            $requiredForStaging = if ($maxVDISize -gt 0) { [int64]([math]::Ceiling($maxVDISize * 1.1)) } else { 0 }
            if ($requiredForStaging -lt $safetyMargin -and $maxVDISize -gt 0) { $requiredForStaging = $safetyMargin }
            $CanStageLocally = $true
            if ($maxVDISize -gt 0) {
                $CanStageLocally = ($freeLocal -ge $requiredForStaging)
                $driveRoot = ([System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $VMFolder).Path))
                Write-Log "Local disk check for staging on ${driveRoot}: Free=$(Format-Bytes $freeLocal), Required~$(Format-Bytes $requiredForStaging), Largest VDI=$(Format-Bytes $maxVDISize), CanStage=$CanStageLocally"
            }

            # Check if VM is running
            $RunningState = ($VMInfo | Select-String -Pattern 'VMState=').ToString()
            $RunningState = $RunningState -replace 'VMState="','' -replace '"',''
            $WasRunning = $false

            # Set backup destination for this VM
            $VMBackupFolder = Join-Path $BackupRoot $VMName

            Write-Log "VM Info: Name=$VMName, UUID=$VMUUID, Location=$VMFolder, BackupTarget=$VMBackupFolder, State=$RunningState"

            # Estimate destination space needs (non-VDI contents + largest VDI)
            $nonVDIFiles = Get-ChildItem -Path $VMFolder -Recurse | Where-Object { $_.Extension -ne '.vdi' }
            $nonVDISize = if ($nonVDIFiles) { ($nonVDIFiles | Measure-Object Length -Sum).Sum } else { 0 }
            $estimatedMinDest = [int64]($nonVDISize + $maxVDISize)
            $freeDest = Get-DriveFreeBytes -Path $VMBackupFolder
            if ($estimatedMinDest -gt 0) {
                $destRoot = ([System.IO.Path]::GetPathRoot($VMBackupFolder))
                Write-Log "Destination disk check ${destRoot}: Free=$(Format-Bytes $freeDest), EstimatedMin~$(Format-Bytes $estimatedMinDest)"
            }

            if ($DryRun) {
                if ($VDIFiles -and $maxVDISize -gt 0) {
                    $driveRoot = ([System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $VMFolder).Path))
                    Write-Log "DRY RUN: Local staging disk ${driveRoot} Free=$(Format-Bytes $freeLocal), Required~$(Format-Bytes $requiredForStaging), CanStage=$CanStageLocally"
                }
                Write-Log "DRY RUN: Would backup $VMName from $VMFolder to $VMBackupFolder. VM running state: $RunningState."
                continue
            }

            if ($RunningState -eq 'running') {
                $WasRunning = $true
                Write-Log "VM $VMName is running. Saving state..."
                & $VBoxManage controlvm $VMName savestate
                Write-Log "VM $VMName state saved."
            }

            # Remove previous backup if exists
            if (Test-Path $VMBackupFolder) {
                Remove-Item -Recurse -Force $VMBackupFolder
                Write-Log "Removed previous backup for $VMName"
            }

            # Copy VM folder (configs, snapshots, etc.), but skip .vdi files
            $ExcludeVDI = @($VDIFiles | ForEach-Object { $_.FullName })
            $ItemsToCopy = $nonVDIFiles
            $TotalItems = $ItemsToCopy.Count
            $LastLoggedPercent = -1
            # Normalize VMFolder to ensure trailing backslash for relative path calc
            $VMFolderNorm = if ($VMFolder.EndsWith('\')) { $VMFolder } else { "$VMFolder\" }
            for ($i = 0; $i -lt $TotalItems; $i++) {
                $Item = $ItemsToCopy[$i]
                $relative = Get-RelativePath -BaseFolder $VMFolder -FullPath $Item.FullName
                $Dest = Join-Path $VMBackupFolder $relative
                if ($Item.PSIsContainer) {
                    if (!(Test-Path $Dest)) {
                        New-Item -ItemType Directory -Path $Dest | Out-Null
                    }
                } else {
                    # Safety guard: skip if destination resolves to the same path
                    if ($Dest -ieq $Item.FullName) { continue }
                    try {
                        Copy-Item -Path $Item.FullName -Destination $Dest -Force -ErrorAction Stop
                    } catch {
                        $vmHadError = $true
                        Write-Log "Copy error for ${VMName}: $($Item.FullName) -> $Dest : $($_.Exception.Message)"
                    }
                }
                $Percent = [math]::Floor((($i + 1) / $TotalItems) * 100)
                if ($Percent % 10 -eq 0 -and $Percent -ne $LastLoggedPercent) {
                    Write-Log "$Percent%..."
                    $LastLoggedPercent = $Percent
                }
            }

            # Stage and compact each VDI locally under the VM folder if space permits; otherwise fallback to direct copy
            $StagingFolder = Join-Path $VMFolder "_vbbackup_staging"
            if ($VDIFiles -and $CanStageLocally) {
                if (Test-Path -LiteralPath $StagingFolder) {
                    try { Remove-Item -LiteralPath $StagingFolder -Recurse -Force -ErrorAction Stop } catch {}
                }
                New-Item -ItemType Directory -Path $StagingFolder -Force | Out-Null
            }

            foreach ($VDI in $VDIFiles) {
                # Relative path under VM folder (preserves filename and casing)
                $relativeVDI = Get-RelativePath -BaseFolder $VMFolder -FullPath $VDI.FullName
                $DestVDI = Join-Path $VMBackupFolder $relativeVDI
                if ($CanStageLocally) {
                    $LocalStagedVDI = Join-Path $StagingFolder $relativeVDI
                    # Ensure staging subfolder exists
                    $stageDir = Split-Path -Parent $LocalStagedVDI
                    if (-not (Test-Path -LiteralPath $stageDir)) {
                        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
                    }

                    Write-Log "Cloning to local staging: $($VDI.FullName) -> $LocalStagedVDI"
                    & $VBoxManage clonemedium "$( $VDI.FullName )" "$LocalStagedVDI" --format=VDI --variant=Standard
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $LocalStagedVDI)) {
                        $vmHadError = $true
                        Write-Log "Clone error for ${VMName}: $( $VDI.FullName )"
                        continue
                    }

                    Write-Log "Compacting staged VDI: $LocalStagedVDI"
                    & $VBoxManage modifymedium "$LocalStagedVDI" --compact
                    if ($LASTEXITCODE -ne 0) {
                        Write-Log "Compact error for ${VMName}: $LocalStagedVDI"
                    }

                    Write-Log "Transferring compacted VDI to backup: $LocalStagedVDI -> $DestVDI"
                    try {
                        $destDir = Split-Path -Parent $DestVDI
                        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                        Copy-FileWithProgress -Source $LocalStagedVDI -Destination $DestVDI
                        # Remove staged file to free space before processing next VDI
                        try {
                            Remove-Item -LiteralPath $LocalStagedVDI -Force
                            Write-Log "Removed staged file to free space: $LocalStagedVDI"
                        } catch {
                            Write-Log "Warning: could not remove staged file $LocalStagedVDI : $($_.Exception.Message)"
                        }
                    } catch {
                        $vmHadError = $true
                        Write-Log "Copy error for ${VMName}: $LocalStagedVDI -> $DestVDI : $($_.Exception.Message)"
                    }
                } else {
                    # Fallback: no local staging space; copy source VDI directly to backup (no compact)
                    Write-Log "Insufficient local space for staging; copying VDI directly to backup: $($VDI.FullName) -> $DestVDI"
                    try {
                        $destDir = Split-Path -Parent $DestVDI
                        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                        Copy-FileWithProgress -Source $VDI.FullName -Destination $DestVDI
                    } catch {
                        $vmHadError = $true
                        Write-Log "Copy error for ${VMName}: $($VDI.FullName) -> $DestVDI : $($_.Exception.Message)"
                    }
                }
            }

            # Cleanup staging
            if (Test-Path -LiteralPath $StagingFolder) {
                try {
                    Remove-Item -LiteralPath $StagingFolder -Recurse -Force
                    Write-Log "Cleaned up staging folder: $StagingFolder"
                } catch {
                    Write-Log "Staging cleanup warning for ${VMName}: $($_.Exception.Message)"
                }
            }

            if ($vmHadError) {
                Write-Log "Backup finished with errors for $VMName"
                $failureCount++
            } else {
                Write-Log "Backup complete for $VMName"
                $successCount++
            }

            # Restart VM if it was running before
            if ($WasRunning) {
                Write-Log "Restarting VM $VMName..."
                & $VBoxManage startvm $VMName --type headless
                Write-Log "VM $VMName restarted."
            }
        }
        catch {
            Write-Log "ERROR backing up ${VMName}: $($_.Exception.Message)"
            $failureCount++
        }
    }
}

if ($successCount -gt 0 -and $failureCount -eq 0) {
    Write-Log "All VM backups completed."
} else {
    Write-Log "Backup run finished. Success: $successCount; Failed: $failureCount; Skipped: $skippedCount."
}
