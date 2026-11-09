#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Fake SSH Honeypot en LXC para Proxmox
# Ejecutar desde el HOST Proxmox.
# Crea un contenedor Ubuntu 24.04 en VLAN 1001.
# ============================================================

# ---------------- CONFIGURACIÓN DEL CONTENEDOR ----------------

CTID="${CTID:-123}"
GUEST_NAME="${GUEST_NAME:-fake-ssh-honeypot}"
HOSTNAME="$GUEST_NAME"
# Sin contraseña por defecto (antes era "123456"): si no la pasas, se genera una
# aleatoria y se muestra al final.
PASSWORD_ROOT="${PASSWORD_ROOT:-$(head -c 18 /dev/urandom | base64 | tr -d '+/=')}"

# Red del contenedor
BRIDGE="${BRIDGE:-vmbr1}"
VLAN_TAG="${VLAN_TAG:-1001}"
# Obligatorias (no se guardan IPs de tu red en el repositorio):
#   CT_IP=192.168.X.Y/24 GATEWAY=192.168.X.1 ./create-contener.sh
CT_IP="${CT_IP:?Define CT_IP, p. ej. CT_IP=192.168.1.47/24}"
GATEWAY="${GATEWAY:?Define GATEWAY, p. ej. GATEWAY=192.168.1.1}"

# Recursos del contenedor
CORES="${CORES:-1}"
MEMORY="${MEMORY:-512}"
SWAP="${SWAP:-256}"
DISK_SIZE="${DISK_SIZE:-4}"

# Storage y template
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-zfs}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"

# Para destruir automáticamente un contenedor existente con el mismo CTID:
# DESTROY_EXISTING=1 ./crear-honeypot-ssh-lxc.sh
DESTROY_EXISTING="${DESTROY_EXISTING:-0}"

# Honeypot
HONEYPOT_PORT="${HONEYPOT_PORT:-22}"
HONEYPOT_USER="${HONEYPOT_USER:-honeypot}"
HONEYPOT_DIR="/opt/fake-ssh-honeypot"
HONEYPOT_LOG_DIR="/var/log/fake-ssh-honeypot"

# ---------------- FUNCIONES GENERALES ----------------

msg() {
    echo -e "\n\033[1;32m[+] $*\033[0m"
}

warn() {
    echo -e "\n\033[1;33m[!] $*\033[0m"
}

err() {
    echo -e "\n\033[1;31m[ERROR] $*\033[0m" >&2
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "Este script debe ejecutarse como root en el host Proxmox."
        exit 1
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        err "No existe el comando requerido: $1"
        exit 1
    }
}

pct_exec() {
    pct exec "$CTID" -- bash -lc "$*"
}

download_template_if_needed() {
    local template_path="/var/lib/vz/template/cache/${TEMPLATE}"

    if [[ -f "$template_path" ]]; then
        msg "Template encontrado: $template_path"
        return 0
    fi

    msg "Template no encontrado. Intentando descargar: $TEMPLATE"
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
}

destroy_existing_ct_if_requested() {
    if pct status "$CTID" >/dev/null 2>&1; then
        if [[ "$DESTROY_EXISTING" != "1" ]]; then
            err "Ya existe un contenedor con CTID $CTID."
            echo
            echo "Si quieres destruirlo y recrearlo automáticamente, ejecuta:"
            echo
            echo "  DESTROY_EXISTING=1 ./crear-honeypot-ssh-lxc.sh"
            echo
            echo "ADVERTENCIA: eso borrará completamente el contenedor $CTID."
            exit 1
        fi

        warn "Destruyendo contenedor existente CTID=$CTID..."
        pct stop "$CTID" >/dev/null 2>&1 || true
        pct destroy "$CTID" --purge 1
    fi
}

create_ct() {
    msg "Creando contenedor LXC CTID=$CTID en VLAN $VLAN_TAG..."

    local net0
    net0="name=eth0,bridge=${BRIDGE},tag=${VLAN_TAG},ip=${CT_IP},gw=${GATEWAY},firewall=1"

    pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "$HOSTNAME" \
        --password "$PASSWORD_ROOT" \
        --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE}" \
        --cores "$CORES" \
        --memory "$MEMORY" \
        --swap "$SWAP" \
        --net0 "$net0" \
        --ostype ubuntu \
        --unprivileged 1 \
        --features nesting=0,keyctl=0 \
        --onboot 1 \
        --start 1

    msg "Contenedor creado e iniciado."
}

wait_for_ct_boot() {
    msg "Esperando que el contenedor arranque..."

    for i in {1..60}; do
        if pct_exec "systemctl is-system-running >/dev/null 2>&1 || true"; then
            if pct_exec "ip addr show eth0 >/dev/null 2>&1"; then
                msg "El contenedor respondió correctamente."
                return 0
            fi
        fi
        sleep 2
    done

    err "El contenedor no respondió a tiempo."
    exit 1
}

wait_for_ct_network() {
    msg "Verificando conectividad del contenedor..."

    pct_exec "ip addr show eth0 || true"
    pct_exec "ip route || true"

    for i in {1..40}; do
        if pct_exec "ping -c1 -W1 ${GATEWAY} >/dev/null 2>&1"; then
            msg "El contenedor llega al gateway ${GATEWAY}."
            break
        fi

        if [[ "$i" -eq 40 ]]; then
            err "El contenedor no puede llegar al gateway ${GATEWAY}."
            echo
            echo "Revisa bridge=${BRIDGE}, VLAN tag=${VLAN_TAG}, gateway=${GATEWAY}, firewall del CT o pfSense."
            exit 1
        fi

        sleep 2
    done

    msg "Verificando salida a internet para instalar paquetes..."

    for i in {1..40}; do
        if pct_exec "ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W1 8.8.8.8 >/dev/null 2>&1"; then
            msg "El contenedor tiene salida a internet."
            return 0
        fi
        sleep 2
    done

    err "El contenedor llega al gateway, pero no tiene salida a internet."
    echo
    echo "Sin internet no se podrán instalar Python, venv ni Paramiko."
    exit 1
}

install_base_packages() {
    msg "Actualizando Ubuntu e instalando dependencias..."

    pct_exec "
export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    python3-pip \
    ca-certificates \
    iproute2 \
    procps \
    net-tools \
    psmisc \
    less \
    nano \
    curl \
    jq

apt-get clean
rm -rf /var/lib/apt/lists/*
"
}

disable_real_ssh() {
    msg "Eliminando/desactivando SSH real del contenedor..."

    pct_exec "
systemctl disable --now ssh 2>/dev/null || true
systemctl disable --now sshd 2>/dev/null || true
systemctl mask ssh 2>/dev/null || true
systemctl mask sshd 2>/dev/null || true

apt-get purge -y openssh-server 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

rm -rf /etc/ssh/sshd_config.d 2>/dev/null || true
"
}

install_honeypot_files() {
    msg "Instalando entorno virtual y Paramiko..."

    pct_exec "
useradd --system --home ${HONEYPOT_DIR} --shell /usr/sbin/nologin ${HONEYPOT_USER} 2>/dev/null || true

mkdir -p ${HONEYPOT_DIR}
mkdir -p ${HONEYPOT_LOG_DIR}

chown -R ${HONEYPOT_USER}:${HONEYPOT_USER} ${HONEYPOT_DIR}
chown -R ${HONEYPOT_USER}:${HONEYPOT_USER} ${HONEYPOT_LOG_DIR}

chmod 750 ${HONEYPOT_DIR}
chmod 750 ${HONEYPOT_LOG_DIR}

python3 -m venv ${HONEYPOT_DIR}/venv
${HONEYPOT_DIR}/venv/bin/pip install --upgrade pip wheel
${HONEYPOT_DIR}/venv/bin/pip install paramiko
"

    msg "Creando servidor SSH falso en Python..."

    pct_exec "cat > ${HONEYPOT_DIR}/fake_ssh_server.py <<'PYEOF'
#!/usr/bin/env python3
import base64
import datetime
import json
import os
import random
import shlex
import socket
import threading
import time
import traceback
from pathlib import Path

import paramiko


HOST = '0.0.0.0'
PORT = int(os.environ.get('HONEYPOT_PORT', '22'))

BASE_DIR = Path('/opt/fake-ssh-honeypot')
LOG_DIR = Path('/var/log/fake-ssh-honeypot')
LOG_FILE = LOG_DIR / 'events.jsonl'
HOST_KEY_FILE = BASE_DIR / 'host_rsa.key'

BANNER = 'SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6'

FAKE_USERS = {
    'root': '/root',
    'admin': '/home/admin',
    'user': '/home/user',
    'ubuntu': '/home/ubuntu',
    'debian': '/home/debian',
    'test': '/home/test',
    'oracle': '/home/oracle',
    'postgres': '/var/lib/postgresql',
    'www-data': '/var/www',
}

FAKE_FILES = {
    '/root': ['.bashrc', '.profile', '.ssh', 'backup.sh', 'notes.txt', 'server.key'],
    '/home/admin': ['.bashrc', '.profile', '.ssh', 'deploy.sh', 'project', 'credentials.txt'],
    '/home/user': ['.bashrc', '.profile', 'Downloads', 'Documents'],
    '/home/ubuntu': ['.bashrc', '.profile', '.ssh', 'app'],
    '/home/debian': ['.bashrc', '.profile', 'server'],
    '/home/test': ['.bashrc', '.profile', 'test.txt'],
    '/var/www': ['html', 'backup', '.env'],
    '/etc': ['passwd', 'shadow', 'hosts', 'hostname', 'resolv.conf', 'ssh', 'nginx', 'crontab'],
    '/etc/ssh': ['sshd_config', 'ssh_host_rsa_key', 'ssh_host_ed25519_key'],
    '/etc/nginx': ['nginx.conf', 'sites-available', 'sites-enabled'],
    '/var/log': ['auth.log', 'syslog', 'kern.log', 'dpkg.log', 'nginx'],
    '/tmp': [],
}

DELAY_WORDS = [
    'wget', 'curl', 'apt install', 'apt-get install', 'dnf install', 'yum install',
    'pacman -S', 'rm -rf', 'mkfs', 'dd ', 'nc ', 'netcat', 'scp ', 'sftp ',
    'chmod +x', 'bash ', 'sh ', 'python ', 'python3 ', 'perl ', 'php ',
    'busybox', 'tftp', 'ftp ', 'nmap', 'masscan'
]


def utc_now():
    return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + 'Z'


def log_event(event_type, **data):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    event = {
        'timestamp': utc_now(),
        'event': event_type,
        **data,
    }
    line = json.dumps(event, ensure_ascii=False, sort_keys=True)
    with LOG_FILE.open('a', encoding='utf-8') as f:
        f.write(line + '\\n')


def generate_host_key():
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    if not HOST_KEY_FILE.exists():
        key = paramiko.RSAKey.generate(2048)
        key.write_private_key_file(str(HOST_KEY_FILE))
        os.chmod(HOST_KEY_FILE, 0o600)


def load_host_key():
    generate_host_key()
    return paramiko.RSAKey(filename=str(HOST_KEY_FILE))


class FakeSSHServer(paramiko.ServerInterface):
    def __init__(self, client_ip):
        self.client_ip = client_ip
        self.username = None
        self.password = None
        self.event = threading.Event()
        self.pty_requested = False
        self.shell_requested = False

    def get_banner(self):
        return ('Ubuntu 22.04.3 LTS\\n', 'en-US')

    def check_auth_password(self, username, password):
        self.username = username
        self.password = password

        log_event(
            'auth_password',
            src_ip=self.client_ip,
            username=username,
            password=password,
            accepted=True,
        )

        return paramiko.AUTH_SUCCESSFUL

    def check_auth_publickey(self, username, key):
        self.username = username

        try:
            fp = base64.b64encode(key.get_fingerprint()).decode()
        except Exception:
            fp = 'unknown'

        log_event(
            'auth_publickey',
            src_ip=self.client_ip,
            username=username,
            key_type=key.get_name(),
            fingerprint=fp,
            accepted=False,
        )

        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return 'password,publickey'

    def check_channel_request(self, kind, chanid):
        log_event(
            'channel_request',
            src_ip=self.client_ip,
            username=self.username,
            kind=kind,
            chanid=chanid,
        )

        if kind == 'session':
            return paramiko.OPEN_SUCCEEDED

        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(
        self, channel, term, width, height, pixelwidth, pixelheight, modes
    ):
        self.pty_requested = True

        log_event(
            'pty_request',
            src_ip=self.client_ip,
            username=self.username,
            term=term.decode(errors='ignore') if isinstance(term, bytes) else str(term),
            width=width,
            height=height,
        )

        return True

    def check_channel_shell_request(self, channel):
        self.shell_requested = True
        self.event.set()

        log_event(
            'shell_request',
            src_ip=self.client_ip,
            username=self.username,
        )

        return True

    def check_channel_exec_request(self, channel, command):
        cmd = command.decode(errors='ignore') if isinstance(command, bytes) else str(command)

        log_event(
            'exec_request',
            src_ip=self.client_ip,
            username=self.username,
            command=cmd,
        )

        output, _cwd, exit_code = handle_command(
            cmd=cmd,
            username=self.username or 'root',
            cwd=fake_home(self.username or 'root'),
            src_ip=self.client_ip,
        )

        try:
            channel.send(output.encode(errors='ignore'))
            channel.send_exit_status(exit_code)
        except Exception:
            pass

        return True


def fake_home(username):
    return FAKE_USERS.get(username, f'/home/{username}')


def prompt(username, hostname, cwd):
    home = fake_home(username)

    if cwd == home:
        display_cwd = '~'
    elif cwd.startswith(home + '/'):
        display_cwd = '~' + cwd[len(home):]
    else:
        display_cwd = cwd

    if username == 'root':
        return f'root@{hostname}:{display_cwd}# '
    return f'{username}@{hostname}:{display_cwd}$ '


def maybe_delay(cmd):
    lowered = cmd.lower()

    if any(word in lowered for word in DELAY_WORDS):
        time.sleep(random.uniform(5, 10))
    else:
        time.sleep(random.uniform(0.05, 0.35))


def normalize_path(cwd, target, username='root'):
    if not target or target == '.':
        return cwd

    if target == '~':
        return fake_home(username)

    if target.startswith('~/'):
        return os.path.normpath(os.path.join(fake_home(username), target[2:]))

    if target.startswith('/'):
        return os.path.normpath(target)

    return os.path.normpath(os.path.join(cwd, target))


def fake_ls(path):
    entries = FAKE_FILES.get(path)

    if entries is None:
        if path.endswith('/.ssh'):
            return 'authorized_keys  id_rsa  id_rsa.pub\\n'
        if path.endswith('/sites-available') or path.endswith('/sites-enabled'):
            return 'default  app.conf\\n'
        if path.endswith('/html'):
            return 'index.html  login.php  upload.php\\n'
        if path.endswith('/backup'):
            return 'site-backup.tar.gz  db.sql.gz\\n'
        if path.endswith('/nginx'):
            return 'access.log  error.log\\n'
        return f\"ls: cannot access '{path}': No such file or directory\\n\"

    if not entries:
        return ''

    return '  '.join(entries) + '\\n'


def fake_cat(path, username):
    basename = os.path.basename(path)

    if path == '/etc/passwd':
        return (
            'root:x:0:0:root:/root:/bin/bash\\n'
            'daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\\n'
            'bin:x:2:2:bin:/bin:/usr/sbin/nologin\\n'
            'www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin\\n'
            'ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash\\n'
            'admin:x:1001:1001:Admin:/home/admin:/bin/bash\\n'
        )

    if path == '/etc/shadow':
        return 'cat: /etc/shadow: Permission denied\\n'

    if path == '/etc/hosts':
        return '127.0.0.1 localhost\\n127.0.1.1 server01\\n'

    if path == '/etc/hostname':
        return 'server01\\n'

    if path == '/etc/resolv.conf':
        return 'nameserver 127.0.0.53\\noptions edns0 trust-ad\\nsearch localdomain\\n'

    if path == '/etc/crontab':
        return (
            'SHELL=/bin/sh\\n'
            'PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\\n'
            '17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly\\n'
            '25 6    * * *   root    test -x /usr/sbin/anacron || run-parts --report /etc/cron.daily\\n'
        )

    if path.endswith('/.ssh/id_rsa'):
        return '-----BEGIN OPENSSH PRIVATE KEY-----\\nPermission denied\\n'

    if basename == 'notes.txt':
        return 'TODO: rotate backups and check web panel credentials.\\n'

    if basename == 'credentials.txt':
        return 'old admin panel password removed. ask miguel for new one.\\n'

    if basename == 'backup.sh':
        return '#!/bin/bash\\ntar czf /tmp/backup.tgz /var/www /etc/nginx\\n'

    if basename == 'deploy.sh':
        return '#!/bin/bash\\ngit pull && systemctl reload nginx\\n'

    if basename == '.env':
        return (
            'APP_ENV=production\\n'
            'DB_HOST=127.0.0.1\\n'
            'DB_USER=app\\n'
            'DB_PASSWORD=changeme\\n'
        )

    if basename == 'nginx.conf':
        return (
            'user www-data;\\n'
            'worker_processes auto;\\n'
            'events { worker_connections 768; }\\n'
            'http { include /etc/nginx/sites-enabled/*; }\\n'
        )

    if basename in ['auth.log', 'syslog', 'kern.log', 'dpkg.log', 'access.log', 'error.log']:
        return (
            'May 16 10:14:22 server01 systemd[1]: Started OpenSSH server daemon.\\n'
            'May 16 10:18:03 server01 sshd[812]: Accepted password for admin from 10.0.0.45 port 54422 ssh2\\n'
            'May 16 10:19:11 server01 sudo: admin : TTY=pts/0 ; PWD=/home/admin ; USER=root ; COMMAND=/usr/bin/systemctl restart nginx\\n'
        )

    return f\"cat: {path}: No such file or directory\\n\"


def handle_command(cmd, username, cwd, src_ip):
    maybe_delay(cmd)

    raw_cmd = cmd.strip()
    if raw_cmd == '':
        return '', cwd, 0

    log_event(
        'command',
        src_ip=src_ip,
        username=username,
        cwd=cwd,
        command=raw_cmd,
    )

    try:
        parts = shlex.split(raw_cmd)
    except ValueError:
        return 'bash: syntax error: unexpected end of file\\n', cwd, 2

    if not parts:
        return '', cwd, 0

    c = parts[0]

    if c in ['exit', 'logout']:
        return '__EXIT__', cwd, 0

    if c == 'pwd':
        return cwd + '\\n', cwd, 0

    if c == 'whoami':
        return username + '\\n', cwd, 0

    if c == 'id':
        if username == 'root':
            return 'uid=0(root) gid=0(root) groups=0(root)\\n', cwd, 0
        return f'uid=1000({username}) gid=1000({username}) groups=1000({username}),27(sudo)\\n', cwd, 0

    if c == 'hostname':
        return 'server01\\n', cwd, 0

    if c == 'uname':
        if '-a' in parts:
            return 'Linux server01 5.15.0-91-generic #101-Ubuntu SMP x86_64 GNU/Linux\\n', cwd, 0
        return 'Linux\\n', cwd, 0

    if c in ['ls', 'll', 'la']:
        target = cwd
        args = [p for p in parts[1:] if not p.startswith('-')]
        if args:
            target = normalize_path(cwd, args[-1], username)
        return fake_ls(target), cwd, 0

    if c == 'dir':
        return fake_ls(cwd), cwd, 0

    if c == 'cd':
        target = parts[1] if len(parts) > 1 else fake_home(username)
        new_path = normalize_path(cwd, target, username)

        if new_path in FAKE_FILES or new_path.endswith('/.ssh') or new_path.endswith('/sites-available') or new_path.endswith('/sites-enabled') or new_path.endswith('/html') or new_path.endswith('/backup') or new_path.endswith('/nginx'):
            return '', new_path, 0

        return f\"bash: cd: {target}: No such file or directory\\n\", cwd, 1

    if c in ['cat', 'head', 'tail']:
        if len(parts) < 2:
            return f'{c}: missing operand\\n', cwd, 1
        target = normalize_path(cwd, parts[-1], username)
        return fake_cat(target, username), cwd, 0

    if c == 'ps':
        return (
            '    PID TTY          TIME CMD\\n'
            '      1 ?        00:00:02 systemd\\n'
            '    422 ?        00:00:00 sshd\\n'
            '    817 ?        00:00:01 nginx\\n'
            '   1201 pts/0    00:00:00 bash\\n'
            '   1212 pts/0    00:00:00 ps\\n'
        ), cwd, 0

    if c == 'top':
        return (
            'top - 10:22:41 up 14 days,  3:18,  1 user,  load average: 0.08, 0.03, 0.01\\n'
            'Tasks: 102 total,   1 running, 101 sleeping,   0 stopped,   0 zombie\\n'
            '%Cpu(s):  1.2 us,  0.4 sy,  0.0 ni, 98.1 id\\n'
            'MiB Mem :   3942.1 total,   1421.7 free,    712.4 used,   1808.0 buff/cache\\n'
        ), cwd, 0

    if c == 'free':
        return (
            '               total        used        free      shared  buff/cache   available\\n'
            'Mem:         4036712      729512     1455820       24884     1851380     3036820\\n'
            'Swap:        2097148           0     2097148\\n'
        ), cwd, 0

    if c in ['ifconfig', 'ip']:
        return (
            'eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500\\n'
            '        inet 172.16.0.23  netmask 255.255.255.0  broadcast 172.16.0.255\\n'
            '        ether 52:54:00:12:34:56  txqueuelen 1000\\n'
            '\\n'
            'lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536\\n'
            '        inet 127.0.0.1  netmask 255.0.0.0\\n'
        ), cwd, 0

    if c in ['netstat', 'ss']:
        return (
            'Proto Recv-Q Send-Q Local Address           Foreign Address         State\\n'
            'tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN\\n'
            'tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN\\n'
            'tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN\\n'
        ), cwd, 0

    if c == 'df':
        return (
            'Filesystem      Size  Used Avail Use% Mounted on\\n'
            '/dev/sda1        40G   13G   25G  35% /\\n'
            'tmpfs           1.9G     0  1.9G   0% /dev/shm\\n'
        ), cwd, 0

    if c == 'du':
        return '4.0K\\t.\\n', cwd, 0

    if c == 'mount':
        return '/dev/sda1 on / type ext4 (rw,relatime,errors=remount-ro)\\n', cwd, 0

    if c == 'env':
        return (
            f'USER={username}\\n'
            f'HOME={fake_home(username)}\\n'
            'SHELL=/bin/bash\\n'
            'TERM=xterm-256color\\n'
            'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\\n'
        ), cwd, 0

    if c == 'echo':
        return ' '.join(parts[1:]) + '\\n', cwd, 0

    if c == 'date':
        return datetime.datetime.now().strftime('%a %b %d %H:%M:%S UTC %Y') + '\\n', cwd, 0

    if c == 'uptime':
        return ' 10:25:01 up 14 days,  3:21,  1 user,  load average: 0.03, 0.04, 0.01\\n', cwd, 0

    if c == 'history':
        return (
            '  1  ls -la\\n'
            '  2  cd /var/www\\n'
            '  3  cat .env\\n'
            '  4  sudo systemctl restart nginx\\n'
        ), cwd, 0

    if c in ['wget', 'curl']:
        return (
            'Resolving host...\\n'
            'Connecting... failed: Connection timed out.\\n'
        ), cwd, 4

    if c in ['apt', 'apt-get']:
        if len(parts) > 1 and parts[1] == 'update':
            return (
                'Hit:1 http://archive.ubuntu.com/ubuntu jammy InRelease\\n'
                'Get:2 http://security.ubuntu.com/ubuntu jammy-security InRelease [110 kB]\\n'
                'Reading package lists... Done\\n'
            ), cwd, 0

        if len(parts) > 1 and parts[1] == 'install':
            pkg = ' '.join(parts[2:]) if len(parts) > 2 else ''
            return (
                'Reading package lists... Done\\n'
                'Building dependency tree... Done\\n'
                f'E: Unable to locate package {pkg}\\n'
            ), cwd, 100

        return 'apt 2.4.11 (amd64)\\n', cwd, 0

    if c == 'sudo':
        return f'[sudo] password for {username}: \\nSorry, try again.\\n', cwd, 1

    if c in ['service', 'systemctl']:
        return 'Failed to connect to bus: No such file or directory\\n', cwd, 1

    if c == 'which':
        if len(parts) > 1:
            return f'/usr/bin/{parts[1]}\\n', cwd, 0
        return '', cwd, 1

    if c == 'whereis':
        if len(parts) > 1:
            return f'{parts[1]}: /usr/bin/{parts[1]} /usr/share/man/man1/{parts[1]}.1.gz\\n', cwd, 0
        return '', cwd, 1

    if c in ['clear', 'reset']:
        return '\\033c', cwd, 0

    if c in ['vi', 'vim', 'nano']:
        return f'{c}: command not found\\n', cwd, 127

    if c in ['python', 'python3', 'perl', 'php', 'ruby']:
        return '', cwd, 0

    if c in ['rm', 'mkdir', 'touch', 'chmod']:
        return '', cwd, 0

    if c == 'chown':
        return 'chown: changing ownership: Operation not permitted\\n', cwd, 1

    if c == 'passwd':
        return (
            'Changing password for root.\\n'
            'Current password: \\n'
            'passwd: Authentication token manipulation error\\n'
        ), cwd, 1

    if c in ['reboot', 'shutdown', 'halt', 'poweroff']:
        return 'Failed to connect to bus: No such file or directory\\n', cwd, 1

    return f'{c}: command not found\\n', cwd, 127


def interactive_shell(channel, server):
    username = server.username or 'root'
    hostname = 'server01'
    cwd = fake_home(username)

    channel.send(b'Welcome to Ubuntu 22.04.3 LTS (GNU/Linux 5.15.0-91-generic x86_64)\\r\\n')
    channel.send(b'\\r\\n')
    channel.send(prompt(username, hostname, cwd).encode())

    buffer = ''

    while True:
        try:
            data = channel.recv(1024)
            if not data:
                break

            text = data.decode(errors='ignore')

            for ch in text:
                if ch in ['\\r', '\\n']:
                    channel.send(b'\\r\\n')
                    cmd = buffer.strip()
                    buffer = ''

                    result, cwd, exit_code = handle_command(cmd, username, cwd, server.client_ip)

                    if result == '__EXIT__':
                        channel.send(b'logout\\r\\n')
                        return

                    result = result.replace('\\n', '\\r\\n')
                    channel.send(result.encode(errors='ignore'))
                    channel.send(prompt(username, hostname, cwd).encode(errors='ignore'))

                elif ch in ['\\x7f', '\\b']:
                    if buffer:
                        buffer = buffer[:-1]
                        channel.send(b'\\b \\b')

                elif ch == '\\x03':
                    buffer = ''
                    channel.send(b'^C\\r\\n')
                    channel.send(prompt(username, hostname, cwd).encode(errors='ignore'))

                elif ch == '\\x04':
                    return

                else:
                    buffer += ch
                    channel.send(ch.encode(errors='ignore'))

        except Exception:
            break


def handle_client(client_sock, addr, host_key):
    client_ip, client_port = addr[0], addr[1]

    log_event(
        'connection',
        src_ip=client_ip,
        src_port=client_port,
    )

    transport = None

    try:
        transport = paramiko.Transport(client_sock)
        transport.local_version = BANNER
        transport.add_server_key(host_key)

        server = FakeSSHServer(client_ip)

        transport.start_server(server=server)

        channel = transport.accept(30)
        if channel is None:
            log_event('no_channel', src_ip=client_ip)
            return

        server.event.wait(20)

        if server.shell_requested:
            interactive_shell(channel, server)
        else:
            time.sleep(1)

    except Exception as e:
        log_event(
            'error',
            src_ip=client_ip,
            error=str(e),
            traceback=traceback.format_exc(limit=5),
        )

    finally:
        try:
            if transport:
                transport.close()
        except Exception:
            pass

        try:
            client_sock.close()
        except Exception:
            pass

        log_event(
            'disconnect',
            src_ip=client_ip,
            src_port=client_port,
        )


def main():
    host_key = load_host_key()

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((HOST, PORT))
    sock.listen(100)

    log_event('server_started', host=HOST, port=PORT)

    while True:
        client, addr = sock.accept()
        t = threading.Thread(target=handle_client, args=(client, addr, host_key), daemon=True)
        t.start()


if __name__ == '__main__':
    main()
PYEOF

chmod +x ${HONEYPOT_DIR}/fake_ssh_server.py
chown -R ${HONEYPOT_USER}:${HONEYPOT_USER} ${HONEYPOT_DIR}
chown -R ${HONEYPOT_USER}:${HONEYPOT_USER} ${HONEYPOT_LOG_DIR}
"
}

create_systemd_service() {
    msg "Creando servicio systemd del honeypot..."

    pct_exec "cat > /etc/systemd/system/fake-ssh-honeypot.service <<EOF
[Unit]
Description=Fake SSH Honeypot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${HONEYPOT_DIR}
Environment=HONEYPOT_PORT=${HONEYPOT_PORT}
ExecStart=${HONEYPOT_DIR}/venv/bin/python ${HONEYPOT_DIR}/fake_ssh_server.py
Restart=always
RestartSec=3

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${HONEYPOT_DIR} ${HONEYPOT_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now fake-ssh-honeypot.service
"
}

verify_installation() {
    msg "Verificando servicio del honeypot..."

    pct_exec "systemctl --no-pager --full status fake-ssh-honeypot.service || true"

    msg "Verificando puerto ${HONEYPOT_PORT} dentro del contenedor..."

    pct_exec "ss -tulpn | grep ':${HONEYPOT_PORT} ' || true"

    msg "Verificando que SSH real no esté activo..."

    pct_exec "
echo '--- ssh service ---'
systemctl is-active ssh 2>/dev/null || true
systemctl is-enabled ssh 2>/dev/null || true

echo '--- sshd process ---'
pgrep -a sshd || true

echo '--- openssh-server package ---'
dpkg -l | grep openssh-server || true
"
}

show_summary() {
    msg "Instalación terminada."

    echo
    echo "=============================================="
    echo " CONTENEDOR CREADO"
    echo "=============================================="
    echo "CTID:             $CTID"
    echo "Nombre guest:     $GUEST_NAME"
    echo "Hostname:         $HOSTNAME"
    echo "Template:         $TEMPLATE"
    echo "Bridge:           $BRIDGE"
    echo "VLAN tag:         $VLAN_TAG"
    echo "IP/CIDR:          $CT_IP"
    echo "Gateway:          $GATEWAY"
    echo "Password root CT: $PASSWORD_ROOT"
    echo "Puerto honeypot:  $HONEYPOT_PORT"
    echo "=============================================="
    echo

    echo "IP detectada dentro del contenedor:"
    pct exec "$CTID" -- hostname -I || true

    echo
    echo "Comprobar puerto 22:"
    echo
    echo "  pct exec $CTID -- ss -tulpn"
    echo
    echo "Ver logs JSON:"
    echo
    echo "  pct exec $CTID -- tail -f ${HONEYPOT_LOG_DIR}/events.jsonl"
    echo
    echo "Ver logs del servicio:"
    echo
    echo "  pct exec $CTID -- journalctl -u fake-ssh-honeypot.service -f"
    echo
    echo "Probar desde otra máquina:"
    echo
    echo "  ssh root@${CT_IP%/*}"
    echo
    echo "El SSH real fue eliminado/desactivado. El puerto 22 lo usa Python/Paramiko."
}

main() {
    require_root
    require_cmd pct
    require_cmd pveam

    msg "Iniciando creación del contenedor honeypot SSH falso..."

    download_template_if_needed
    destroy_existing_ct_if_requested
    create_ct

    sleep 8

    wait_for_ct_boot
    wait_for_ct_network
    install_base_packages
    disable_real_ssh
    install_honeypot_files
    create_systemd_service
    verify_installation
    show_summary
}

main "$@"
