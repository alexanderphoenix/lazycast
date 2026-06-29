#!/bin/bash
# Lazycast WFD/Miracast receiver for Samsung Galaxy S24
# wpa_supplicant@wlan0.service must be running before this starts.

LAZYDIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$LAZYDIR"
WPACTL=/run/wpa_supplicant

exec > >(stdbuf -oL tee -a /var/log/lazycast.log) 2>&1
echo "=== lazycast $(date) ==="

cleanup() {
    trap - EXIT INT TERM
    echo "--- Stopping ---"
    pkill ffplay 2>/dev/null
    sudo kill "$(cat /tmp/lazycast_dnsmasq.pid 2>/dev/null)" 2>/dev/null
    sudo pkill -f "dnsmasq.*192.168.173" 2>/dev/null
    sudo rm -f /tmp/lazycast_dnsmasq.pid /tmp/lazycast_dnsmasq.leases /tmp/lazycast_dnsmasq.log
    sudo ip addr del 192.168.173.1/24 dev wlan0 2>/dev/null
    echo "Done."
}

shutdown() {
    cleanup
    exit 0
}

trap cleanup EXIT
trap shutdown INT TERM

# Wait for wpa_supplicant to be available.
# Use -iwlan0 explicitly: the p2p-wlan0-X group socket is root:root and
# wpa_cli without -i picks it first, gets permission denied, never gets PONG.
for i in $(seq 1 15); do
    wpa_cli -p"$WPACTL" -iwlan0 ping 2>/dev/null | grep -q PONG && break
    echo "Waiting for wpa_supplicant... ($i/15)"
    sleep 2
done
if ! wpa_cli -p"$WPACTL" -iwlan0 ping 2>/dev/null | grep -q PONG; then
    echo "ERROR: wpa_supplicant not responding at $WPACTL"
    exit 1
fi
echo "wpa_supplicant ready"

# Remove any stale P2P group from a previous run
p2pdev_init=$(wpa_cli -p"$WPACTL" interface 2>/dev/null | grep "p2p-dev" | tail -1)
stale=$(ip link show 2>/dev/null | grep -oE 'p2p-wlan[0-9]+-[0-9]+' | head -1)
if [ -n "$stale" ]; then
    echo "Removing stale P2P group: $stale"
    sudo wpa_cli -p"$WPACTL" p2p_group_remove "$stale" 2>/dev/null
    sleep 2
fi

while :; do
    p2pdev=$(wpa_cli -p"$WPACTL" interface 2>/dev/null | grep "p2p-dev" | tail -1)
    p2piface=$(ip link show 2>/dev/null | grep -oE 'p2p-wlan[0-9]+-[0-9]+' | head -1)

    if [ -z "$p2piface" ]; then
        echo "--- Creating P2P group ---"
        wpa_cli -p"$WPACTL" -i"$p2pdev" p2p_flush 2>/dev/null
        wpa_cli -p"$WPACTL" -i"$p2pdev" set device_name "$(hostname)"
        wpa_cli -p"$WPACTL" -i"$p2pdev" set device_type 7-0050F204-1
        wpa_cli -p"$WPACTL" -i"$p2pdev" wfd_subelem_set 0 000600111c44012c
        wpa_cli -p"$WPACTL" -i"$p2pdev" wfd_subelem_set 1 0006000000000000
        wpa_cli -p"$WPACTL" -i"$p2pdev" wfd_subelem_set 6 000700000000000000

        while [ -z "$p2piface" ]; do
            result=$(wpa_cli -p"$WPACTL" -i"$p2pdev" p2p_group_add freq=2412 2>/dev/null)
            echo "p2p_group_add: $result"
            sleep 3
            p2piface=$(ip link show 2>/dev/null | grep -oE 'p2p-wlan[0-9]+-[0-9]+' | head -1)
        done
    fi

    ssid=$(wpa_cli -p"$WPACTL" -i"$p2piface" status 2>/dev/null | grep '^ssid=' | cut -d= -f2)
    echo "--- P2P interface: $p2piface  SSID: $ssid ---"

    # Assign IP on both the P2P virtual interface and wlan0 (physical).
    # brcmfmac can deliver P2P client frames to wlan0 rather than p2p-wlan0-X,
    # so dnsmasq must be reachable on both.
    sudo ip addr add 192.168.173.1/24 dev "$p2piface" 2>/dev/null || true
    sudo ip addr add 192.168.173.1/24 dev wlan0 2>/dev/null || true
    sudo ip link set "$p2piface" up
    sudo ip link set wlan0 up
    sleep 1

    sudo kill "$(cat /tmp/lazycast_dnsmasq.pid 2>/dev/null)" 2>/dev/null
    sudo pkill -f "dnsmasq.*192.168.173" 2>/dev/null
    sleep 1
    sudo rm -f /tmp/lazycast_dnsmasq.log /tmp/lazycast_dnsmasq.pid /tmp/lazycast_dnsmasq.leases
    sudo dnsmasq \
        --except-interface=lo \
        --except-interface=eth0 \
        --dhcp-range=192.168.173.50,192.168.173.150,255.255.255.0,1h \
        --dhcp-authoritative --port=0 --no-resolv --no-hosts \
        --pid-file=/tmp/lazycast_dnsmasq.pid \
        --dhcp-leasefile=/tmp/lazycast_dnsmasq.leases \
        --log-facility=/tmp/lazycast_dnsmasq.log --log-dhcp
    sleep 1
    ss -ulnp | grep ':67' || echo "WARNING: nothing on :67"

    echo ""
    echo ">>> READY — open Smart View on Samsung and tap '$(hostname)' <<<"
    echo ""

    while :; do
        echo "[$(date '+%H:%M:%S')] WPS PBC on $p2piface"
        sudo wpa_cli -p"$WPACTL" -i"$p2piface" wps_pbc

        connected=0
        for i in $(seq 1 30); do
            stations=$(sudo wpa_cli -p"$WPACTL" -i"$p2piface" all_sta 2>/dev/null)
            if echo "$stations" | grep -qE '([0-9a-f]{2}:){5}[0-9a-f]{2}'; then
                echo "[$(date '+%H:%M:%S')] Phone associated"
                connected=1; break
            fi
            printf "."
            sleep 2
        done
        echo ""

        if [ $connected -eq 1 ]; then
            sudo tcpdump -i any -n '(udp port 67 or udp port 68)' \
                -w /tmp/lazycast_dhcp.pcap 2>/dev/null &
            TCPDUMP_PID=$!
            sleep 1

            phone_ip=""
            for j in $(seq 1 25); do
                phone_ip=$(awk '{print $3}' /tmp/lazycast_dnsmasq.leases 2>/dev/null | head -1)
                [ -z "$phone_ip" ] && \
                    phone_ip=$(ip neigh show dev "$p2piface" 2>/dev/null \
                               | grep REACHABLE | awk '{print $1}' \
                               | grep -v '^192\.168\.173\.1$' | head -1)
                [ -n "$phone_ip" ] && break
                printf "."
                sleep 1
            done
            echo ""
            sudo kill $TCPDUMP_PID 2>/dev/null; sleep 0.5

            pcap_size=$(wc -c < /tmp/lazycast_dhcp.pcap 2>/dev/null || echo 0)
            echo "DHCP pcap: ${pcap_size} bytes | Leases: $(cat /tmp/lazycast_dnsmasq.leases 2>/dev/null || echo none)"
            [ "$pcap_size" -gt 24 ] && sudo tcpdump -r /tmp/lazycast_dhcp.pcap -n 2>/dev/null | head -20

            if [ -z "$phone_ip" ]; then
                echo "WARNING: no phone IP"
                phone_ip=192.168.173.80
            fi

            echo "Phone IP: $phone_ip — starting d2.py"
            # Capture first 200 UDP packets on port 1028 to see Samsung's stream format
            sudo tcpdump -i any -n "udp port 1028" -c 200 -w /tmp/lazycast_udp1028.pcap 2>/dev/null &
            UDP_TCPDUMP_PID=$!
            python3 ./d2.py "$phone_ip" 2>&1
            sudo kill $UDP_TCPDUMP_PID 2>/dev/null
            sleep 0.5
            udp_size=$(wc -c < /tmp/lazycast_udp1028.pcap 2>/dev/null || echo 0)
            echo "UDP 1028 pcap: ${udp_size} bytes"
            [ "$udp_size" -gt 24 ] && sudo tcpdump -r /tmp/lazycast_udp1028.pcap -n 2>/dev/null | head -10
            echo "d2.py exited, restarting loop"
        else
            echo "Timeout — re-enabling WPS"
        fi

        ip link show "$p2piface" &>/dev/null || { echo "P2P gone — restarting outer loop"; break; }
    done
done
