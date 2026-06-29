# lazycast Raspberry Pi Smart View receiver

This fork is configured as a Miracast/Wi-Fi Display receiver for a Raspberry Pi,
tested with Samsung Smart View from a Galaxy S24 Ultra. It creates a Wi-Fi
Direct group, gives the phone an address with `dnsmasq`, negotiates the WFD
stream over RTSP, and plays the received MPEG-TS stream with GStreamer.

The project is based on Hsun-Wei Cho's original
[`homeworkc/lazycast`](https://github.com/homeworkc/lazycast). Most of the WFD
negotiation and control flow comes from that work; this fork's README documents
the current Raspberry Pi deployment path used here.

## Hardware

Known working target:

- Raspberry Pi 3 Model B Rev 1.2
- Raspberry Pi Wi-Fi used for Wi-Fi Direct/P2P
- HDMI display/audio output
- Stable 5 V power supply

Use a good power supply and cable. If the Pi reports undervoltage or throttling,
Miracast playback can stutter:

```sh
vcgencmd get_throttled
```

`throttled=0x0` is ideal. Values such as `0x50005` indicate undervoltage and
previous/current throttling. Also avoid placing unshielded HDMI displays or
portable monitors directly on the Pi; that can introduce audible interference.

## Operating system

Use Raspberry Pi OS with normal kernel Wi-Fi Direct support. This fork has been
used on a modern Raspberry Pi OS image where the legacy `/opt/vc` OpenMAX build
environment is not present. The current Samsung path does not require compiling
the legacy in-tree players.

Enable SSH if you want to administer the Pi remotely.

## Install packages

```sh
sudo apt update
sudo apt install -y \
  git python3 \
  wpasupplicant wireless-tools iw \
  dnsmasq tcpdump \
  gstreamer1.0-tools \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-libav \
  alsa-utils
```

The AAC audio path needs a GStreamer AAC decoder. On the tested Pi this is
provided by `faad`/GStreamer plugins from the packages above.

## Clone this fork

```sh
cd /home/pi
git clone https://github.com/alexanderphoenix/lazycast.git
cd lazycast
```

If you use a different user or directory, adjust the paths in the examples
below.

`all.sh` uses `sudo` for Wi-Fi Direct setup, interface configuration, `dnsmasq`,
and packet capture. Manual runs need sudo access. The systemd example below runs
as a system service, so those commands run as root.

## Wi-Fi setup

`all.sh` expects `wpa_supplicant` to be running and reachable at
`/run/wpa_supplicant`. On many Raspberry Pi OS installs this is already true.
Check with:

```sh
wpa_cli -p/run/wpa_supplicant -iwlan0 ping
```

Expected output:

```text
PONG
```

If it is not running:

```sh
sudo systemctl enable --now wpa_supplicant@wlan0.service
```

Do not run NetworkManager or other Wi-Fi managers that fight `wpa_supplicant`
for control of `wlan0` while casting. Background scanning can cause glitches.

## Run manually

From the repository directory:

```sh
./all.sh
```

Wait for:

```text
>>> READY — open Smart View on Samsung and tap '<hostname>' <<<
```

Then open Smart View on the Samsung phone and select the Pi hostname.
This Samsung path uses WPS push-button mode. The original lazycast PIN
`31415926` is still present in legacy scripts, but Samsung Smart View did not
associate reliably with the fixed PIN flow on the tested setup.

Logs are written to:

```text
/var/log/lazycast.log
/tmp/gst.log
/tmp/lazycast_dnsmasq.log
```

The Pi uses:

- `192.168.173.1/24` for the Wi-Fi Direct network
- DHCP range `192.168.173.50` to `192.168.173.150`
- RTP/UDP port `1028`
- RTSP/TCP port `7236` on the phone side

## Run on boot with systemd

Create a system service for the checkout path you used. For `/home/pi/lazycast`:

```ini
[Unit]
Description=lazycast Smart View receiver
After=network.target wpa_supplicant@wlan0.service

[Service]
Type=simple
WorkingDirectory=/home/pi/lazycast
ExecStart=/home/pi/lazycast/all.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

One way to install that unit is:

```sh
sudo tee /etc/systemd/system/lazycast.service >/dev/null <<'EOF'
[Unit]
Description=lazycast Smart View receiver
After=network.target wpa_supplicant@wlan0.service

[Service]
Type=simple
WorkingDirectory=/home/pi/lazycast
ExecStart=/home/pi/lazycast/all.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now lazycast.service
```

Watch logs:

```sh
sudo journalctl -u lazycast.service -f
tail -f /var/log/lazycast.log
```

The service runs independently of user login. It is fine to disable Raspberry Pi
auto-login and boot to the CLI, provided `lazycast.service` is enabled.

## Current playback path

For Samsung Smart View this fork uses the GStreamer path in `d2.py`:

- WFD audio is advertised as AAC.
- RTP MPEG-TS is received on UDP `1028`.
- `rtpjitterbuffer` smooths Wi-Fi packet timing.
- H.264 video is decoded with `v4l2h264dec` and displayed with `kmssink`.
- AAC audio is decoded by GStreamer and played to HDMI ALSA (`default:CARD=b1`).

The pipeline is tuned for 1080p at approximately 25-30 fps on a Pi 3. It avoids
dropping compressed H.264 before decode, which helps prevent visible artifacts
during fast motion.

## Troubleshooting

### Smart View cannot find or connect to the Pi

Check that `all.sh` printed the READY message, then inspect:

```sh
ip link show
wpa_cli -p/run/wpa_supplicant interface
sudo journalctl -u wpa_supplicant@wlan0.service --no-pager -n 100
tail -100 /var/log/lazycast.log
```

If a stale P2P interface exists, restart the service or reboot.

### Phone connects but no video appears

Check whether GStreamer failed:

```sh
cat /tmp/gst.log
ps -ef | grep gst-launch
```

Confirm the needed GStreamer elements exist:

```sh
gst-inspect-1.0 rtpjitterbuffer rtpmp2tdepay tsdemux h264parse v4l2h264dec kmssink faad alsasink
```

### Audio missing

Confirm HDMI audio exists:

```sh
aplay -l
amixer -c b1 sget PCM
```

The expected HDMI card on the tested Pi is `bcm2835 HDMI 1`, ALSA card `b1`.
If your card name differs, update the `alsasink device=` value in `d2.py`.

### Stutter or brief freezes

First check power:

```sh
vcgencmd get_throttled
vcgencmd measure_temp
```

Undervoltage/throttling is a common cause of periodic stutter on Pi 3. Use a
better power supply/cable before chasing pipeline settings.

Also keep the phone close to the Pi and avoid other Wi-Fi traffic/scanning on
the Pi during casting.

### Buzzing or noise

If buzzing continues after casting stops, confirm no playback process is alive:

```sh
ps -ef | grep -E 'gst-launch|d2.py|aplay'
fuser -v /dev/snd/*
```

Mute HDMI audio manually:

```sh
amixer -c b1 sset PCM mute
```

If the noise is physical interference, move the display, HDMI cable, or audio
amplifier away from the Pi.

## Notes

- HDCP is not supported.
- Pairing persistence can vary by phone/OS. If connection attempts become
  confused, forget the display on the phone and restart `lazycast`.
- The legacy native players under `player/` and `h264/` are retained from the
  original project, but this fork's Samsung path currently uses GStreamer.
- Miracast over Infrastructure files from the original project remain in the
  repo, but they are not part of the deployment path documented here.
