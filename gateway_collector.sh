#!/bin/sh
# gateway_collector.sh - Export pfSense dpinger gateway + default-route metrics
# as a Prometheus textfile.
#
# Exports per-gateway reachability, smoothed RTT, RTT stddev and packet loss
# (read straight from the dpinger control sockets) plus which gateway currently
# owns the IPv4 default route - the authoritative multi-WAN failover/failback
# signal. No PHP dependency; pure /bin/sh + awk.
#
# Usage: gateway_collector.sh [output_dir]
#   output_dir defaults to /var/tmp/node_exporter

OUTPUT_DIR="${1:-/var/tmp/node_exporter}"
OUTPUT_FILE="${OUTPUT_DIR}/gateways.prom"
TMP_FILE="${OUTPUT_FILE}.$$"

mkdir -p "${OUTPUT_DIR}"

{
    # Active IPv4 default route egress interface (blank if no default route).
    printf 'DEFIF %s\n' \
        "$(route -n get -inet default 2>/dev/null | awk '/interface:/{print $2; exit}')"

    # Local source IP -> interface name (inet only), used to resolve each
    # gateway's egress interface from its dpinger source address.
    /sbin/ifconfig 2>/dev/null | awk '
        /^[a-z]/   { ifn = $1; sub(/:$/, "", ifn) }
        /^\tinet / { print "IFMAP " $2 " " ifn }'

    # One line per gateway from its dpinger control socket. The socket file name
    # encodes  dpinger_<name>~<srcip>~<monitorip>.sock  and, on connect, dpinger
    # replies  "<name> <rtt_us> <stddev_us> <loss_pct>".
    for sock in /var/run/dpinger_*.sock; do
        [ -S "$sock" ] || continue
        base=$(basename "$sock" .sock)
        rest=${base#dpinger_}
        name=${rest%%~*}
        rest=${rest#*~}
        srcip=${rest%%~*}
        monip=${rest##*~}
        vals=$(nc -U -w1 "$sock" </dev/null 2>/dev/null)
        [ -n "$vals" ] || continue
        set -- $vals                      # $2=rtt_us $3=stddev_us $4=loss_pct
        printf 'GW %s %s %s %s %s %s\n' "$name" "$srcip" "$monip" "$2" "$3" "$4"
    done
} | awk '
    $1 == "DEFIF" { defif = $2; next }
    $1 == "IFMAP" { ip2if[$2] = $3; next }
    $1 == "GW" {
        name = $2; srcip = $3; monip = $4
        rtt_us = $5; stddev_us = $6; loss_pct = $7

        ifn = (srcip in ip2if) ? ip2if[srcip] : ""
        is_default = (ifn != "" && ifn == defif) ? 1 : 0
        up = (loss_pct + 0 < 100) ? 1 : 0

        info_out    = info_out    sprintf("node_gateway_info{gateway=\"%s\",interface=\"%s\",source=\"%s\",monitor=\"%s\"} 1\n", name, ifn, srcip, monip)
        up_out      = up_out      sprintf("node_gateway_up{gateway=\"%s\"} %d\n", name, up)
        default_out = default_out sprintf("node_gateway_default{gateway=\"%s\"} %d\n", name, is_default)
        rtt_out     = rtt_out     sprintf("node_gateway_rtt_seconds{gateway=\"%s\"} %.9f\n", name, rtt_us / 1000000)
        stddev_out  = stddev_out  sprintf("node_gateway_rtt_stddev_seconds{gateway=\"%s\"} %.9f\n", name, stddev_us / 1000000)
        loss_out    = loss_out    sprintf("node_gateway_loss_ratio{gateway=\"%s\"} %.4f\n", name, loss_pct / 100)
    }
    END {
        printf "# HELP node_gateway_info Gateway metadata (egress interface, source and monitor IP). Always 1.\n"
        printf "# TYPE node_gateway_info gauge\n";              printf "%s", info_out

        printf "# HELP node_gateway_up 1 if the gateway monitor is reachable (loss < 100%%), 0 otherwise.\n"
        printf "# TYPE node_gateway_up gauge\n";                printf "%s", up_out

        printf "# HELP node_gateway_default 1 if this gateway currently owns the IPv4 default route, 0 otherwise.\n"
        printf "# TYPE node_gateway_default gauge\n";           printf "%s", default_out

        printf "# HELP node_gateway_rtt_seconds Smoothed round-trip time to the monitor target, in seconds.\n"
        printf "# TYPE node_gateway_rtt_seconds gauge\n";       printf "%s", rtt_out

        printf "# HELP node_gateway_rtt_stddev_seconds Round-trip time standard deviation, in seconds.\n"
        printf "# TYPE node_gateway_rtt_stddev_seconds gauge\n"; printf "%s", stddev_out

        printf "# HELP node_gateway_loss_ratio Fraction of probe packets lost (0..1).\n"
        printf "# TYPE node_gateway_loss_ratio gauge\n";        printf "%s", loss_out
    }
' > "${TMP_FILE}"

mv "${TMP_FILE}" "${OUTPUT_FILE}"
