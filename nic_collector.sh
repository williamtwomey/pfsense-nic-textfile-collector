#!/bin/sh
# nic_collector.sh - Parse ifconfig -v into Prometheus textfile metrics
# Exports: link status, negotiated speed, SFP diagnostics
# Usage: nic_collector.sh [output_dir]
#   output_dir defaults to /var/tmp/node_exporter

OUTPUT_DIR="${1:-/var/tmp/node_exporter}"
OUTPUT_FILE="${OUTPUT_DIR}/nic_ifconfig.prom"
TMP_FILE="${OUTPUT_FILE}.$$"

mkdir -p "${OUTPUT_DIR}"

/sbin/ifconfig -v | awk '
function media_to_speed(m) {
    if (m ~ /100000[Bb]ase/) return 100000000000
    if (m ~ /40[Gg][Bb]ase/)  return 40000000000
    if (m ~ /25[Gg][Bb]ase/)  return 25000000000
    if (m ~ /10[Gg][Bb]ase/ || m ~ /10[Gg]base/) return 10000000000
    if (m ~ /5000[Bb]ase/)    return 5000000000
    if (m ~ /2500[Bb]ase/)    return 2500000000
    if (m ~ /1000[Bb]ase/ || m ~ /1000BASE/) return 1000000000
    if (m ~ /100[Bb]ase/)     return 100000000
    if (m ~ /10[Bb]ase/)      return 10000000
    return 0
}

function emit() {
    if (!has_status) return

    status_val = (status == "active") ? 1 : 0
    up_out = up_out sprintf("node_ifconfig_up{device=\"%s\"} %d\n", iface, status_val)

    if (speed > 0)
        speed_out = speed_out sprintf("node_ifconfig_link_speed_bps{device=\"%s\"} %.0f\n", iface, speed)

    if (plugged != "") {
        gsub(/"/, "\\\"", plugged)
        gsub(/"/, "\\\"", vendor)
        gsub(/"/, "\\\"", pn)
        gsub(/"/, "\\\"", sn)
        sfp_info_out = sfp_info_out sprintf("node_ifconfig_sfp_info{device=\"%s\",type=\"%s\",vendor=\"%s\",part_number=\"%s\",serial=\"%s\"} 1\n", iface, plugged, vendor, pn, sn)
    }
    if (sfp_temp != "")
        sfp_temp_out = sfp_temp_out sprintf("node_ifconfig_sfp_temperature_celsius{device=\"%s\"} %s\n", iface, sfp_temp)
    if (sfp_voltage != "")
        sfp_volt_out = sfp_volt_out sprintf("node_ifconfig_sfp_voltage_volts{device=\"%s\"} %s\n", iface, sfp_voltage)
}

# Start of a new interface block (line starts with non-whitespace)
/^[a-zA-Z]/ {
    if (iface != "") emit()

    n = index($1, ":")
    iface = substr($1, 1, n - 1)
    has_status = 0; status = ""; speed = 0
    plugged = ""; vendor = ""; pn = ""; sn = ""
    sfp_temp = ""; sfp_voltage = ""
}

/^\tstatus:/ {
    has_status = 1
    status = $2
}

/^\tmedia:/ {
    line = $0
    n1 = index(line, "(")
    if (n1 > 0) {
        n2 = index(line, ")")
        media_info = substr(line, n1 + 1, n2 - n1 - 1)
        split(media_info, mp, " ")
        speed = media_to_speed(mp[1])
    }
}

/^\tplugged:/ {
    line = $0
    sub(/^\tplugged: /, "", line)
    plugged = line
}

/^\tvendor:/ {
    line = $0
    sub(/^\tvendor: /, "", line)
    n = split(line, p, " ")
    for (i = 1; i <= n; i++) {
        if (p[i] == "PN:") pn = p[i + 1]
        else if (p[i] == "SN:") sn = p[i + 1]
    }
    vn = index(line, " PN:")
    if (vn > 0) vendor = substr(line, 1, vn - 1)
}

/^\tmodule temperature:/ {
    n = split($0, p, " ")
    for (i = 1; i <= n; i++) {
        if (p[i] == "temperature:") sfp_temp = p[i + 1]
        if (p[i] == "voltage:") sfp_voltage = p[i + 1]
    }
}

/^\tlane [0-9]/ {
    lane = $2
    sub(/:$/, "", lane)

    line = $0
    n = split(line, p, " ")
    rx_mw = ""; rx_dbm = ""; txb = ""
    for (i = 1; i <= n; i++) {
        if (p[i] == "power:" && i > 1 && p[i - 1] == "RX") rx_mw = p[i + 1]
        if (p[i] == "bias:") txb = p[i + 1]
    }
    # Extract dBm value from parentheses
    n1 = index(line, "(")
    if (n1 > 0) {
        n2 = index(line, " dBm)")
        if (n2 > n1) rx_dbm = substr(line, n1 + 1, n2 - n1 - 1)
    }

    if (rx_mw != "")
        sfp_rx_mw_out = sfp_rx_mw_out sprintf("node_ifconfig_sfp_rx_power_mw{device=\"%s\",lane=\"%s\"} %s\n", iface, lane, rx_mw)
    if (rx_dbm != "")
        sfp_rx_dbm_out = sfp_rx_dbm_out sprintf("node_ifconfig_sfp_rx_power_dbm{device=\"%s\",lane=\"%s\"} %s\n", iface, lane, rx_dbm)
    if (txb != "")
        sfp_tx_out = sfp_tx_out sprintf("node_ifconfig_sfp_tx_bias_ma{device=\"%s\",lane=\"%s\"} %s\n", iface, lane, txb)
}

END {
    if (iface != "") emit()

    printf "# HELP node_ifconfig_up 1 if the interface carrier is active, 0 otherwise.\n"
    printf "# TYPE node_ifconfig_up gauge\n"
    printf "%s", up_out

    if (speed_out != "") {
        printf "# HELP node_ifconfig_link_speed_bps Negotiated link speed in bits per second.\n"
        printf "# TYPE node_ifconfig_link_speed_bps gauge\n"
        printf "%s", speed_out
    }

    if (sfp_info_out != "") {
        printf "# HELP node_ifconfig_sfp_info SFP module identification. Always 1.\n"
        printf "# TYPE node_ifconfig_sfp_info gauge\n"
        printf "%s", sfp_info_out
    }
    if (sfp_temp_out != "") {
        printf "# HELP node_ifconfig_sfp_temperature_celsius SFP module temperature in degrees Celsius.\n"
        printf "# TYPE node_ifconfig_sfp_temperature_celsius gauge\n"
        printf "%s", sfp_temp_out
    }
    if (sfp_volt_out != "") {
        printf "# HELP node_ifconfig_sfp_voltage_volts SFP module supply voltage in Volts.\n"
        printf "# TYPE node_ifconfig_sfp_voltage_volts gauge\n"
        printf "%s", sfp_volt_out
    }
    if (sfp_rx_mw_out != "") {
        printf "# HELP node_ifconfig_sfp_rx_power_mw SFP received optical power in milliwatts.\n"
        printf "# TYPE node_ifconfig_sfp_rx_power_mw gauge\n"
        printf "%s", sfp_rx_mw_out
    }
    if (sfp_rx_dbm_out != "") {
        printf "# HELP node_ifconfig_sfp_rx_power_dbm SFP received optical power in dBm.\n"
        printf "# TYPE node_ifconfig_sfp_rx_power_dbm gauge\n"
        printf "%s", sfp_rx_dbm_out
    }
    if (sfp_tx_out != "") {
        printf "# HELP node_ifconfig_sfp_tx_bias_ma SFP TX laser bias current in milliamps.\n"
        printf "# TYPE node_ifconfig_sfp_tx_bias_ma gauge\n"
        printf "%s", sfp_tx_out
    }
}
' > "${TMP_FILE}"

mv "${TMP_FILE}" "${OUTPUT_FILE}"
