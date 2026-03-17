#!/bin/bash
# ═══════════════════════════════════════════════════════
#  VPS Monitor — Установка Netdata + 3X-UI плагин + Checker
#  Запусти на VPS: bash install.sh
# ═══════════════════════════════════════════════════════
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; }
ask() { echo -ne "${CYAN}[?]${NC} $1"; }

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   VPS Monitor — Netdata + 3X-UI + RKN Checker${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""

# ─── Проверки ───
if [ "$EUID" -ne 0 ]; then err "Запусти от root: sudo bash install.sh"; exit 1; fi

# ─── Сбор данных ───
ask "URL панели 3X-UI [https://127.0.0.1:20028]: "; read PANEL_URL
PANEL_URL=${PANEL_URL:-https://127.0.0.1:20028}

ask "Sub-path панели (например /bZ9FbJRYYXox6vuz9k): "; read PANEL_PATH

ask "Логин панели: "; read PANEL_USER

ask "Пароль панели: "; read -s PANEL_PASS; echo ""

ask "Порт VLESS на этом VPS [29590]: "; read VLESS_PORT
VLESS_PORT=${VLESS_PORT:-29590}

ask "Порт Netdata [19999]: "; read ND_PORT
ND_PORT=${ND_PORT:-19999}

echo ""
log "URL: ${PANEL_URL}${PANEL_PATH}"
log "VLESS порт: ${VLESS_PORT}"
log "Netdata порт: ${ND_PORT}"
echo ""

# ═══════════════════════════════════════════════════════
# 1. УСТАНОВКА NETDATA
# ═══════════════════════════════════════════════════════
echo -e "${CYAN}── Шаг 1: Netdata ──${NC}"

if command -v netdata &>/dev/null; then
    warn "Netdata уже установлен, пропускаю"
else
    log "Устанавливаю Netdata..."
    curl -Ss https://get.netdata.cloud/kickstart.sh > /tmp/netdata-kickstart.sh
    bash /tmp/netdata-kickstart.sh --dont-wait --no-updates --stable-channel
    log "Netdata установлен"
fi

# Настроить порт
if [ "$ND_PORT" != "19999" ]; then
    log "Меняю порт Netdata на ${ND_PORT}..."
    sed -i "s/# default port = 19999/default port = ${ND_PORT}/" /etc/netdata/netdata.conf 2>/dev/null || true
    cat >> /etc/netdata/netdata.conf << EOF

[web]
    default port = ${ND_PORT}
EOF
fi

# Разрешить доступ только с VPN-подсети и localhost
log "Настраиваю доступ к Netdata (только localhost + VPN)..."
cat >> /etc/netdata/netdata.conf << EOF

[web]
    allow connections from = localhost 10.* 172.16.* 192.168.* fd*
    allow dashboard from = localhost 10.* 172.16.* 192.168.* fd*
EOF

systemctl restart netdata 2>/dev/null || service netdata restart 2>/dev/null || true
log "Netdata запущен на порту ${ND_PORT}"

# ═══════════════════════════════════════════════════════
# 2. ПЛАГИН 3X-UI ДЛЯ NETDATA
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}── Шаг 2: Плагин 3X-UI для Netdata ──${NC}"

PLUGIN_DIR="/usr/libexec/netdata/plugins.d"
CONF_DIR="/etc/netdata"

# Найти правильную директорию плагинов
if [ ! -d "$PLUGIN_DIR" ]; then
    PLUGIN_DIR="/opt/netdata/usr/libexec/netdata/plugins.d"
fi
if [ ! -d "$CONF_DIR" ]; then
    CONF_DIR="/opt/netdata/etc/netdata"
fi

log "Директория плагинов: ${PLUGIN_DIR}"

# Создаём плагин
cat > ${PLUGIN_DIR}/3xui.plugin << 'PLUGINEOF'
#!/usr/bin/env python3
"""
Netdata external plugin — 3X-UI metrics.
Reads from 3X-UI API and outputs charts in Netdata format.
"""
import sys, os, json, time, ssl, urllib.request, urllib.error

PANEL_URL = os.environ.get("XPANEL_URL", "https://127.0.0.1:20028")
PANEL_PATH = os.environ.get("XPANEL_PATH", "")
PANEL_USER = os.environ.get("XPANEL_USER", "admin")
PANEL_PASS = os.environ.get("XPANEL_PASS", "")
UPDATE_EVERY = int(os.environ.get("XPANEL_INTERVAL", "15"))

cookie = ""
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def api(method, ep, body=None):
    global cookie
    url = PANEL_URL.rstrip("/") + PANEL_PATH + ep
    hd = {"Content-Type": "application/json", "Accept": "application/json"}
    if cookie: hd["Cookie"] = cookie
    data = json.dumps(body).encode() if body and method != "GET" else None
    req = urllib.request.Request(url, data=data, headers=hd, method=method)
    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=10)
        for sc in (resp.headers.get_all("Set-Cookie") or []):
            cp = sc.split(";")[0]
            if "=" in cp and len(cp) > 10 and "lang" not in cp.lower():
                cookie = cp
        return json.loads(resp.read().decode())
    except:
        return {"success": False}

def login():
    return api("POST", "/login", {"username": PANEL_USER, "password": PANEL_PASS})

def main():
    update = int(sys.argv[1]) if len(sys.argv) > 1 else UPDATE_EVERY

    login()

    # Define charts
    print(f"CHART 3xui.traffic '' '3X-UI client traffic' 'GB' 3xui 3xui.traffic stacked {update} {update}")
    print("DIMENSION download '' absolute 1 1073741824")
    print("DIMENSION upload '' absolute 1 1073741824")

    print(f"CHART 3xui.clients '' '3X-UI clients' 'clients' 3xui 3xui.clients line {update} {update}")
    print("DIMENSION online '' absolute 1 1")
    print("DIMENSION total '' absolute 1 1")

    print(f"CHART 3xui.client_traffic '' '3X-UI traffic per client' 'GB' 3xui 3xui.client_traffic stacked {update} {update}")

    known_clients = set()

    while True:
        time.sleep(update)

        ib = api("GET", "/panel/api/inbounds/list")
        if not ib.get("success"):
            login()
            ib = api("GET", "/panel/api/inbounds/list")
        if not ib.get("success"):
            continue

        now = int(time.time() * 1000)
        total_up = 0
        total_down = 0
        online = 0
        total = 0
        clients = []

        for inb in ib.get("obj", []):
            for c in inb.get("clientStats", []):
                total += 1
                up = c.get("up", 0)
                down = c.get("down", 0)
                total_up += up
                total_down += down
                email = c.get("email", "unknown")
                last = c.get("lastOnline", 0)
                if last and (now - last) < 120000:
                    online += 1
                clients.append((email, down, up))

                # Dynamic dimensions
                safe = email.replace(" ", "_").replace(".", "_")
                if safe not in known_clients:
                    known_clients.add(safe)
                    print(f"CHART 3xui.client_traffic '' '3X-UI traffic per client' 'GB' 3xui 3xui.client_traffic stacked {update} {update}")
                    for kn in known_clients:
                        print(f"DIMENSION {kn} '' absolute 1 1073741824")

        # Total traffic
        print("BEGIN 3xui.traffic")
        print(f"SET download = {total_down}")
        print(f"SET upload = {total_up}")
        print("END")

        # Clients
        print("BEGIN 3xui.clients")
        print(f"SET online = {online}")
        print(f"SET total = {total}")
        print("END")

        # Per-client traffic
        print("BEGIN 3xui.client_traffic")
        for email, down, up in clients:
            safe = email.replace(" ", "_").replace(".", "_")
            print(f"SET {safe} = {down + up}")
        print("END")

        sys.stdout.flush()

if __name__ == "__main__":
    main()
PLUGINEOF

chmod +x ${PLUGIN_DIR}/3xui.plugin
chown netdata:netdata ${PLUGIN_DIR}/3xui.plugin 2>/dev/null || true

# Конфиг с credentials
cat > /etc/netdata/3xui.conf << EOF
# 3X-UI Plugin Configuration
XPANEL_URL=${PANEL_URL}
XPANEL_PATH=${PANEL_PATH}
XPANEL_USER=${PANEL_USER}
XPANEL_PASS=${PANEL_PASS}
XPANEL_INTERVAL=15
EOF
chmod 600 /etc/netdata/3xui.conf

# Добавить переменные окружения в Netdata
mkdir -p /etc/netdata
cat > /etc/netdata/3xui-env.conf << EOF
XPANEL_URL=${PANEL_URL}
XPANEL_PATH=${PANEL_PATH}
XPANEL_USER=${PANEL_USER}
XPANEL_PASS=${PANEL_PASS}
XPANEL_INTERVAL=15
EOF
chmod 600 /etc/netdata/3xui-env.conf

# Добавить в Netdata как external plugin
NETDATA_CONF="/etc/netdata/netdata.conf"
if ! grep -q "3xui" "$NETDATA_CONF" 2>/dev/null; then
    cat >> "$NETDATA_CONF" << EOF

[plugin:3xui]
    command = env \$(cat /etc/netdata/3xui-env.conf | tr '\n' ' ') ${PLUGIN_DIR}/3xui.plugin
    update every = 15
EOF
fi

log "Плагин 3X-UI установлен"

# ═══════════════════════════════════════════════════════
# 3. RKN / VLESS CHECKER
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}── Шаг 3: RKN / VLESS Checker ──${NC}"

CHECKER_DIR="/opt/vps-checker"
mkdir -p ${CHECKER_DIR}
mkdir -p ${CHECKER_DIR}/logs

cat > ${CHECKER_DIR}/checker.py << CHECKEREOF
#!/usr/bin/env python3
"""
RKN/VLESS Availability Checker
Проверяет доступность VLESS-порта с разных точек,
мониторит задержки и определяет замедление/блокировку.
Пишет логи и метрики для Netdata.
"""
import socket, time, json, os, sys, subprocess, statistics
from datetime import datetime

VLESS_PORT = int(os.environ.get("VLESS_PORT", "${VLESS_PORT}"))
CHECK_INTERVAL = 300  # 5 минут
LOG_DIR = "${CHECKER_DIR}/logs"
METRICS_FILE = "${CHECKER_DIR}/metrics.json"

# Точки проверки — IP этого сервера проверяем изнутри + тестовые хосты
# Для проверки "снаружи" используем TCP connect к своему порту
SERVER_IP = None

def get_server_ip():
    """Определить внешний IP сервера."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"

def check_port(host, port, timeout=10):
    """Проверить доступность TCP-порта, вернуть задержку в мс."""
    try:
        start = time.time()
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((host, port))
        elapsed = (time.time() - start) * 1000
        sock.close()
        if result == 0:
            return {"status": "open", "latency_ms": round(elapsed, 1)}
        else:
            return {"status": "closed", "latency_ms": None}
    except socket.timeout:
        return {"status": "timeout", "latency_ms": None}
    except Exception as e:
        return {"status": f"error: {e}", "latency_ms": None}

def ping_host(host, count=3):
    """Пинг хоста, вернуть среднюю задержку."""
    try:
        result = subprocess.run(
            ["ping", "-c", str(count), "-W", "5", host],
            capture_output=True, text=True, timeout=20
        )
        if result.returncode == 0:
            # Парсим avg из "rtt min/avg/max/mdev = ..."
            for line in result.stdout.split("\n"):
                if "avg" in line and "/" in line:
                    parts = line.split("=")[1].strip().split("/")
                    return {"status": "ok", "avg_ms": round(float(parts[1]), 1)}
        return {"status": "fail", "avg_ms": None}
    except:
        return {"status": "fail", "avg_ms": None}

def check_tls_handshake(host, port, timeout=10):
    """Проверить TLS handshake — имитация того что делает ТСПУ."""
    import ssl
    try:
        start = time.time()
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        ssock = ctx.wrap_socket(sock, server_hostname=host)
        ssock.connect((host, port))
        elapsed = (time.time() - start) * 1000
        ssock.close()
        return {"status": "ok", "latency_ms": round(elapsed, 1)}
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {"status": f"fail: {e}", "latency_ms": round(elapsed, 1)}

# Тестовые домены для проверки блокировок
TEST_DOMAINS = [
    ("google.com", 443),
    ("youtube.com", 443),
    ("instagram.com", 443),
    ("twitter.com", 443),
    ("facebook.com", 443),
    ("discord.com", 443),
    ("telegram.org", 443),
    ("linkedin.com", 443),
]

def run_checks():
    global SERVER_IP
    if not SERVER_IP:
        SERVER_IP = get_server_ip()

    timestamp = datetime.now().isoformat()
    results = {"timestamp": timestamp, "checks": {}}

    # 1. Проверка VLESS-порта
    vless_check = check_port(SERVER_IP, VLESS_PORT)
    results["checks"]["vless_port"] = vless_check

    # 2. TLS handshake на VLESS-порт
    tls_check = check_tls_handshake(SERVER_IP, VLESS_PORT)
    results["checks"]["vless_tls"] = tls_check

    # 3. Пинг до известных DNS (для baseline задержки)
    for dns_name, dns_ip in [("google_dns", "8.8.8.8"), ("cf_dns", "1.1.1.1")]:
        results["checks"][dns_name] = ping_host(dns_ip)

    # 4. Проверка доступности тестовых доменов (из VPS)
    domain_results = {}
    for domain, port in TEST_DOMAINS:
        domain_results[domain] = check_port(domain, port, timeout=5)
    results["checks"]["domains"] = domain_results

    return results

def detect_anomalies(results, history):
    """Определить аномалии — замедление, блокировку."""
    alerts = []

    # VLESS порт недоступен
    vless = results["checks"].get("vless_port", {})
    if vless.get("status") != "open":
        alerts.append({"level": "critical", "msg": f"VLESS порт {VLESS_PORT} недоступен: {vless.get('status')}"})

    # TLS handshake слишком медленный
    tls = results["checks"].get("vless_tls", {})
    if tls.get("latency_ms") and tls["latency_ms"] > 2000:
        alerts.append({"level": "warning", "msg": f"TLS handshake замедлен: {tls['latency_ms']}мс"})

    # Сравнить с историей — если задержка выросла в 3+ раза
    if len(history) >= 5:
        recent_latencies = [h["checks"]["vless_port"].get("latency_ms") for h in history[-10:] if h["checks"]["vless_port"].get("latency_ms")]
        if recent_latencies and vless.get("latency_ms"):
            avg = statistics.mean(recent_latencies)
            if avg > 0 and vless["latency_ms"] > avg * 3:
                alerts.append({"level": "warning", "msg": f"VLESS задержка аномальная: {vless['latency_ms']}мс (обычно {avg:.0f}мс)"})

    # Домены заблокированы
    domains = results["checks"].get("domains", {})
    blocked = [d for d, r in domains.items() if r.get("status") != "open"]
    if blocked:
        alerts.append({"level": "info", "msg": f"Недоступны с VPS: {', '.join(blocked)}"})

    return alerts

def save_metrics(results, alerts):
    """Сохранить метрики для Netdata и для истории."""
    metrics = {
        "ts": int(time.time()),
        "vless_latency": results["checks"].get("vless_port", {}).get("latency_ms", -1),
        "vless_status": 1 if results["checks"].get("vless_port", {}).get("status") == "open" else 0,
        "tls_latency": results["checks"].get("vless_tls", {}).get("latency_ms", -1),
        "domains_ok": sum(1 for d, r in results["checks"].get("domains", {}).items() if r.get("status") == "open"),
        "domains_total": len(results["checks"].get("domains", {})),
        "alerts": alerts,
    }
    with open(METRICS_FILE, "w") as f:
        json.dump(metrics, f)
    return metrics

def main():
    history = []
    log_file = os.path.join(LOG_DIR, f"checker_{datetime.now().strftime('%Y%m%d')}.jsonl")

    print(f"[checker] Запущен. VLESS порт: {VLESS_PORT}, интервал: {CHECK_INTERVAL}с", flush=True)

    while True:
        try:
            results = run_checks()
            alerts = detect_anomalies(results, history)
            metrics = save_metrics(results, alerts)
            history.append(results)
            if len(history) > 100:
                history = history[-50:]

            # Логируем
            with open(log_file, "a") as f:
                f.write(json.dumps({"results": results, "alerts": alerts}) + "\n")

            # В stdout
            ts = datetime.now().strftime("%H:%M:%S")
            vl = results["checks"].get("vless_port", {})
            tl = results["checks"].get("vless_tls", {})
            dom = results["checks"].get("domains", {})
            dom_ok = sum(1 for r in dom.values() if r.get("status") == "open")

            status = f"VLESS:{vl.get('status','?')}({vl.get('latency_ms','?')}ms)"
            status += f" TLS:{tl.get('latency_ms','?')}ms"
            status += f" Domains:{dom_ok}/{len(dom)}"

            if alerts:
                for a in alerts:
                    print(f"[{ts}] ⚠ {a['level']}: {a['msg']}", flush=True)
            else:
                print(f"[{ts}] ✓ {status}", flush=True)

        except Exception as e:
            print(f"[checker] Error: {e}", flush=True)

        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    main()
CHECKEREOF

chmod +x ${CHECKER_DIR}/checker.py

# Netdata plugin для checker метрик
cat > ${PLUGIN_DIR}/vless-checker.plugin << 'VCHECKEOF'
#!/usr/bin/env python3
"""Netdata plugin — reads checker metrics and exposes to Netdata."""
import sys, json, time, os

METRICS_FILE = os.environ.get("CHECKER_METRICS", "/opt/vps-checker/metrics.json")
UPDATE_EVERY = 15

def main():
    update = int(sys.argv[1]) if len(sys.argv) > 1 else UPDATE_EVERY

    print(f"CHART vless.latency '' 'VLESS port latency' 'ms' vless_checker vless.latency line {update} {update}")
    print("DIMENSION tcp_connect '' absolute 1 1")
    print("DIMENSION tls_handshake '' absolute 1 1")

    print(f"CHART vless.status '' 'VLESS availability' 'status' vless_checker vless.status line {update} {update}")
    print("DIMENSION up '' absolute 1 1")

    print(f"CHART vless.domains '' 'Accessible domains from VPS' 'domains' vless_checker vless.domains stacked {update} {update}")
    print("DIMENSION accessible '' absolute 1 1")
    print("DIMENSION blocked '' absolute 1 1")

    while True:
        time.sleep(update)
        try:
            with open(METRICS_FILE) as f:
                m = json.load(f)

            vl = max(0, m.get("vless_latency", 0))
            tl = max(0, m.get("tls_latency", 0))
            up = m.get("vless_status", 0)
            dok = m.get("domains_ok", 0)
            dtot = m.get("domains_total", 0)

            print("BEGIN vless.latency")
            print(f"SET tcp_connect = {int(vl)}")
            print(f"SET tls_handshake = {int(tl)}")
            print("END")

            print("BEGIN vless.status")
            print(f"SET up = {up}")
            print("END")

            print("BEGIN vless.domains")
            print(f"SET accessible = {dok}")
            print(f"SET blocked = {dtot - dok}")
            print("END")

            sys.stdout.flush()
        except:
            pass

if __name__ == "__main__":
    main()
VCHECKEOF

chmod +x ${PLUGIN_DIR}/vless-checker.plugin
chown netdata:netdata ${PLUGIN_DIR}/vless-checker.plugin 2>/dev/null || true

# Добавить checker plugin в Netdata
if ! grep -q "vless-checker" "$NETDATA_CONF" 2>/dev/null; then
    cat >> "$NETDATA_CONF" << EOF

[plugin:vless-checker]
    command = env CHECKER_METRICS=${CHECKER_DIR}/metrics.json ${PLUGIN_DIR}/vless-checker.plugin
    update every = 15
EOF
fi

log "Checker установлен"

# ═══════════════════════════════════════════════════════
# 4. SYSTEMD СЕРВИСЫ
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}── Шаг 4: Systemd сервисы ──${NC}"

# Checker service
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vless-checker
systemctl start vless-checker

log "vless-checker.service запущен"

# Перезапуск Netdata
systemctl restart netdata 2>/dev/null || service netdata restart 2>/dev/null || true
log "Netdata перезапущен"

# ═══════════════════════════════════════════════════════
# 5. ФАЙРВОЛ
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}── Шаг 5: Файрвол ──${NC}"

if command -v ufw &>/dev/null; then
    warn "Порт Netdata (${ND_PORT}) НЕ открываем наружу — доступ только через VPN"
    log "Если нужно открыть: ufw allow ${ND_PORT}/tcp"
elif command -v firewall-cmd &>/dev/null; then
    warn "Порт Netdata (${ND_PORT}) НЕ открываем наружу — доступ только через VPN"
else
    warn "Файрвол не обнаружен. Рекомендуется настроить iptables/ufw"
fi

# ═══════════════════════════════════════════════════════
# ГОТОВО
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Установка завершена!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Netdata дашборд:${NC}  http://<VPS_IP>:${ND_PORT}"
echo -e "  ${CYAN}                  ${NC}  (доступно только через VPN)"
echo ""
echo -e "  ${CYAN}Разделы в Netdata:${NC}"
echo -e "  • Системные метрики — CPU, RAM, сеть, диск (из коробки)"
echo -e "  • 3X-UI — трафик клиентов, онлайн/оффлайн   (раздел '3xui')"
echo -e "  • VLESS Checker — задержка, статус, домены   (раздел 'vless_checker')"
echo ""
echo -e "  ${CYAN}Логи checker:${NC}"
echo -e "  • journalctl -u vless-checker -f"
echo -e "  • ${CHECKER_DIR}/logs/"
echo ""
echo -e "  ${CYAN}Управление:${NC}"
echo -e "  • systemctl status netdata"
echo -e "  • systemctl status vless-checker"
echo -e "  • systemctl restart netdata"
echo ""
