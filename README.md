# pfSense NIC + gateway textfile collector

## Problem

pfSense's node-exporter doesn't have crucial NIC metrics.
- SFP power/temperature
- Link status
- Link speed

...nor any **multi-WAN gateway** metrics:
- Per-gateway reachability / RTT / packet loss (dpinger)
- Which gateway currently owns the default route (i.e. did we fail over?)

So alerting on link flapping, SFP temp, or a **WAN failover/failback** via prom/alertmanager
isn't feasible out of the box.

Enter this project, to throw a couple of shell scripts at the problem.

## Scripts

| Script | Output file | What it exports |
|---|---|---|
| `nic_collector.sh` | `nic_ifconfig.prom` | link status, link speed, SFP diagnostics |
| `gateway_collector.sh` | `gateways.prom` | dpinger gateway RTT/loss/up + active default route |

Both are pure `/bin/sh` + `awk` (no PHP), write atomically (`tmp` + `mv`), and take an
optional output-dir argument (default `/var/tmp/node_exporter`).

`gateway_collector.sh` reads the dpinger control sockets directly
(`/var/run/dpinger_<name>~<src>~<monitor>.sock`, which reply `<name> <rtt_us> <stddev_us> <loss_pct>`)
and resolves each gateway's egress interface from its source IP, so it can flag the one that
currently owns the IPv4 default route — the authoritative failover signal.

## Usage

1. Install `node_exporter` and `cron` via Package Manager

2. Copy scripts to pfSense
   ```
   # scp nic_collector.sh gateway_collector.sh admin@192.0.2.1:~
   ```

3. Set up cron (Services -> Cron). Gateways change fast, so collect them more often:
   ```
   */5 * * * * /bin/sh /root/nic_collector.sh
   *   * * * * /bin/sh /root/gateway_collector.sh
   ```

## Example metrics

### NIC (`nic_ifconfig.prom`)

```
# HELP node_ifconfig_up 1 if the interface carrier is active, 0 otherwise.
# TYPE node_ifconfig_up gauge
node_ifconfig_up{device="ix1"} 1
node_ifconfig_up{device="ix3"} 1
# HELP node_ifconfig_link_speed_bps Negotiated link speed in bits per second.
# TYPE node_ifconfig_link_speed_bps gauge
node_ifconfig_link_speed_bps{device="ix1"} 10000000000
node_ifconfig_link_speed_bps{device="ix3"} 1000000000
# HELP node_ifconfig_sfp_temperature_celsius SFP module temperature in degrees Celsius.
# TYPE node_ifconfig_sfp_temperature_celsius gauge
node_ifconfig_sfp_temperature_celsius{device="ix1"} 51.43
# ... sfp_info / voltage / rx_power_mw / rx_power_dbm / tx_bias_ma also exported
```

### Gateways (`gateways.prom`)

```
# HELP node_gateway_info Gateway metadata (egress interface, source and monitor IP). Always 1.
# TYPE node_gateway_info gauge
node_gateway_info{gateway="WAN_DHCP",interface="ix1",source="198.51.100.25",monitor="198.51.100.1"} 1
node_gateway_info{gateway="BACKUP",interface="ix3",source="203.0.113.52",monitor="203.0.113.1"} 1
# HELP node_gateway_up 1 if the gateway monitor is reachable (loss < 100%), 0 otherwise.
# TYPE node_gateway_up gauge
node_gateway_up{gateway="WAN_DHCP"} 1
node_gateway_up{gateway="BACKUP"} 1
# HELP node_gateway_default 1 if this gateway currently owns the IPv4 default route, 0 otherwise.
# TYPE node_gateway_default gauge
node_gateway_default{gateway="WAN_DHCP"} 1
node_gateway_default{gateway="BACKUP"} 0
# HELP node_gateway_rtt_seconds Smoothed round-trip time to the monitor target, in seconds.
# TYPE node_gateway_rtt_seconds gauge
node_gateway_rtt_seconds{gateway="WAN_DHCP"} 0.003765000
node_gateway_rtt_seconds{gateway="BACKUP"} 0.012108000
# node_gateway_rtt_stddev_seconds and node_gateway_loss_ratio also exported
```

## Alerting (failover / failback)

`node_gateway_default` is the cleanest signal: it tracks the actual default route, so it flips
exactly when pfSense moves traffic between WANs. The firing alert is the failover; its resolution
is the failback. See [`examples/prometheus-alerts.yml`](examples/prometheus-alerts.yml).

```yaml
- alert: WANFailover
  expr: node_gateway_default{gateway="WAN_DHCP"} == 0
  for: 1m
  labels: { severity: warning }
  annotations:
    summary: "pfSense failed over off the primary WAN"
    description: "Default route is no longer on WAN_DHCP. Active: {{ ... }}."
```

> Note: `node_gateway_up` is a simple reachable/unreachable flag (loss < 100%); it does **not**
> reproduce dpinger's debounced latency/loss alarm thresholds. For "did we actually fail over",
> prefer `node_gateway_default`. For early-warning on a degrading link, alert on
> `node_gateway_loss_ratio` / `node_gateway_rtt_seconds`.
