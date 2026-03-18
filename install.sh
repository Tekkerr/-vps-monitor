
#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  VPS Monitor v4 — Netdata + 3X-UI plugin + VLESS Checker
#
#  Устанавливает:
#    1. Netdata (системные метрики)
#    2. Плагин 3X-UI для Netdata (клиенты, трафик)
#    3. VLESS Checker + Netdata-плагин (порт, TLS, домены)
#
#  Повторный запуск безопасен: конфиги перезаписываются,
#  старые блоки удаляются перед записью новых.
#
#  sudo bash install.sh
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Цвета ──
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${G}[✓]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err()  { echo -e "${R}[✗]${N} $1"; exit 1; }
ask()  { echo -ne "${C}[?]${N} $1"; }

# ── Валидаторы ──
valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

echo ""
echo -e "${C}═══════════════════════════════════════════════════════════${N}"
echo -e "${C}   VPS Monitor v4 — Netdata + 3X-UI + VLESS Checker     ${N}"
echo -e "${C}═══════════════════════════════════════════════════════════${N}"
echo ""

# ── Root ──
[[ "$EUID" -ne 0 ]] && err "Запусти от root: sudo bash install.sh"

# ── Зависимости ──
for cmd in python3 curl; do
    command -v "$cmd" &>/dev/null || err "$cmd не найден. Установи: apt install python3 curl"
done
if ! command -v ping &>/dev/null; then
    warn "ping не найден, ставлю iputils-ping..."
    apt-get install -y iputils-ping >/dev/null 2>&1 || warn "Не удалось поставить iputils-ping"
fi
ok "Зависимости: python3, curl, ping"

# ═══════════════════════════════════════════════════════════════
# ВВОД ПАРАМЕТРОВ
# ═══════════════════════════════════════════════════════════════

# -- URL панели --
ask "URL панели 3X-UI [https://127.0.0.1:20028]: "; read -r PANEL_URL
PANEL_URL="${PANEL_URL:-https://127.0.0.1:20028}"
PANEL_URL="${PANEL_URL%/}"

# -- Sub-path --
ask "Sub-path панели (например /bZ9FbJRYYXox6vuz9k, пусто если нет): "; read -r PANEL_PATH
PANEL_PATH="${PANEL_PATH%/}"
if [[ -n "$PANEL_PATH" && "${PANEL_PATH:0:1}" != "/" ]]; then
    PANEL_PATH="/$PANEL_PATH"
fi

# -- Логин --
ask "Логин панели: "; read -r PANEL_USER
[[ -z "$PANEL_USER" ]] && err "Логин не может быть пустым"

# -- Пароль --
ask "Пароль панели: "; read -rs PANEL_PASS; echo ""
[[ -z "$PANEL_PASS" ]] && err "Пароль не может быть пустым"

# -- Порт VLESS --
ask "Порт VLESS [29590]: "; read -r VLESS_PORT
VLESS_PORT="${VLESS_PORT:-29590}"
valid_port "$VLESS_PORT" || err "Порт VLESS должен быть числом 1-65535"

# -- Порт Netdata --
ask "Порт Netdata [19999]: "; read -r ND_PORT
ND_PORT="${ND_PORT:-19999}"
valid_port "$ND_PORT" || err "Порт Netdata должен быть числом 1-65535"

# -- Режим доступа --
echo ""
echo -e "  ${C}Режим доступа к Netdata:${N}"
echo -e "  ${C}1${N} — только localhost (безопасно, доступ через SSH-туннель)"
echo -e "  ${C}2${N} — открыт по IP (нужен файрвол)"
ask "Выбери [1]: "; read -r ACCESS_MODE
ACCESS_MODE="${ACCESS_MODE:-1}"
if [[ "$ACCESS_MODE" != "1" && "$ACCESS_MODE" != "2" ]]; then
    warn "Неизвестный режим '${ACCESS_MODE}', ставлю 1 (localhost)"
    ACCESS_MODE="1"
fi

TRUSTED_IP=""
if [[ "$ACCESS_MODE" == "2" ]]; then
    ask "Твой IP для доступа (для ufw allow, пусто — пропустить): "; read -r TRUSTED_IP
fi

echo ""
ok "Панель:  ${PANEL_URL}${PANEL_PATH}"
ok "VLESS:   порт ${VLESS_PORT}"
ok "Netdata: порт ${ND_PORT}"
if [[ "$ACCESS_MODE" == "1" ]]; then
    ok "Доступ:  localhost (SSH-туннель)"
else
    ok "Доступ:  открыт по IP"
    [[ -n "$TRUSTED_IP" ]] && ok "Trusted: ${TRUSTED_IP}"
fi

# ═══════════════════════════════════════════════════════════════
# ПРОВЕРКА 3X-UI
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}── Проверка подключения к 3X-UI ──${N}"

XTEST_URL="${PANEL_URL}${PANEL_PATH}/login" \
XTEST_USER="$PANEL_USER" \
XTEST_PASS="$PANEL_PASS" \
python3 - <<'PYCHECK' && ok "3X-UI: логин успешен" || {
import os, urllib.request, ssl, json, sys
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
data = json.dumps({
    "username": os.environ["XTEST_USER"],
    "password": os.environ["XTEST_PASS"],
}).encode()
req = urllib.request.Request(
    os.environ["XTEST_URL"], data=data,
    headers={"Content-Type": "application/json"}, method="POST"
)
try:
    resp = urllib.request.urlopen(req, context=ctx, timeout=10)
    r = json.loads(resp.read())
    sys.exit(0 if r.get("success") else 1)
except Exception as e:
    print(f"Ошибка: {e}", file=sys.stderr)
    sys.exit(1)
PYCHECK
    warn "Не удалось подключиться к 3X-UI"
    ask "Продолжить установку? (y/N): "; read -r CONT
    [[ "$CONT" != "y" && "$CONT" != "Y" ]] && exit 1
}

# ═══════════════════════════════════════════════════════════════
# 1. NETDATA
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}── Шаг 1/5: Netdata ──${N}"

if command -v netdata &>/dev/null; then
    ok "Netdata уже установлен, пропускаю"
else
    ok "Устанавливаю Netdata..."
    curl -Ss https://get.netdata.cloud/kickstart.sh -o /tmp/nd-kick.sh
    bash /tmp/nd-kick.sh --dont-wait --no-updates --stable-channel
    rm -f /tmp/nd-kick.sh
    ok "Netdata установлен"
fi

# -- Находим пути --
PLUGIN_DIR=""
for d in /usr/libexec/netdata/plugins.d /opt/netdata/usr/libexec/netdata/plugins.d; do
    [[ -d "$d" ]] && { PLUGIN_DIR="$d"; break; }
done
[[ -z "$PLUGIN_DIR" ]] && err "Директория плагинов Netdata не найдена"

ND_CONFDIR=""
for d in /etc/netdata /opt/netdata/etc/netdata; do
    [[ -d "$d" ]] && { ND_CONFDIR="$d"; break; }
done
[[ -z "$ND_CONFDIR" ]] && err "Директория конфигов Netdata не найдена"

ok "Плагины:  ${PLUGIN_DIR}"
ok "Конфиги:  ${ND_CONFDIR}"

# -- Конфигурация через netdata.conf.d (не трогаем основной файл) --
mkdir -p "${ND_CONFDIR}/netdata.conf.d"

BIND_TO="127.0.0.1"
[[ "$ACCESS_MODE" == "2" ]] && BIND_TO="*"

cat > "${ND_CONFDIR}/netdata.conf.d/90-vps-monitor.conf" << EOF
# Auto-generated by VPS Monitor v4. Safe to delete.
[web]
    default port = ${ND_PORT}
    bind to = ${BIND_TO}
EOF

ok "netdata.conf.d/90-vps-monitor.conf (bind=${BIND_TO}, port=${ND_PORT})"

# ═══════════════════════════════════════════════════════════════
# 2. CREDENTIALS
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}── Шаг 2/5: Credentials ──${N}"

CRED_FILE="${ND_CONFDIR}/3xui-credentials.json"

# Генерируем JSON через Python — безопасно к любым спецсимволам
XPURL="$PANEL_URL" \
XPPATH="$PANEL_PATH" \
XPUSER="$PANEL_USER" \
XPPASS="$PANEL_PASS" \
python3 - <<'PYCRED' > "$CRED_FILE"
import os, json
print(json.dumps({
    "panel_url": os.environ["XPURL"],
    "panel_path": os.environ["XPPATH"],
    "panel_user": os.environ["XPUSER"],
    "panel_pass": os.environ["XPPASS"],
}, ensure_ascii=False, indent=2))
PYCRED

chmod 600 "$CRED_FILE"
chown netdata:netdata "$CRED_FILE" 2>/dev/null || true
ok "${CRED_FILE} (chmod 600, owner netdata)"

# ═══════════════════════════════════════════════════════════════
# 3. ПЛАГИН 3X-UI
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}── Шаг 3/5: 3X-UI плагин ──${N}"

cat > "${PLUGIN_DIR}/3xui.plugin" << 'XPLUGIN'
#!/usr/bin/env python3
"""
Netdata external plugin: 3X-UI client metrics.

Charts:
  3xui.traffic      — total download/upload (bytes)
  3xui.clients      — online/total count
  3xui.client_down  — per-client download (GiB, stacked)
  3xui.client_up    — per-client upload (GiB, stacked)

Dimensions are declared at startup from the current client list.
New clients added after startup require: systemctl restart netdata

Reads credentials from /etc/netdata/3xui-credentials.json
(or /opt/netdata/etc/netdata/3xui-credentials.json).
"""
import sys, os, json, time, ssl, re, urllib.request

# ── Config ──

CRED_SEARCH = [
    "/etc/netdata/3xui-credentials.json",
    "/opt/netdata/etc/netdata/3xui-credentials.json",
]

def load_config():
    for p in CRED_SEARCH:
        if os.path.exists(p):
            try:
                with open(p) as f:
                    return json.load(f)
            except Exception as e:
                print(f"3xui.plugin: failed to read {p}: {e}", file=sys.stderr)
    print("3xui.plugin: no credentials file found, exiting", file=sys.stderr)
    sys.exit(1)

CFG = load_config()
BASE_URL = CFG["panel_url"].rstrip("/") + CFG.get("panel_path", "")
USER = CFG["panel_user"]
PASS = CFG["panel_pass"]

# ── HTTP ──

_cookie = ""
_ctx = ssl.create_default_context()
_ctx.check_hostname = False
_ctx.verify_mode = ssl.CERT_NONE

def _api(method, endpoint, body=None):
    global _cookie
    url = BASE_URL + endpoint
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if _cookie:
        headers["Cookie"] = _cookie
    data = json.dumps(body).encode() if body and method != "GET" else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req, context=_ctx, timeout=10)
        for sc in (resp.headers.get_all("Set-Cookie") or []):
            part = sc.split(";")[0]
            if "=" in part and len(part) > 10 and "lang" not in part.lower():
                _cookie = part
        return json.loads(resp.read().decode())
    except Exception as e:
        print(f"3xui.plugin: {method} {endpoint}: {e}", file=sys.stderr)
        return {"success": False}

def _login():
    r = _api("POST", "/login", {"username": USER, "password": PASS})
    if not r.get("success"):
        print("3xui.plugin: login failed", file=sys.stderr)
    return r.get("success", False)

def _get_inbounds():
    """Fetch inbounds, retry with re-login on failure."""
    r = _api("GET", "/panel/api/inbounds/list")
    if not r.get("success"):
        _login()
        r = _api("GET", "/panel/api/inbounds/list")
    return r

# ── Helpers ──

def safe_dim(name):
    """Only [A-Za-z0-9_], collapse runs of _ to single _."""
    s = re.sub(r'[^A-Za-z0-9_]', '_', name)
    s = re.sub(r'_+', '_', s).strip('_')
    return s or "unknown"

def collect_dims(inbounds_obj):
    """Extract unique sanitized dimension names from inbounds."""
    dims = []
    seen = set()
    for inb in (inbounds_obj or []):
        for c in inb.get("clientStats", []):
            d = safe_dim(c.get("email", "unknown"))
            if d not in seen:
                seen.add(d)
                dims.append(d)
    return dims

# ── Main ──

def main():
    update_every = int(sys.argv[1]) if len(sys.argv) > 1 else 15

    # Initial login + dimension discovery
    _login()
    ib = _get_inbounds()
    dims = collect_dims(ib.get("obj", []))

    # Retry once if empty
    if not dims:
        print("3xui.plugin: no clients found, retrying in 10s...", file=sys.stderr)
        time.sleep(10)
        _login()
        ib = _get_inbounds()
        dims = collect_dims(ib.get("obj", []))

    # ── Declare charts (ONCE) ──

    print(f"CHART 3xui.traffic '' '3X-UI total traffic' 'bytes' vpn 3xui.traffic area {update_every} {update_every}")
    print("DIMENSION download '' absolute 1 1")
    print("DIMENSION upload '' absolute 1 1")
    print("")

    print(f"CHART 3xui.clients '' '3X-UI clients' 'clients' vpn 3xui.clients line {update_every} {update_every}")
    print("DIMENSION online '' absolute 1 1")
    print("DIMENSION total '' absolute 1 1")
    print("")

    if dims:
        print(f"CHART 3xui.client_down '' 'Download per client' 'GiB' vpn 3xui.client_down stacked {update_every} {update_every}")
        for d in dims:
            print(f"DIMENSION {d} '' absolute 1 1073741824")
        print("")

        print(f"CHART 3xui.client_up '' 'Upload per client' 'GiB' vpn 3xui.client_up stacked {update_every} {update_every}")
        for d in dims:
            print(f"DIMENSION {d} '' absolute 1 1073741824")
        print("")
    else:
        print("3xui.plugin: WARNING: no dimensions, per-client charts disabled", file=sys.stderr)

    sys.stdout.flush()

    # ── Collection loop ──

    consecutive_fails = 0

    while True:
        time.sleep(update_every)

        ib = _get_inbounds()
        if not ib.get("success"):
            consecutive_fails += 1
            if consecutive_fails == 1 or consecutive_fails % 20 == 0:
                print(f"3xui.plugin: fetch failed ({consecutive_fails}x)", file=sys.stderr)
            continue

        consecutive_fails = 0
        now_ms = int(time.time() * 1000)
        total_up = total_down = online_count = total_count = 0
        per_client = {}

        for inb in ib.get("obj", []):
            for c in inb.get("clientStats", []):
                total_count += 1
                up = c.get("up", 0)
                down = c.get("down", 0)
                total_up += up
                total_down += down
                last = c.get("lastOnline", 0)
                if last and (now_ms - last) < 120000:
                    online_count += 1
                dim = safe_dim(c.get("email", "unknown"))
                # If same dim name from multiple inbounds, sum them
                if dim in per_client:
                    per_client[dim]["d"] += down
                    per_client[dim]["u"] += up
                else:
                    per_client[dim] = {"d": down, "u": up}

        print("BEGIN 3xui.traffic")
        print(f"SET download = {total_down}")
        print(f"SET upload = {total_up}")
        print("END")

        print("BEGIN 3xui.clients")
        print(f"SET online = {online_count}")
        print(f"SET total = {total_count}")
        print("END")

        if dims:
            print("BEGIN 3xui.client_down")
            for d in dims:
                val = per_client.get(d, {}).get("d", 0)
                print(f"SET {d} = {val}")
            print("END")

            print("BEGIN 3xui.client_up")
            for d in dims:
                val = per_client.get(d, {}).get("u", 0)
                print(f"SET {d} = {val}")
            print("END")

        sys.stdout.flush()

if __name__ == "__main__":
    main()
XPLUGIN

chmod 755 "${PLUGIN_DIR}/3xui.plugin"
chown root:netdata "${PLUGIN_DIR}/3xui.plugin" 2>/dev/null || true
ok "3xui.plugin → ${PLUGIN_DIR}/"

# ═══════════════════════════════════════════════════════════════
# 4. VLESS CHECKER + NETDATA PLUGIN
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}── Шаг 4/5: VLESS Checker ──${N}"

CHECKER_DIR="/opt/vless-checker"
mkdir -p "${CHECKER_DIR}/logs"

# -- checker.py --
cat > "${CHECKER_DIR}/checker.py" << 'CHECKER'
#!/usr/bin/env python3
"""
VLESS/RKN Checker — мониторинг доступности VLESS-порта.

Проверяет С САМОГО VPS (не из России).
Показывает: порт жив, TLS handshake время, ping baseline, домены.
Для проверки из РФ нужен внешний probe (OpenWrt/OONI/RIPE Atlas).

Пишет метрики в JSON для Netdata-плагина.
Логи — в /opt/vless-checker/logs/YYYYMMDD.jsonl
"""
import socket, time, json, os, sys, subprocess, statistics, ssl
from datetime import datetime

VLESS_PORT = int(os.environ.get("VLESS_PORT", "29590"))
INTERVAL   = int(os.environ.get("CHECK_INTERVAL", "300"))
METRICS    = os.environ.get("METRICS_FILE", "/opt/vless-checker/metrics.json")
LOGDIR     = os.environ.get("LOG_DIR", "/opt/vless-checker/logs")

DOMAINS = [
    ("google.com", 443),
    ("youtube.com", 443),
    ("instagram.com", 443),
    ("twitter.com", 443),
    ("facebook.com", 443),
    ("discord.com", 443),
    ("telegram.org", 443),
    ("linkedin.com", 443),
]

history = []

def get_external_ip():
    """Get the primary outbound IP of this machine."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

def tcp_check(host, port, timeout=10):
    """TCP connect check. Returns (is_open, latency_ms)."""
    try:
        t0 = time.time()
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        ok = (s.connect_ex((host, port)) == 0)
        ms = round((time.time() - t0) * 1000, 1)
        s.close()
        return ok, (ms if ok else None)
    except Exception:
        return False, None

def tls_check(host, port, timeout=10):
    """TLS handshake check. Returns (success, latency_ms)."""
    t0 = time.time()
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        raw.settimeout(timeout)
        wrapped = ctx.wrap_socket(raw, server_hostname=host)
        wrapped.connect((host, port))
        ms = round((time.time() - t0) * 1000, 1)
        wrapped.close()
        return True, ms
    except Exception:
        ms = round((time.time() - t0) * 1000, 1)
        return False, ms

def ping_ms(host, count=3):
    """Ping host, return average ms or None."""
    try:
        r = subprocess.run(
            ["ping", "-c", str(count), "-W", "5", host],
            capture_output=True, text=True, timeout=20
        )
        if r.returncode == 0:
            for line in r.stdout.split("\n"):
                if "avg" in line and "/" in line:
                    return round(float(line.split("=")[1].strip().split("/")[1]), 1)
    except Exception:
        pass
    return None

def run_check():
    ip = get_external_ip()

    tcp_up, tcp_ms = tcp_check(ip, VLESS_PORT)
    tls_ok, tls_ms = tls_check(ip, VLESS_PORT)
    pg = ping_ms("8.8.8.8")

    domains_up = 0
    domain_detail = {}
    for domain, port in DOMAINS:
        up, _ = tcp_check(domain, port, timeout=5)
        domain_detail[domain] = up
        if up:
            domains_up += 1

    return {
        "tcp_up": tcp_up, "tcp_ms": tcp_ms,
        "tls_ok": tls_ok, "tls_ms": tls_ms,
        "ping": pg,
        "domains_up": domains_up, "domains_total": len(DOMAINS),
        "domains": domain_detail,
    }

def check_alerts(r):
    alerts = []

    if not r["tcp_up"]:
        alerts.append(f"CRIT: VLESS port {VLESS_PORT} is DOWN")

    if r["tls_ms"] is not None and r["tls_ms"] > 3000:
        alerts.append(f"WARN: TLS handshake slow: {r['tls_ms']}ms")

    # Spike detection vs recent history
    if len(history) >= 5 and r["tcp_ms"] is not None:
        recent = [h["tcp_ms"] for h in history[-10:] if h.get("tcp_ms") is not None]
        if recent:
            avg = statistics.mean(recent)
            if avg > 0 and r["tcp_ms"] > avg * 3:
                alerts.append(f"WARN: TCP latency spike {r['tcp_ms']}ms (avg {avg:.0f}ms)")

    blocked = [d for d, up in r.get("domains", {}).items() if not up]
    if blocked:
        alerts.append(f"INFO: unreachable from VPS: {', '.join(blocked)}")

    return alerts

def write_metrics(r, alerts):
    m = {
        "ts": int(time.time()),
        "tcp_up": 1 if r["tcp_up"] else 0,
        "tcp_ms": r["tcp_ms"] if r["tcp_ms"] is not None else -1,
        "tls_ms": r["tls_ms"] if r["tls_ms"] is not None else -1,
        "ping": r["ping"] if r["ping"] is not None else -1,
        "domains_up": r["domains_up"],
        "domains_total": r["domains_total"],
        "alerts": len(alerts),
    }
    try:
        # Write atomically via tmp file
        tmp = METRICS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(m, f)
        os.replace(tmp, METRICS)
    except Exception as e:
        print(f"[checker] write error: {e}", file=sys.stderr, flush=True)

def write_log(ts_str, r, alerts):
    log_file = os.path.join(LOGDIR, f"{datetime.now().strftime('%Y%m%d')}.jsonl")
    try:
        with open(log_file, "a") as f:
            f.write(json.dumps({"ts": ts_str, "r": r, "a": alerts}) + "\n")
    except Exception:
        pass

def main():
    print(f"[checker] VLESS port={VLESS_PORT}, interval={INTERVAL}s", flush=True)

    while True:
        try:
            r = run_check()
            alerts = check_alerts(r)
            write_metrics(r, alerts)

            history.append(r)
            if len(history) > 60:
                del history[:30]

            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            write_log(ts, r, alerts)

            status = "UP" if r["tcp_up"] else "DOWN"
            line = f"[{ts}] VLESS:{status}({r['tcp_ms']}ms) TLS:{r['tls_ms']}ms Ping:{r['ping']}ms Dom:{r['domains_up']}/{r['domains_total']}"
            print(line, flush=True)
            for a in alerts:
                print(f"[{ts}] ⚠ {a}", flush=True)

        except Exception as e:
            print(f"[checker] error: {e}", file=sys.stderr, flush=True)

        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
CHECKER

chmod +x "${CHECKER_DIR}/checker.py"
ok "checker.py → ${CHECKER_DIR}/"

# -- Netdata plugin for checker metrics --
cat > "${PLUGIN_DIR}/vless-checker.plugin" << 'VCHKPLUG'
#!/usr/bin/env python3
"""
Netdata external plugin: reads VLESS checker metrics from JSON.
File: /opt/vless-checker/metrics.json (written by checker.py)

Charts:
  vless.latency  — TCP/TLS/ping latency (ms)
  vless.status   — port up/down (bool)
  vless.domains  — accessible/blocked domain count
"""
import sys, json, time, os

METRICS_FILE = "/opt/vless-checker/metrics.json"
STALE_SECONDS = 600  # ignore data older than 10 min

def main():
    update_every = int(sys.argv[1]) if len(sys.argv) > 1 else 15

    # Declare charts ONCE
    print(f"CHART vless.latency '' 'VLESS latency' 'ms' vless vless.latency line {update_every} {update_every}")
    print("DIMENSION tcp '' absolute 1 1")
    print("DIMENSION tls '' absolute 1 1")
    print("DIMENSION ping '' absolute 1 1")
    print("")

    print(f"CHART vless.status '' 'VLESS port status' 'up/down' vless vless.status line {update_every} {update_every}")
    print("DIMENSION up '' absolute 1 1")
    print("")

    print(f"CHART vless.domains '' 'Domain accessibility' 'count' vless vless.domains stacked {update_every} {update_every}")
    print("DIMENSION accessible '' absolute 1 1")
    print("DIMENSION blocked '' absolute 1 1")
    print("")

    sys.stdout.flush()

    while True:
        time.sleep(update_every)

        if not os.path.exists(METRICS_FILE):
            continue

        try:
            with open(METRICS_FILE) as f:
                m = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            print(f"vless-checker.plugin: read error: {e}", file=sys.stderr)
            continue

        # Skip stale
        if time.time() - m.get("ts", 0) > STALE_SECONDS:
            continue

        tcp = max(0, int(m.get("tcp_ms", 0)))
        tls = max(0, int(m.get("tls_ms", 0)))
        pg  = max(0, int(m.get("ping", 0)))
        up  = m.get("tcp_up", 0)
        dok = m.get("domains_up", 0)
        dt  = m.get("domains_total", 0)

        print("BEGIN vless.latency")
        print(f"SET tcp = {tcp}")
        print(f"SET tls = {tls}")
        print(f"SET ping = {pg}")
        print("END")

        print("BEGIN vless.status")
        print(f"SET up = {up}")
        print("END")

        print("BEGIN vless.domains")
        print(f"SET accessible = {dok}")
        print(f"SET blocked = {dt - dok}")
        print("END")

        sys.stdout.flush()

if __name__ == "__main__":
    main()
VCHKPLUG

chmod 755 "${PLUGIN_DIR}/vless-checker.plugin"
chown root:netdata "${PLUGIN_DIR}/vless-checker.plugin" 2>/dev/null || true
ok "vless-checker.plugin → ${PLUGIN_DIR}/"

# ═══════════════════════════════════════════════════════════════
# 5. SYSTEMD + РЕГИСТРАЦИЯ ПЛАГИНОВ
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}── Шаг 5/5: Systemd + регистрация плагинов ──${N}"

# -- Checker systemd service --
cat > /etc/systemd/system/vless-checker.service << EOF
[Unit]
Description=VLESS/RKN Availability Checker
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${CHECKER_DIR}/checker.py
Restart=always
RestartSec=30
Environment=VLESS_PORT=${VLESS_PORT}
Environment=CHECK_INTERVAL=300
Environment=METRICS_FILE=/opt/vless-checker/metrics.json
Environment=LOG_DIR=${CHECKER_DIR}/logs

[Install]
WantedBy=multi-user.target
EOF

# -- Явная регистрация плагинов в netdata.conf.d --
# Netdata автоматически исполняет .plugin файлы из plugins.d,
# но явная регистрация гарантирует правильный update_every
cat > "${ND_CONFDIR}/netdata.conf.d/91-3xui-plugin.conf" << EOF
# 3X-UI plugin registration
[plugin:3xui]
    update every = 15
EOF

cat > "${ND_CONFDIR}/netdata.conf.d/92-vless-checker-plugin.conf" << EOF
# VLESS checker plugin registration
[plugin:vless-checker]
    update every = 15
EOF

ok "Плагины зарегистрированы в netdata.conf.d/"

# -- Запуск сервисов --
systemctl daemon-reload

systemctl enable --now vless-checker 2>/dev/null
sleep 2
if systemctl is-active --quiet vless-checker; then
    ok "vless-checker: работает"
else
    warn "vless-checker: не стартовал — journalctl -u vless-checker -n 20"
fi

systemctl restart netdata
sleep 4
if systemctl is-active --quiet netdata; then
    ok "netdata: работает"
else
    warn "netdata: не стартовал — journalctl -u netdata -n 20"
fi

# -- Проверка что плагины реально подхвачены --
echo ""
echo -e "${C}── Проверка плагинов ──${N}"
sleep 2

if journalctl -u netdata --no-pager -n 50 2>/dev/null | grep -qi "3xui"; then
    ok "3xui.plugin обнаружен Netdata"
else
    warn "3xui.plugin пока не видно в логах (может появиться через ~15 сек)"
fi

if journalctl -u netdata --no-pager -n 50 2>/dev/null | grep -qi "vless"; then
    ok "vless-checker.plugin обнаружен Netdata"
else
    warn "vless-checker.plugin пока не видно в логах (может появиться через ~15 сек)"
fi

# ═══════════════════════════════════════════════════════════════
# ИТОГО
# ═══════════════════════════════════════════════════════════════

# Получаем публичный IP (с fallback)
PUB_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "UNKNOWN")
VPS_IP="${PUB_IP:-$LOCAL_IP}"

echo ""
echo -e "${G}═══════════════════════════════════════════════════════════${N}"
echo -e "${G}   Установка завершена!${N}"
echo -e "${G}═══════════════════════════════════════════════════════════${N}"
echo ""

if [[ "$ACCESS_MODE" == "1" ]]; then
    echo -e "  ${C}Доступ через SSH-туннель:${N}"
    echo ""
    echo -e "    ${G}ssh -L ${ND_PORT}:127.0.0.1:${ND_PORT} root@${VPS_IP}${N}"
    echo ""
    echo -e "  Затем открой в браузере:"
    echo -e "    ${G}http://localhost:${ND_PORT}${N}"
else
    echo -e "  ${C}Дашборд:${N}"
    echo -e "    ${G}http://${VPS_IP}:${ND_PORT}${N}"
    echo ""
    if [[ -n "$TRUSTED_IP" ]]; then
        echo -e "  ${Y}Настрой файрвол:${N}"
        echo -e "    ufw default deny incoming"
        echo -e "    ufw allow 22/tcp"
        echo -e "    ufw allow ${VLESS_PORT}/tcp"
        echo -e "    ufw allow from ${TRUSTED_IP} to any port ${ND_PORT}"
        echo -e "    ufw enable"
    else
        echo -e "  ${Y}⚠ Порт ${ND_PORT} открыт всем! Настрой ufw:${N}"
        echo -e "    ufw allow 22/tcp && ufw allow ${VLESS_PORT}/tcp"
        echo -e "    ufw allow from <ТВОЙ_IP> to any port ${ND_PORT}"
        echo -e "    ufw enable"
    fi
fi

echo ""
echo -e "  ${C}Проверка:${N}"
echo -e "    systemctl status netdata"
echo -e "    systemctl status vless-checker"
echo -e "    journalctl -u netdata -n 30"
echo -e "    journalctl -u vless-checker -f"
echo ""
echo -e "  ${C}Логи checker:${N}"
echo -e "    ${CHECKER_DIR}/logs/"
echo ""
echo -e "  ${Y}Ограничения:${N}"
echo -e "    • Новые клиенты 3X-UI → systemctl restart netdata"
echo -e "    • Checker проверяет порт с VPS, не из РФ"
echo -e "    • Probe для OpenWrt → следующий шаг"
echo ""
