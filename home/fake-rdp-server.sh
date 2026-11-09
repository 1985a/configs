#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# Fake RDP Honeypot para Proxmox LXC
# Ejecutar en el HOST Proxmox como root.
#
# Configuración por defecto:
#   CTID:   126
#   Bridge: vmbr1
#   VLAN:   1001
#   MAC:    02:10:01:33:89:24
#   IP:     DHCP
#   Puerto: TCP 3389
#   Base:   Debian 13
#
# El script NO borra contenedores existentes.
# ==========================================================

DEFAULT_CTID="126"
DEFAULT_HOSTNAME="fake-rdp-honeypot"

DEFAULT_BRIDGE="vmbr1"
DEFAULT_VLAN_TAG="1001"
DEFAULT_MACADDR="02:10:01:33:89:24"

DEFAULT_MEMORY="256"
DEFAULT_SWAP="128"
DEFAULT_CORES="1"
DEFAULT_ROOTFS_GB="4"

DEFAULT_TEMPLATE_STORAGE="local"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[AVISO]${NC} $*"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "No encuentro el comando requerido: $1"
}

ask_default() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "$prompt [$default]: " value
    echo "${value:-$default}"
}

valid_mac() {
    [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

pct_exec() {
    pct exec "$CTID" -- bash -lc "$1"
}

wait_for_ct_running() {
    local _

    for _ in $(seq 1 30); do
        if pct status "$CTID" 2>/dev/null | grep -q "status: running"; then
            return 0
        fi
        sleep 1
    done

    return 1
}

wait_for_network() {
    local _

    echo "Esperando red/DHCP dentro del contenedor..."

    for _ in $(seq 1 60); do
        if pct exec "$CTID" -- bash -lc "ip -4 route show default >/dev/null 2>&1"; then
            ok "El contenedor ya tiene ruta por defecto."
            return 0
        fi
        sleep 2
    done

    warn "No pude confirmar ruta por defecto dentro del contenedor."
    warn "Si no hay DHCP en VLAN 1001, apt fallará."
    return 1
}

echo
echo "======================================================="
echo " Instalador Fake RDP Honeypot para Proxmox LXC"
echo " Debian 13 / vmbr1 / VLAN 1001 / DHCP / TCP 3389"
echo "======================================================="
echo

[[ $EUID -eq 0 ]] || die "Debes ejecutar este script como root en el host Proxmox."

need_cmd pct
need_cmd pveam
need_cmd pvesm

if ! command -v apt >/dev/null 2>&1; then
    die "Este script está pensado para ejecutarse en un host Proxmox basado en Debian."
fi

echo "Configuración del contenedor:"
echo

CTID="$(ask_default "ID del contenedor LXC" "$DEFAULT_CTID")"
HOSTNAME="$(ask_default "Hostname del contenedor" "$DEFAULT_HOSTNAME")"

AUTO_STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')"
if [[ -z "${AUTO_STORAGE:-}" ]]; then
    AUTO_STORAGE="local-lvm"
fi

STORAGE="$(ask_default "Storage para el rootfs del contenedor" "$AUTO_STORAGE")"
ROOTFS_GB="$(ask_default "Tamaño del disco en GB" "$DEFAULT_ROOTFS_GB")"
CORES="$(ask_default "CPU cores" "$DEFAULT_CORES")"
MEMORY="$(ask_default "Memoria RAM MB" "$DEFAULT_MEMORY")"
SWAP="$(ask_default "Swap MB" "$DEFAULT_SWAP")"

echo
echo "Configuración de red:"
echo

BRIDGE="$(ask_default "Bridge Proxmox" "$DEFAULT_BRIDGE")"
VLAN_TAG="$(ask_default "VLAN tag" "$DEFAULT_VLAN_TAG")"
MACADDR="$(ask_default "MAC address para reserva DHCP" "$DEFAULT_MACADDR")"

valid_mac "$MACADDR" || die "La MAC '$MACADDR' no tiene un formato válido."

NETCFG="name=eth0,bridge=${BRIDGE},tag=${VLAN_TAG},hwaddr=${MACADDR},ip=dhcp"

echo
echo "Se aplicará esta red al contenedor:"
echo "  Bridge: ${BRIDGE}"
echo "  VLAN:   ${VLAN_TAG}"
echo "  MAC:    ${MACADDR}"
echo "  IP:     DHCP"
echo "  Puerto: TCP 3389"
echo

warn "Registra esta MAC en tu DHCP:"
warn "$MACADDR"
echo

warn "Este script NO borra contenedores existentes."
warn "Si el CTID $CTID ya existe, el script se detendrá para evitar pérdida de datos."
echo

if pct status "$CTID" >/dev/null 2>&1; then
    die "Ya existe un contenedor con ID $CTID. Usa otro ID o elimina el anterior manualmente solo si estás seguro."
fi

echo
echo "Buscando plantilla Debian 13 disponible localmente..."

LOCAL_TEMPLATE_REF="$(pveam list "$DEFAULT_TEMPLATE_STORAGE" 2>/dev/null \
    | awk '/debian-13-standard.*amd64.*tar/ {print $1}' \
    | sort -V \
    | tail -n 1)"

if [[ -n "${LOCAL_TEMPLATE_REF:-}" ]]; then
    TEMPLATE_REF="$LOCAL_TEMPLATE_REF"
    ok "Usando plantilla local Debian 13 ya descargada: $TEMPLATE_REF"
else
    warn "No encontré plantilla Debian 13 local en $DEFAULT_TEMPLATE_STORAGE."
    echo "Actualizando lista de plantillas disponibles..."
    pveam update >/dev/null

    TEMPLATE="$(pveam available --section system \
        | awk '/debian-13-standard.*amd64.*tar/ {print $2}' \
        | sort -V \
        | tail -n 1)"

    if [[ -z "$TEMPLATE" ]]; then
        die "No pude encontrar una plantilla Debian 13 disponible para descargar."
    fi

    echo "Descargando plantilla Debian 13 en storage '$DEFAULT_TEMPLATE_STORAGE': $TEMPLATE"
    pveam download "$DEFAULT_TEMPLATE_STORAGE" "$TEMPLATE"

    TEMPLATE_REF="${DEFAULT_TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
    ok "Plantilla Debian 13 descargada: $TEMPLATE_REF"
fi

echo
echo "Creando contenedor LXC $CTID..."

pct create "$CTID" "$TEMPLATE_REF" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${ROOTFS_GB}" \
    --net0 "$NETCFG" \
    --unprivileged 1 \
    --features nesting=0 \
    --onboot 1 \
    --start 1

ok "Contenedor creado."

echo
echo "Esperando que el contenedor arranque..."
wait_for_ct_running || die "El contenedor no arrancó correctamente."

sleep 5
wait_for_network || warn "Continuaré, pero si no hay red en el contenedor puede fallar apt."

echo
echo "Actualizando sistema dentro del contenedor..."

pct_exec 'export DEBIAN_FRONTEND=noninteractive; apt update'
pct_exec 'export DEBIAN_FRONTEND=noninteractive; apt upgrade -y'
pct_exec 'export DEBIAN_FRONTEND=noninteractive; apt install -y python3 jq vim net-tools iproute2 logrotate procps'

echo
echo "Creando estructura del honeypot..."

pct_exec 'mkdir -p /opt/fake-rdp-honeypot/bin /opt/fake-rdp-honeypot/logs'
pct_exec 'touch /opt/fake-rdp-honeypot/logs/events.jsonl'
pct_exec 'touch /opt/fake-rdp-honeypot/logs/errors.log'

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/fake-rdp.py" <<'PY'
#!/usr/bin/env python3
import socket
import os
import json
import time
import traceback
import binascii
import signal
import threading
from datetime import datetime, timezone

HOST = "0.0.0.0"
PORT = 3389

BASE_DIR = "/opt/fake-rdp-honeypot"
LOG_DIR = os.path.join(BASE_DIR, "logs")
EVENTS_LOG = os.path.join(LOG_DIR, "events.jsonl")
ERROR_LOG = os.path.join(LOG_DIR, "errors.log")

STOP_EVENT = threading.Event()

PROTOCOLS = {
    0x00000000: "RDP_STANDARD",
    0x00000001: "SSL_TLS",
    0x00000002: "HYBRID_NLA_CREDSSP",
    0x00000004: "RDSTLS",
    0x00000008: "HYBRID_EX",
}


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def log_event(event):
    os.makedirs(LOG_DIR, exist_ok=True)
    with open(EVENTS_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")


def log_error(msg):
    os.makedirs(LOG_DIR, exist_ok=True)
    with open(ERROR_LOG, "a", encoding="utf-8") as f:
        f.write(f"[{now_iso()}] {msg}\n")


def protocol_flags_to_names(value):
    names = []
    for flag, name in PROTOCOLS.items():
        if flag == 0:
            continue
        if value & flag:
            names.append(name)
    if not names and value == 0:
        names.append("RDP_STANDARD")
    return names


def is_tpkt(data):
    return len(data) >= 4 and data[0] == 0x03 and data[1] == 0x00


def extract_cookie(data):
    try:
        text = data.decode("latin1", errors="ignore")
        marker = "Cookie: mstshash="
        if marker in text:
            value = text.split(marker, 1)[1].split("\r\n", 1)[0].strip()
            return value[:128]
    except Exception:
        pass
    return ""


def parse_rdp_negotiation_request(data):
    result = {
        "is_tpkt": is_tpkt(data),
        "x224_type": "",
        "cookie_mstshash": extract_cookie(data),
        "requested_protocols_value": None,
        "requested_protocols": [],
        "raw_hex": binascii.hexlify(data[:1024]).decode(),
    }

    try:
        if is_tpkt(data) and len(data) >= 6:
            x224_type = data[5]
            if x224_type == 0xE0:
                result["x224_type"] = "X224_CONNECTION_REQUEST"
            elif x224_type == 0xF0:
                result["x224_type"] = "X224_DATA"
            else:
                result["x224_type"] = f"0x{x224_type:02x}"

        # RDP Negotiation Request:
        # type=0x01, flags=0x00, length=0x0008, selected protocols 4 bytes little endian.
        marker = b"\x01\x00\x08\x00"
        idx = data.find(marker)
        if idx != -1 and idx + 8 <= len(data):
            requested = int.from_bytes(data[idx + 4:idx + 8], "little")
            result["requested_protocols_value"] = requested
            result["requested_protocols"] = protocol_flags_to_names(requested)

    except Exception:
        pass

    return result


def build_connection_confirm(selected_protocol=0x00000001):
    # TPKT + X.224 Connection Confirm + RDP Negotiation Response
    # selected_protocol:
    #   0 = Standard RDP Security
    #   1 = SSL/TLS
    payload = bytearray()
    payload += b"\x03\x00\x00\x13"              # TPKT, length 19
    payload += b"\x0e\xd0\x00\x00\x12\x34\x00"  # X.224 CC
    payload += b"\x02\x00\x08\x00"              # RDP Negotiation Response
    payload += selected_protocol.to_bytes(4, "little")
    return bytes(payload)


def classify_second_packet(data):
    if not data:
        return "none"

    # TLS ClientHello often begins with: 16 03 01/03/...
    if len(data) >= 3 and data[0] == 0x16 and data[1] == 0x03:
        return "TLS_CLIENT_HELLO"

    if is_tpkt(data):
        return "TPKT_RDP_PACKET"

    return "UNKNOWN_PACKET"


def handle_client(conn, addr):
    client_ip, client_port = addr[0], addr[1]
    start_time = time.time()

    event = {
        "timestamp": now_iso(),
        "client_ip": client_ip,
        "client_port": client_port,
        "server_port": PORT,
        "event_type": "connection",
        "x224_type": "",
        "cookie_mstshash": "",
        "requested_protocols_value": None,
        "requested_protocols": [],
        "selected_protocol": "",
        "second_packet_type": "",
        "duration_seconds": None,
        "raw_hex": "",
        "second_raw_hex": "",
    }

    try:
        conn.settimeout(8)

        first = conn.recv(4096)

        if not first:
            event["event_type"] = "empty_connection"
            return

        parsed = parse_rdp_negotiation_request(first)

        event["event_type"] = "rdp_negotiation_attempt"
        event["x224_type"] = parsed.get("x224_type", "")
        event["cookie_mstshash"] = parsed.get("cookie_mstshash", "")
        event["requested_protocols_value"] = parsed.get("requested_protocols_value")
        event["requested_protocols"] = parsed.get("requested_protocols", [])
        event["raw_hex"] = parsed.get("raw_hex", "")

        requested = event["requested_protocols_value"]

        # Selecciona SSL/TLS si fue solicitado. Si no, usa RDP estándar.
        if requested is not None and requested & 0x00000001:
            selected = 0x00000001
            event["selected_protocol"] = "SSL_TLS"
        else:
            selected = 0x00000000
            event["selected_protocol"] = "RDP_STANDARD"

        conn.sendall(build_connection_confirm(selected))

        try:
            second = conn.recv(4096)
            if second:
                event["second_packet_type"] = classify_second_packet(second)
                event["second_raw_hex"] = binascii.hexlify(second[:1024]).decode()
        except socket.timeout:
            event["second_packet_type"] = "timeout_after_confirm"

    except Exception as e:
        event["event_type"] = "error"
        event["error"] = str(e)
        log_error(traceback.format_exc())

    finally:
        event["duration_seconds"] = round(time.time() - start_time, 4)
        log_event(event)

        try:
            conn.close()
        except Exception:
            pass


def signal_handler(signum, frame):
    STOP_EVENT.set()


def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    os.makedirs(LOG_DIR, exist_ok=True)

    log_event({
        "timestamp": now_iso(),
        "client_ip": "127.0.0.1",
        "client_port": 0,
        "server_port": PORT,
        "event_type": "service_started",
        "x224_type": "",
        "cookie_mstshash": "",
        "requested_protocols_value": None,
        "requested_protocols": [],
        "selected_protocol": "",
        "second_packet_type": "",
        "duration_seconds": 0,
        "raw_hex": "",
        "second_raw_hex": "",
    })

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.settimeout(2)

    sock.bind((HOST, PORT))
    sock.listen(128)

    print(f"[+] Fake RDP honeypot escuchando en {HOST}:{PORT}", flush=True)

    while not STOP_EVENT.is_set():
        try:
            conn, addr = sock.accept()
            thread = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
            thread.start()
        except socket.timeout:
            continue
        except Exception:
            log_error(traceback.format_exc())

    try:
        sock.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
PY

cat > "$TMPDIR/fake-rdp-honeypot.service" <<'SERVICE'
[Unit]
Description=Fake RDP Honeypot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/fake-rdp-honeypot
ExecStart=/usr/bin/python3 /opt/fake-rdp-honeypot/bin/fake-rdp.py
Restart=always
RestartSec=3

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/opt/fake-rdp-honeypot/logs

[Install]
WantedBy=multi-user.target
SERVICE

cat > "$TMPDIR/fake-rdp-live" <<'LIVE'
#!/usr/bin/env bash

LOG="/opt/fake-rdp-honeypot/logs/events.jsonl"

mkdir -p /opt/fake-rdp-honeypot/logs
touch "$LOG"

print_event() {
    jq -r '
    [
      (.timestamp // "-"),
      (.client_ip // "-"),
      ((.client_port // "-")|tostring),
      (.event_type // "-"),
      (.cookie_mstshash // "-"),
      ((.requested_protocols // []) | join(",")),
      (.selected_protocol // "-"),
      (.second_packet_type // "-")
    ] | @tsv
    ' | awk -F'\t' '
    function month_name(mm) {
        if (mm == "01") return "Enero"
        if (mm == "02") return "Febrero"
        if (mm == "03") return "Marzo"
        if (mm == "04") return "Abril"
        if (mm == "05") return "Mayo"
        if (mm == "06") return "Junio"
        if (mm == "07") return "Julio"
        if (mm == "08") return "Agosto"
        if (mm == "09") return "Septiembre"
        if (mm == "10") return "Octubre"
        if (mm == "11") return "Noviembre"
        if (mm == "12") return "Diciembre"
        return mm
    }

    function fmt_date(ts, month, day, hour) {
        if (ts == "-" || ts == "") return "-"
        month = substr(ts, 6, 2)
        day   = substr(ts, 9, 2)
        hour  = substr(ts, 12, 8)
        return month_name(month) " " day " " hour
    }

    {
      printf "%-22s %-16s %-8s %-24s %-18s %-30s %-14s %-22s\n",
             fmt_date($1), $2, $3, $4, $5, $6, $7, $8
    }'
}

clear
echo "============================================================================================================================"
echo "                                             FAKE RDP HONEYPOT - LIVE"
echo "============================================================================================================================"
echo

echo "[+] Servicio:"
systemctl is-active fake-rdp-honeypot 2>/dev/null || echo "no-activo"

echo
echo "[+] Puerto 3389:"
ss -tulpn | grep ':3389' || echo "No se detecta puerto 3389 escuchando."

echo
echo "[+] Log:"
ls -lh "$LOG"

echo
printf "%-22s %-16s %-8s %-24s %-18s %-30s %-14s %-22s\n" \
"FECHA" "IP" "PUERTO" "EVENTO" "MSTSHASH" "PROTOCOLOS" "SELECCIONADO" "SEGUNDO_PAQUETE"
printf "%-22s %-16s %-8s %-24s %-18s %-30s %-14s %-22s\n" \
"-----" "--" "------" "------" "--------" "----------" "------------" "---------------"

if [ -s "$LOG" ]; then
    tail -n 20 "$LOG" | while IFS= read -r line; do
        echo "$line" | print_event
    done
fi

echo
echo "[+] Esperando nuevos intentos. Presiona Ctrl+C para salir."
echo

tail -n 0 -F "$LOG" | while IFS= read -r line; do
    echo "$line" | print_event
done
LIVE

cat > "$TMPDIR/fake-rdp-summary" <<'SUMMARY'
#!/usr/bin/env bash

LOG="/opt/fake-rdp-honeypot/logs/events.jsonl"

if [ ! -f "$LOG" ]; then
    echo "No existe el log todavía: $LOG"
    exit 1
fi

echo
echo "=========================="
echo " RESUMEN FAKE RDP HONEYPOT"
echo "=========================="
echo

echo "[+] Total de eventos:"
wc -l "$LOG" | awk '{print $1}'

echo
echo "[+] Top IPs:"
jq -r '.client_ip // empty' "$LOG" | sort | uniq -c | sort -nr | head -20

echo
echo "[+] Eventos por tipo:"
jq -r '.event_type // empty' "$LOG" | sort | uniq -c | sort -nr

echo
echo "[+] Cookies mstshash vistas:"
jq -r '.cookie_mstshash // empty' "$LOG" | grep -v '^$' | sort | uniq -c | sort -nr | head -20

echo
echo "[+] Protocolos solicitados:"
jq -r '(.requested_protocols // [])[]?' "$LOG" | sort | uniq -c | sort -nr

echo
echo "[+] Segundo paquete:"
jq -r '.second_packet_type // empty' "$LOG" | grep -v '^$' | sort | uniq -c | sort -nr

echo
echo "[+] Últimos 10 eventos sin raw_hex:"
tail -n 10 "$LOG" | jq 'del(.raw_hex, .second_raw_hex)'
SUMMARY

cat > "$TMPDIR/fake-rdp-info" <<'INFO'
#!/usr/bin/env bash

echo
echo "============================="
echo " FAKE RDP HONEYPOT - INFO"
echo "============================="
echo

echo "[+] IPs del contenedor:"
hostname -I || true

echo
echo "[+] Interfaces:"
ip -br addr || true

echo
echo "[+] Ruta por defecto:"
ip route show default || true

echo
echo "[+] Servicio:"
systemctl status fake-rdp-honeypot --no-pager || true

echo
echo "[+] Puerto 3389:"
ss -tulpn | grep ':3389' || echo "No se detecta puerto 3389 escuchando."

echo
echo "[+] Archivos instalados:"
ls -lh /opt/fake-rdp-honeypot/bin/ || true
ls -lh /usr/local/bin/fake-rdp-* 2>/dev/null || true
ls -lh /usr/bin/fake-rdp-* 2>/dev/null || true

echo
echo "[+] Logs:"
ls -lh /opt/fake-rdp-honeypot/logs/ || true

echo
echo "[+] Últimos eventos:"
tail -n 5 /opt/fake-rdp-honeypot/logs/events.jsonl 2>/dev/null | jq 'del(.raw_hex, .second_raw_hex)' || true
INFO

cat > "$TMPDIR/logrotate-fake-rdp-honeypot" <<'LOGROTATE'
/opt/fake-rdp-honeypot/logs/*.log
/opt/fake-rdp-honeypot/logs/*.jsonl
{
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE

echo
echo "Copiando archivos al contenedor..."

pct push "$CTID" "$TMPDIR/fake-rdp.py" /opt/fake-rdp-honeypot/bin/fake-rdp.py
pct push "$CTID" "$TMPDIR/fake-rdp-honeypot.service" /etc/systemd/system/fake-rdp-honeypot.service
pct push "$CTID" "$TMPDIR/fake-rdp-live" /usr/local/bin/fake-rdp-live
pct push "$CTID" "$TMPDIR/fake-rdp-summary" /usr/local/bin/fake-rdp-summary
pct push "$CTID" "$TMPDIR/fake-rdp-info" /usr/local/bin/fake-rdp-info
pct push "$CTID" "$TMPDIR/logrotate-fake-rdp-honeypot" /etc/logrotate.d/fake-rdp-honeypot

pct_exec 'chmod +x /opt/fake-rdp-honeypot/bin/fake-rdp.py'
pct_exec 'chmod +x /usr/local/bin/fake-rdp-live /usr/local/bin/fake-rdp-summary /usr/local/bin/fake-rdp-info'

pct_exec 'cp -f /usr/local/bin/fake-rdp-live /usr/bin/fake-rdp-live'
pct_exec 'cp -f /usr/local/bin/fake-rdp-summary /usr/bin/fake-rdp-summary'
pct_exec 'cp -f /usr/local/bin/fake-rdp-info /usr/bin/fake-rdp-info'
pct_exec 'chmod +x /usr/bin/fake-rdp-live /usr/bin/fake-rdp-summary /usr/bin/fake-rdp-info'

echo
echo "Activando servicio..."

pct_exec 'systemctl daemon-reload'
pct_exec 'systemctl enable --now fake-rdp-honeypot'

sleep 3

echo
echo "Comprobando servicio..."

if pct exec "$CTID" -- bash -lc 'systemctl is-active --quiet fake-rdp-honeypot'; then
    ok "Servicio fake-rdp-honeypot activo."
else
    warn "El servicio no aparece activo. Mostrando estado:"
    pct exec "$CTID" -- bash -lc 'systemctl status fake-rdp-honeypot --no-pager || true'
    die "El servicio no inició correctamente."
fi

if pct exec "$CTID" -- bash -lc 'ss -tulpn | grep -q ":3389"'; then
    ok "Puerto TCP 3389 escuchando dentro del contenedor."
else
    warn "No se detectó el puerto 3389 escuchando."
    pct_exec 'ss -tulpn || true'
    die "El honeypot no quedó escuchando en 3389."
fi

echo
echo "Verificando comandos instalados..."

pct_exec 'command -v fake-rdp-live'
pct_exec 'command -v fake-rdp-summary'
pct_exec 'command -v fake-rdp-info'

CT_ADDR="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"

echo
ok "Instalación terminada."
echo
echo "======================================================="
echo " Datos importantes"
echo "======================================================="
echo "CTID:          $CTID"
echo "Hostname:      $HOSTNAME"
echo "Bridge:        $BRIDGE"
echo "VLAN:          $VLAN_TAG"
echo "MAC:           $MACADDR"
echo "IP detectada:  ${CT_ADDR:-No detectada todavía}"
echo "Puerto:        TCP 3389"
echo
echo "Registra esta MAC en tu DHCP:"
echo "  $MACADDR"
echo
echo "Entrar al contenedor:"
echo "  pct enter $CTID"
echo
echo "Ver estado completo:"
echo "  pct exec $CTID -- /usr/local/bin/fake-rdp-info"
echo
echo "Ver eventos en vivo:"
echo "  pct exec $CTID -- /usr/local/bin/fake-rdp-live"
echo
echo "Ver resumen:"
echo "  pct exec $CTID -- /usr/local/bin/fake-rdp-summary"
echo
echo "Logs dentro del contenedor:"
echo "  /opt/fake-rdp-honeypot/logs/events.jsonl"
echo "  /opt/fake-rdp-honeypot/logs/errors.log"
echo
echo "Probar desde otra máquina:"
echo "  xfreerdp /v:${CT_ADDR:-IP_DEL_CONTENEDOR}:3389 /u:administrator /p:test /cert:ignore"
echo
echo "O con nmap:"
echo "  nmap -sV -p3389 ${CT_ADDR:-IP_DEL_CONTENEDOR}"
echo
warn "Si quieres recibir ataques desde Internet, crea NAT hacia la IP DHCP/reservada del contenedor puerto TCP 3389."
warn "No apuntes ese NAT hacia ningún Windows real."
echo
