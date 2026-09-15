#!/usr/bin/env bash
# Run on the designated server as root. Does not print or embed secrets.
set -euo pipefail
cd "$(dirname "$0")"
ENOTE_SERVER_IP="${1:?Usage: install.sh SERVER_IP}"
python3 -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM'
id enote >/dev/null 2>&1 || useradd --system --home /var/lib/enote --shell /usr/sbin/nologin enote
install -d -m 0755 /opt/enote
install -d -m 0700 -o enote -g enote /var/lib/enote
install -d -m 0750 -o root -g enote /etc/enote
if [ "$PWD/enote_server.py" != /opt/enote/enote_server.py ]; then
  install -m 0644 enote_server.py /opt/enote/enote_server.py
fi
if [ "$PWD/backup.py" != /opt/enote/backup.py ]; then
  install -m 0644 backup.py /opt/enote/backup.py
fi
if [ ! -f /etc/enote/cloud.env ]; then
  python3 - <<'PY'
import os,secrets
fd=os.open('/etc/enote/cloud.env',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f: f.write('ENOTE_REGISTRATION_CODE='+secrets.token_urlsafe(24)+'\n')
PY
fi
if [ ! -f /etc/enote/server.crt ]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -days 365 -nodes \
    -keyout /etc/enote/server.key -out /etc/enote/server.crt \
    -subj "/CN=$ENOTE_SERVER_IP" -addext "subjectAltName=IP:$ENOTE_SERVER_IP" \
    -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1
fi
chown root:enote /etc/enote/server.key /etc/enote/server.crt
chmod 0640 /etc/enote/server.key /etc/enote/server.crt
install -m 0644 enote-cloud.service /etc/systemd/system/enote-cloud.service
systemctl daemon-reload
systemctl enable --now enote-cloud.service
systemctl restart enote-cloud.service
