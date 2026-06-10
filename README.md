# vpn-ssh-setup
tailscale + openssh-server setup

- tailscale startup (powershell)
```bash
tailscale up --authkey <키> --unattended --reset
```

- ssh server status (powershell)
```bash
Get-Service sshd
```
