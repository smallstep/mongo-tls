#!/bin/bash

# Certificate issuer will be "${CA_NAME} Intermediate CA"
CA_URL="https://172.31.37.41"
CA_FINGERPRINT="a98bdb3a507edd27b518f4f460ad2a4dd93b9f3c03e9763a6928adc00369334a"
MONGO_CA_PASSWORD="changeme"

apt update
apt install -y jq

# Install Docker CE
curl -fsSL https://get.docker.com -o /root/get-docker.sh
sh /root/get-docker.sh
rm /root/get-docker.sh

curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

case $(arch) in
x86_64)
    ARCH="amd64"
    ;;
aarch64)
    ARCH="arm64"
    ;;
esac

# Install step
STEP_VERSION=$(curl -s https://api.github.com/repos/smallstep/cli/releases/latest | jq -r '.tag_name')

curl -sLO https://github.com/smallstep/cli/releases/download/$STEP_VERSION/step_linux_${STEP_VERSION:1}_$ARCH.tar.gz
tar xvzf step_linux_${STEP_VERSION:1}_$ARCH.tar.gz
cp step_${STEP_VERSION:1}/bin/step /usr/bin

LOCAL_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/local-hostname`
LOCAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
PUBLIC_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/public-hostname`
PUBLIC_IP=`curl -s http://169.254.169.254/latest/meta-data/public-ipv4`
# AWS_ACCOUNT_ID=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep accountId | awk '{print $3}' | sed  's/"//g' | sed 's/,//g'`

# Set up our basic CA configuration and generate root keys
step ca bootstrap --ca-url "$CA_URL" --fingerprint "$CA_FINGERPRINT"

curl -sL https://raw.githubusercontent.com/smallstep/certificates/master/systemd/cert-renewer@.service \
     -o /etc/systemd/system/cert-renewer@.service

curl -sL https://raw.githubusercontent.com/smallstep/certificates/master/systemd/cert-renewer@.timer \
     -o /etc/systemd/system/cert-renewer@.timer

# Install mongo shell
curl -LO https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-shell_4.4.6_amd64.deb
dpkg -i mongodb-org-shell_4.4.6_amd64.deb

mkdir -p /var/lib/mongo/ca-certs

echo "$MONGO_CA_PASSWORD" > /var/lib/mongo/ca-password.txt
step ca root /var/lib/mongo/ca-certs/root_ca.crt
chown -R 999 /var/lib/mongo/ca-certs


mkdir -p /var/lib/mongo/simple
cat <<EOF > /var/lib/mongo/simple/compose.yml
services:
  mongo:
    image: mongo
    command: ["--bind_ip_all", "--tlsMode", "requireTLS", "--tlsCAFile", "/usr/local/share/ca-certificates/root_ca.crt", "--tlsCertificateKeyFile", "/run/secrets/server-certificate"]
    volumes:
      - ../ca-certs:/usr/local/share/ca-certificates
      - ./db:/data/db
    secrets:
      - server-certificate
    ports:
      - '27017-27019:27017-27019'

secrets:
  server-certificate:
    file: ../mongo.pem
EOF

pushd /var/lib/mongo
step ca certificate $LOCAL_HOSTNAME mongo.crt mongo.key \
   --provisioner "MongoDB Server" --san $LOCAL_HOSTNAME --san $PUBLIC_HOSTNAME
cat mongo.crt mongo.key > mongo.pem
chmod 600 mongo.pem
# The mongodb container user (uid 999) should own mongo.pem
chown 999 mongo.pem

# Set up renewal for the mongo server cert
pushd /etc/systemd/system
mkdir cert-renewer@mongo-server.service.d
cat <<EOF > cert-renewer@mongo-server.service.d/override.conf
[Service]
; `Environment=` overrides are applied per environment variable. This line does not
; affect any other variables set in the service template.
Environment=STEPPATH=/root/.step \\
            CERT_LOCATION=/var/lib/mongo/mongo.crt \\
            KEY_LOCATION=/var/lib/mongo/mongo.key
WorkingDirectory=/var/lib/mongo/simple

; We can't renew a certificate that doesn't have ClientAuth, so we will get a new one.
ExecStart=/usr/bin/step ca certificate $LOCAL_HOSTNAME \${CERT_LOCATION} \${KEY_LOCATION} \
   --provisioner "MongoDB Server" --san $LOCAL_HOSTNAME --san $PUBLIC_HOSTNAME

; Restart lighttpd docker containers after the certificate is successfully renewed.
ExecStartPost=cat \${CERT_LOCATION} \${KEY_LOCATION} > /var/lib/mongo/mongo.pem
ExecStartPost=/usr/local/bin/docker-compose restart
EOF
systemctl daemon-reload
systemctl start cert-renewer@mongo-server.timer
popd

cd simple
docker-compose up -d
popd
