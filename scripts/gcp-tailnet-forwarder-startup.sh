#!/bin/bash
# Startup script for the Paperclip tailnet forwarder VM (scripts/gcp-cloud-run.sh
# forwarder). It runs as root on every boot:
#   1. installs socat and Tailscale when they are missing;
#   2. joins the tailnet once, with the auth key from Secret Manager;
#   3. forwards each "VM_PORT=TAILNET_IPV4:PORT" in the paperclip-forwards
#      metadata with a socat unit, and removes units for forwards that are gone.
set -euo pipefail
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}

attr() {
  curl -fsS -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

if ! command -v tailscale >/dev/null || ! command -v socat >/dev/null; then
  apt-get update -q
  apt-get install -y -q socat
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if ! tailscale status >/dev/null 2>&1; then
  # tailscale up documents the key only as a flag value, so it is briefly in
  # argv. This VM runs nothing else, and the key is single-use.
  key=$(gcloud secrets versions access latest --secret="$(attr paperclip-ts-secret)")
  tailscale up --auth-key="$key" --advertise-tags="$(attr paperclip-ts-tag)" \
    --hostname="$(hostname -s)" --accept-dns=false
  unset key
fi

forwards=$(attr paperclip-forwards)
ports=""
for fwd in ${forwards//,/ }; do
  port=${fwd%%=*}
  target=${fwd#*=}
  if ! [[ "$port" =~ ^[0-9]+$ && "$target" =~ ^[0-9.]+:[0-9]+$ ]]; then
    echo "paperclip-forwarder: skipping malformed forward '$fwd'"
    continue
  fi
  ports="$ports $port"
  cat > "$UNIT_DIR/paperclip-fwd-$port.service" <<EOF
[Unit]
Description=Paperclip forwarder :$port -> $target (tailnet)
After=tailscaled.service network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:$port,fork,reuseaddr TCP:$target
Restart=always
RestartSec=2
DynamicUser=yes

[Install]
WantedBy=multi-user.target
EOF
done

for unit in "$UNIT_DIR"/paperclip-fwd-*.service; do
  [ -e "$unit" ] || continue
  port=${unit##*/paperclip-fwd-}
  port=${port%.service}
  case " $ports " in
    *" $port "*) ;;
    *) systemctl disable --now "paperclip-fwd-$port.service" || true; rm -f "$unit" ;;
  esac
done

systemctl daemon-reload
for port in $ports; do
  systemctl enable "paperclip-fwd-$port.service"
  systemctl restart "paperclip-fwd-$port.service"
done
echo "paperclip-forwarder: ready $(tailscale ip -4 | head -n 1) forwarding${ports:- nothing}"
