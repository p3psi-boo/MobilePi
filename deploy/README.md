# MobilePi Deployment

## systemd (Linux)

1. Copy binaries to `/opt/mobilepi/`
2. Create env file `/etc/mobilepi/hub.env`:
   ```
   MOBILE_PI_TENANT_KEY=your-secret-key
   ```
3. Create env file `/etc/mobilepi/daemon.env`:
   ```
   MOBILE_PI_HUB_WS_URL=wss://your-hub:8080/ws
   MOBILE_PI_TENANT_KEY=your-secret-key
   ```
4. Install and start:
   ```bash
   sudo cp deploy/mobilepi-hub.service deploy/mobilepi-daemon.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now mobilepi-hub mobilepi-daemon
   ```

## launchd (macOS)

1. Copy binary to `/opt/mobilepi/daemon`
2. Edit `deploy/com.mobilepi.daemon.plist` with your hub URL and tenant key
3. Install and start:
   ```bash
   sudo cp deploy/com.mobilepi.daemon.plist /Library/LaunchDaemons/
   sudo launchctl load /Library/LaunchDaemons/com.mobilepi.daemon.plist
   ```
