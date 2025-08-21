# VirtualBox VM Automatic Backup Script (Windows)

This project provides a PowerShell script to automatically back up all VirtualBox VMs on a Windows host. It auto-discovers VMs, safely handles running machines, compacts virtual disks to save space, and overwrites the previous backup each run.

Script: `Virtualbox_backup_VMs.ps1`

## Key features
- Auto-discovery: Enumerates all registered VMs via `VBoxManage list vms` every run (no manual VM list).
- Overwrite-only: Keeps a single backup per VM; removes the previous backup folder before copying.
- Includes config: Copies `.vbox` and other non-VDI VM files/folders.
- VM state handling: Saves state for running VMs before backup and starts them again after.
- Dry run mode: `-DryRun` logs planned actions without pausing VMs or copying.
- VDI optimization: Skips raw `.vdi` copy; clones each VDI to a local staging folder and runs `VBoxManage modifymedium --compact`, then transfers the compacted VDI to the backup.
- Local staging and cleanup: Uses per-VM `_vbbackup_staging` folder; staged files are deleted after transfer.
- Disk space checks with fallback: Checks free space on the VM’s local drive; if insufficient for staging, falls back to a direct VDI copy (no compact). Also logs destination free space and a minimal estimate.
- Progress visibility: Logs progress at 10% increments during file/folder copies, including large VDI transfers.
- Robust logging: Timestamped logs written to `backup_log.txt` with file-sharing to avoid view locks; log is truncated at the start of each run.
- Resilience: Skips inaccessible VMs; safe relative path handling prevents path traversal issues.
- Summary output: Final summary shows Success/Failed/Skipped and only logs “All VM backups completed.” when all VMs succeed.

## How it works (high level)
1. Discovers VMs via `VBoxManage list vms` and queries details (`showvminfo --machinereadable`).
2. For each VM:
	- Saves state if running.
	- Deletes the previous backup folder for that VM.
	- Copies non-VDI files (e.g., `.vbox`, logs, snapshots metadata).
	- Calculates largest VDI size and local free space to decide if compacted staging is possible.
	- If possible, clones the VDI to `_vbbackup_staging`, compacts it, then transfers to backup and deletes the staged file. Otherwise, copies the original VDI directly.
	- Restarts the VM if it was running.
3. Prints a per-run summary with counts.

## Configuration
Edit variables near the top of `Virtualbox_backup_VMs.ps1`:
- `$VBoxManage` – Path to `VBoxManage.exe` (defaults to `C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`).
- `$BackupRoot` – Destination folder (e.g., `Z:\VM_Backup`). Create the root if needed.

## Usage
Dry run (no changes):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Virtualbox_backup_VMs.ps1 -DryRun
```

Run backup:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Virtualbox_backup_VMs.ps1
```

Logs are written to `backup_log.txt` in the script directory. The log is reset at the start of each run.

## Scheduling (Task Scheduler)
1. Create a new task.
2. Triggers: Nightly at your desired time.
3. Actions: Program/script: `powershell` (or `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`).
	- Arguments: `-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Virtualbox_backup_VMs.ps1"`
	- Start in: `C:\path\to\Virtualbox_backup_script`
4. Options: Run whether user is logged on or not; Run with highest privileges.

## What gets backed up
- Non-VDI files: `.vbox` (config), logs, snapshots metadata, and other VM files.
- Disk images: `.vdi` files are either compacted via local staging and then transferred, or directly copied if staging space is insufficient.

## Notes and limitations
- No retention policy: Each run overwrites the prior backup for each VM.
- The script does not quiesce the guest OS; it uses VirtualBox save-state for consistency.
- Devices from tools like Genymotion may appear as VMs; they will be processed unless filtered out.
- If there isn’t enough local space, compaction is skipped for that VM’s disks (a direct copy is used).