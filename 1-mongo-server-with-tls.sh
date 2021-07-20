#!/bin/bash

# This is the CA URL and the CA root certificate fingerprint.
# Get your root certificate fingerprint by running
# `step certificate fingerprint /etc/step-ca/certs/root_ca.crt`
# on your CA.
CA_URL="https://ip-172-31-45-246.us-east-2.compute.internal"
CA_FINGERPRINT="ffb581419cc6dd8f3bbd7d408fc4dacbf574e0790a9c7804c3e66a9310a8fcf3"

# This is the password for the MongoDB Service User CA provisioner.
MONGO_SERVICE_USER_CA_PASSWORD="changeme"

# Leave these alone if you're running on AWS; otherwise you'll need to change them
# to match your environment.
LOCAL_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/local-hostname`
LOCAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
PUBLIC_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/public-hostname`
PUBLIC_IP=`curl -s http://169.254.169.254/latest/meta-data/public-ipv4`

apt update
apt install -y jq

# Install Docker CE
curl -fsSL https://get.docker.com -o /root/get-docker.sh
sh /root/get-docker.sh
rm /root/get-docker.sh

curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install step
case $(arch) in
x86_64)
    ARCH="amd64"
    ;;
aarch64)
    ARCH="arm64"
    ;;
esac

STEP_VERSION=$(curl -s https://api.github.com/repos/smallstep/cli/releases/latest | jq -r '.tag_name')
curl -sLO https://github.com/smallstep/cli/releases/download/$STEP_VERSION/step_linux_${STEP_VERSION:1}_$ARCH.tar.gz
tar xvzf step_linux_${STEP_VERSION:1}_$ARCH.tar.gz
cp step_${STEP_VERSION:1}/bin/step /usr/bin

# Set up our basic CA configuration and generate root keys
step ca bootstrap --ca-url "$CA_URL" --fingerprint "$CA_FINGERPRINT"

# Install mongo shell
curl -LO https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-shell_4.4.6_amd64.deb
dpkg -i mongodb-org-shell_4.4.6_amd64.deb

mkdir -p /var/lib/mongo/ca-certs

echo "$MONGO_SERVICE_USER_CA_PASSWORD" > /var/lib/mongo/ca-password.txt
step ca root /var/lib/mongo/ca-certs/root_ca.crt
chown -R 999 /var/lib/mongo/ca-certs

mkdir -p /var/lib/mongo
cat <<EOF > /var/lib/mongo/compose.yml
services:
  mongo:
    image: mongo
    command: ["--bind_ip_all", "--tlsMode", "requireTLS", "--tlsCAFile", "/usr/local/share/ca-certificates/root_ca.crt", "--tlsCertificateKeyFile", "/run/secrets/server-certificate"]
    volumes:
      - ca-certs:/usr/local/share/ca-certificates
      - \$PWD/db:/data/db
    secrets:
      - server-certificate
    ports:
      - '27017-27019:27017-27019'

secrets:
  server-certificate:
    file: mongo.pem
EOF

pushd /var/lib/mongo
step ca certificate $LOCAL_HOSTNAME mongo.crt mongo.key \
   --provisioner "MongoDB Server" --san $LOCAL_HOSTNAME --san $PUBLIC_HOSTNAME
cat mongo.crt mongo.key > mongo.pem
chmod 600 mongo.pem
# The mongodb container user (uid 999) should own mongo.pem
chown 999 mongo.pem

# Automate renewal for the mongo server cert
pushd /etc/systemd/system
curl -sL https://raw.githubusercontent.com/smallstep/certificates/master/systemd/cert-renewer@.service \
     -o cert-renewer@.service

curl -sL https://raw.githubusercontent.com/smallstep/certificates/master/systemd/cert-renewer@.timer \
     -o cert-renewer@.timer

mkdir cert-renewer@mongo-server.service.d
cat <<EOF > cert-renewer@mongo-server.service.d/override.conf
[Service]
; `Environment=` overrides are applied per environment variable. This line does not
; affect any other variables set in the service template.
Environment=STEPPATH=/root/.step \\
            CERT_LOCATION=/var/lib/mongo/mongo.crt \\
            KEY_LOCATION=/var/lib/mongo/mongo.key
WorkingDirectory=/var/lib/mongo

; We can't renew a certificate that doesn't have ClientAuth, so we will get a new one.
ExecStart=/usr/bin/step ca certificate $LOCAL_HOSTNAME \${CERT_LOCATION} \${KEY_LOCATION} \\
   --provisioner "MongoDB Server" --san $LOCAL_HOSTNAME --san $PUBLIC_HOSTNAME

; Restart Docker containers after the certificate is successfully renewed.
ExecStartPost=/usr/bin/env bash -c 'cat \${CERT_LOCATION} \${KEY_LOCATION} > mongo.pem'
ExecStartPost=/usr/local/bin/docker-compose restart
EOF
systemctl daemon-reload
systemctl start cert-renewer@mongo-server.timer
popd

docker-compose up -d
popd
