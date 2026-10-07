# Glance Stops Working

This document describes the steps to troubleshoot and resolve issues when the OpenStack Glance service stops working.

## Glance stops accepting authentication requests.

### Possible Causes

- The 401s are the Glance on pcd-ce-hyp-01 (10.45.60.1, behind nginx on 9494) failing to validate tokens.
- Its log says Unable to validate token: Unable to establish connection to https://pcd.rye.ninja/keystone/v3/auth/tokens … [Errno -2] No address found. So the running process can't resolve pcd.rye.ninja.
- A fresh process as the same pf9 user, with the service's library path and eventlet loaded the same way, resolves it to 10.45.45.45 without trouble.
- pf9-glance-api has been running since 2026-09-30 06:04, which is also when systemd-resolved started, so the host had just booted. My guess is that the process picked up broken resolver state during that boot and never refreshed it. That is inferred from timing, not proven.

### Resolution

- Restart the pf9-glance-api service to refresh its DNS resolver state:

```bash
sudo systemctl restart pf9-glance-api
```

### Verification

- Ensure that the pf9-glance-api service is running without errors:

```bash
sudo systemctl status pf9-glance-api
```

- Verify that the service is now able to authenticate requests by checking the logs:

```bash
sudo journalctl -u pf9-glance-api -f
```

### Self-Healing Automation

- Implement a systemd service override or a cron job to automatically restart the pf9-glance-api service if it fails to authenticate requests due to DNS resolution issues.