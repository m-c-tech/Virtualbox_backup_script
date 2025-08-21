# VirtualBox VM Automatic Backup Script (Windows)

## Objective
Automate nightly backups of all VirtualBox VMs on a Windows host, with auto-discovery of new VMs and support for VMs stored across multiple disks.

## Key Features
- Uses VirtualBox command-line tools (`VBoxManage`) to list and copy VMs.
- PowerShell script for automation and logging.
- Auto-discovers all registered VMs (no manual VM list required).
- Backups stored in a designated folder, one backup per VM (previous backup is overwritten).
- Handles VMs on different disks by querying VM locations.
- Scheduled via Windows Task Scheduler for nightly execution.
- Logs all backup actions and errors to `backup_log.txt` with timestamps.

## Auto-Discovery Approach
- The script queries VirtualBox for all registered VMs each run using `VBoxManage list vms`.
- No need to update the script when new VMs are added.

## Handling Multiple Disks
- Uses VM info to determine disk location and configuration file path.
- Script automatically finds and backs up VMs across multiple disks.

## Scheduling
- Use Windows Task Scheduler to run the PowerShell script nightly.

## Notes
- The script overwrites previous backups for each VM (no retention policy).
- All backup actions and errors are logged to `backup_log.txt` in the script folder.

## References
- [VirtualBox Automatic Backup with a Simple Batch File](https://andydunkel.net/2018/02/20/virtualbox-automatic-backup-with-a-simple-batch-file/)
