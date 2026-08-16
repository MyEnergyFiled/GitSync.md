# Automation and Background Sync

GitSync.md supports user-initiated pulls through Shortcuts, but it does not schedule periodic background Git transfers. iOS gives App Intents a limited execution window and may suspend or terminate work based on battery, network, thermal state, and user activity. A background refresh task therefore cannot guarantee that a clone, fetch, LFS transfer, or worktree update will finish.

## Supported automation

- **Pull Repository** fetches and fast-forwards one cloned repository.
- **Pull All Repositories** processes cloned repositories sequentially so one repository does not race another for shared app state.
- Both actions can run without opening the app when iOS grants enough execution time.
- A Personal Automation triggered when GitSync.md opens is the recommended auto-pull setup. A manual Shortcut while the device is unlocked is the most reliable option.

The pull safety rules are the same as in the app: local edits are not overwritten, diverged branches and conflicts require attention, and failures in one repository are reported rather than silently discarded.

## iOS execution limits

GitSync.md intentionally does not register `BGAppRefreshTask` or `BGProcessingTask` today:

- scheduling time and runtime are controlled by iOS, not by the app;
- network access is not guaranteed, especially on constrained or changing connections;
- libgit2 and Git LFS calls cannot always be interrupted in the middle of a transport operation;
- security-scoped folders provided by Files or another app may be unavailable in the background;
- a terminated task cannot present conflict resolution or SSH host-trust UI.

An automation can therefore be interrupted before all repositories finish. Run it again after unlocking the device; completed repositories remain complete and local files are preserved.

## Data-protection policy

- Shortcut pulls stop before constructing Git state when iOS reports protected data as unavailable.
- Credentials are stored in Keychain with `AfterFirstUnlockThisDeviceOnly`: they do not sync to another device and are unavailable until the first unlock after a restart.
- A repository in a security-scoped external folder is pulled only when its bookmark resolves and folder access is active.
- Temporary loss of an external provider no longer marks the repository as deleted or clears its last known clone state.
- Logs redact credentials and do not include article bodies or authorization request bodies.

If a Shortcut reports that protected data or an external folder is unavailable, unlock the device, open GitSync.md, restore folder access if requested, and run the Shortcut again.

## Future evaluation gate

A scheduled background pull should be added only after it can enforce expiration handling at safe Git boundaries, verify protected-data and bookmark availability, persist per-repository outcomes, avoid parallel repository mutation, and pass the locked/unlocked device cases in [REAL_DEVICE_REGRESSION.md](REAL_DEVICE_REGRESSION.md).
