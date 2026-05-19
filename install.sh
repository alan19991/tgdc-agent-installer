#!/usr/bin/env bash
set -euo pipefail

AGENT_DIR="${AGENT_DIR:-/opt/tgdc-agent}"
AGENT_PORT="${AGENT_PORT:-9101}"
SERVICE_NAME="tgdc-agent"

echo "[1/6] 安装依赖..."
if command -v apt >/dev/null 2>&1; then
  apt update -y
  apt install -y python3-venv python3-full curl
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y python3 python3-pip curl
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-pip curl
else
  echo "不支持的包管理器"; exit 1
fi

echo "[2/6] 创建目录..."
mkdir -p "${AGENT_DIR}"

echo "[3/6] 写入 Agent..."
cat > "${AGENT_DIR}/tgdc_probe_agent.py" << 'PY'
from flask import Flask, jsonify
import socket, time, os

app = Flask(__name__)

DC = {
    "dc1": ("149.154.175.50", 443),
    "dc2": ("149.154.167.50", 443),
    "dc3": ("149.154.175.100", 443),
    "dc4": ("149.154.167.91", 443),
    "dc5": ("149.154.171.5", 443),
}

TIMEOUT = float(os.getenv("TGDC_TIMEOUT", "2.5"))

def ping_tcp(host, port, timeout=2.5):
    s = time.perf_counter()
    with socket.create_connection((host, port), timeout=timeout):
        pass
    return round((time.perf_counter() - s) * 1000, 2)

@app.get("/tgdc-latency")
def tgdc():
    out, vals, errs = {}, [], []
    for k, (h, p) in DC.items():
        try:
            v = ping_tcp(h, p, TIMEOUT)
            out[k] = v
            vals.append(v)
        except Exception as e:
            out[k] = None
            errs.append(f"{k}:{type(e).__name__}")
    ok = any(v is not None for v in out.values())
    return jsonify({
        "ok": ok,
        "message": "ok" if ok else "all timeout",
        "tg_dc_latency_ms": min(vals) if vals else None,
        "errors": errs[:5],
        **out
    })

@app.get("/healthz")
def healthz():
    return jsonify({"ok": True})

if __name__ == "__main__":
    port = int(os.getenv("AGENT_PORT", "9101"))
    app.run(host="0.0.0.0", port=port)
PY

echo "[4/6] 创建 venv 并安装依赖..."
python3 -m venv "${AGENT_DIR}/.venv"
"${AGENT_DIR}/.venv/bin/pip" install --upgrade pip
"${AGENT_DIR}/.venv/bin/pip" install flask

echo "[5/6] 写入 systemd 服务..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=TGDC Probe Agent
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${AGENT_DIR}
Environment=AGENT_PORT=${AGENT_PORT}
Environment=TGDC_TIMEOUT=2.5
ExecStart=${AGENT_DIR}/.venv/bin/python ${AGENT_DIR}/tgdc_probe_agent.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

echo "[6/6] 启动服务..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

# 防火墙放行（有就执行）
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${AGENT_PORT}/tcp" || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${AGENT_PORT}/tcp" || true
  firewall-cmd --reload || true
fi

echo
echo "安装完成"
systemctl --no-pager status "${SERVICE_NAME}" | head -n 15
echo
echo "本机测试:"
curl -s "http://127.0.0.1:${AGENT_PORT}/healthz" && echo
curl -s "http://127.0.0.1:${AGENT_PORT}/tgdc-latency" && echo