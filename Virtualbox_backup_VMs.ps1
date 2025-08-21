# VirtualBox VM Automatic Backup Script
# This PowerShell script backs up all VirtualBox VMs and their configuration files.
# It overwrites the previous backup each time.
# Supports a dry run mode for testing.

param(
    [switch]$DryRun
)

# Set the path to VBoxManage.exe (update if VirtualBox is installed elsewhere)

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

# Set log file path
$ScriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile = Join-Path $ScriptFolder "backup_log.txt"

# Function to log messages with timestamp
function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Timestamp - $Message"
    Add-Content -Path $LogFile -Value $LogEntry
    Write-Host $LogEntry
}

# Set the backup destination folder
$BackupRoot = "Z:\VM_Backup"

# Create backup folder if it doesn't exist

if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
    Write-Log "Created backup root folder: $BackupRoot"
}

# Get list of all VMs
$VMs = & $VBoxManage list vms

foreach ($VM in $VMs) {
    # Extract VM name and UUID
    if ($VM -match '"(.+?)"\s+\{(.+?)\}') {
        $VMName = $matches[1]
        $VMUUID = $matches[2]

        Write-Log "Starting backup for VM: $VMName ($VMUUID)"

        try {
            # Get VM info to find config file location and running state
            $VMInfo = & $VBoxManage showvminfo $VMUUID --machinereadable
            if (-not ($VMInfo -match 'CfgFile=')) {
                Write-Log "Skipping VM $VMName ($VMUUID): VM info is inaccessible or missing."
                continue
            }
            $ConfigPath = ($VMInfo | Select-String -Pattern 'CfgFile=').ToString()
            $ConfigPath = $ConfigPath -replace 'CfgFile="','' -replace '"',''

            # Get VM folder
            $VMFolder = Split-Path $ConfigPath -Parent

            # Check if VM is running
            $RunningState = ($VMInfo | Select-String -Pattern 'VMState=').ToString()
            $RunningState = $RunningState -replace 'VMState="','' -replace '"',''
            $WasRunning = $false

            # Set backup destination for this VM
            $VMBackupFolder = Join-Path $BackupRoot $VMName

            Write-Log "VM Info: Name=$VMName, UUID=$VMUUID, Location=$VMFolder, BackupTarget=$VMBackupFolder, State=$RunningState"

            if ($DryRun) {
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

            # Copy VM folder (includes config and disks)
            Copy-Item -Path $VMFolder -Destination $VMBackupFolder -Recurse -Force
            Write-Log "Backup complete for $VMName"

            # Restart VM if it was running before
            if ($WasRunning) {
                Write-Log "Restarting VM $VMName..."
                & $VBoxManage startvm $VMName --type headless
                Write-Log "VM $VMName restarted."
            }
        }
        catch {
            Write-Log "ERROR backing up ${VMName}: $($_.Exception.Message)"
        }
    }
}

Write-Log "All VM backups completed."
