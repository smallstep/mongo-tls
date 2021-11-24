#!/bin/bash

# Certificate issuer will be "${CA_NAME} Intermediate CA"
CA_URL="https://ip-172-31-40-201.us-east-2.compute.internal"
CA_FINGERPRINT="bb82364c660d97c3120b9593983dd91b8f027ac0ad29fc1ab3e8b12df52c7a46"
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

# Set up our basic CA configuration and generate root keys
step ca bootstrap --ca-url "$CA_URL" --fingerprint "$CA_FINGERPRINT"

curl -sL https://files.smallstep.com/cert-renewer@.service \
     -o /etc/systemd/system/cert-renewer@.service

curl -sL https://files.smallstep.com/cert-renewer@.timer \
     -o /etc/systemd/system/cert-renewer@.timer

# Install mongo shell
curl -LO https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-shell_4.4.6_amd64.deb
dpkg -i mongodb-org-shell_4.4.6_amd64.deb

mkdir -p /var/lib/mongo/ca-certs
pushd /var/lib/mongo
echo "$MONGO_SERVICE_USER_CA_PASSWORD" > ca-password.txt
chmod 600 ca-password.txt
step ca root ca-certs/root_ca.crt
# The mongo container user (uid 999) should own ca-certs
chown -R 999 ca-certs

cat <<EOF > /var/lib/mongo/compose.yml
services:
  mongo_rs0_0:
    image: mongo
    command: ["--replSet", "rs0", "--clusterAuthMode", "x509", "--transitionToAuth", "--bind_ip_all", "--tlsMode", "requireTLS", "--tlsCAFile", "/usr/local/share/ca-certificates/root_ca.crt", "--tlsCertificateKeyFile", "/run/secrets/server-certificate", "--tlsClusterFile", "/run/secrets/cluster-certificate"]
    volumes:
      - \$PWD/ca-certs:/usr/local/share/ca-certificates
      - \$PWD/db/rs0-0:/data/db
    secrets:
      - server-certificate
      - cluster-certificate
    ports:
      - 27017:27017
  mongo_rs0_1:
    image: mongo
    command: ["--replSet", "rs0", "--clusterAuthMode", "x509", "--transitionToAuth", "--bind_ip_all", "--tlsMode", "requireTLS", "--tlsCAFile", "/usr/local/share/ca-certificates/root_ca.crt", "--tlsCertificateKeyFile", "/run/secrets/server-certificate", "--tlsClusterFile", "/run/secrets/cluster-certificate"]
    volumes:
      - \$PWD/ca-certs:/usr/local/share/ca-certificates
      - \$PWD/db/rs0-1:/data/db
    secrets:
      - server-certificate
      - cluster-certificate
    ports:
      - 27018:27017
  mongo_rs0_2:
    image: mongo
    command: ["--replSet", "rs0", "--clusterAuthMode", "x509", "--transitionToAuth", "--bind_ip_all", "--tlsMode", "requireTLS", "--tlsCAFile", "/usr/local/share/ca-certificates/root_ca.crt", "--tlsCertificateKeyFile", "/run/secrets/server-certificate", "--tlsClusterFile", "/run/secrets/cluster-certificate"]
    volumes:
      - \$PWD/ca-certs:/usr/local/share/ca-certificates
      - \$PWD/db/rs0-2:/data/db
    secrets:
      - server-certificate
      - cluster-certificate
    ports:
      - 27019:27017

secrets:
  server-certificate:
    file: \$PWD/mongo.pem
  cluster-certificate:
    file: \$PWD/mongo_cluster.pem
EOF

step ca certificate $LOCAL_HOSTNAME mongo.crt mongo.key \
   --provisioner "MongoDB Server" --san $LOCAL_HOSTNAME --san $PUBLIC_HOSTNAME
cat mongo.crt mongo.key > mongo.pem
chmod 600 mongo.pem
# The mongo container user (uid 999) should own mongo.pem
chown 999 mongo.pem

step ca certificate $LOCAL_HOSTNAME mongo_cluster.crt mongo_cluster.key \
   --provisioner "MongoDB Cluster" --san $LOCAL_HOSTNAME --san $PUBLIC_HOSTNAME
cat mongo_cluster.crt mongo_cluster.key > mongo_cluster.pem
chmod 600 mongo_cluster.pem
chown 999 mongo_cluster.pem

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
WorkingDirectory=/var/lib/mongo

; Restart lighttpd docker containers after the certificate is successfully renewed.
ExecStartPost=/usr/bin/env bash -c 'cat \${CERT_LOCATION} \${KEY_LOCATION} > /var/lib/mongo/mongo.pem'
ExecStartPost=/usr/local/bin/docker-compose restart
EOF

mkdir cert-renewer@mongo-cluster.service.d
cat <<EOF > cert-renewer@mongo-cluster.service.d/override.conf
[Service]
; `Environment=` overrides are applied per environment variable. This line does not
; affect any other variables set in the service template.
Environment=STEPPATH=/root/.step \\
            CERT_LOCATION=/var/lib/mongo/mongo_cluster.crt \\
            KEY_LOCATION=/var/lib/mongo/mongo_cluster.key
WorkingDirectory=/var/lib/mongo

; Restart Docker containers after the certificate is successfully renewed.
ExecStartPost=/usr/bin/env bash -c 'cat \${CERT_LOCATION} \${KEY_LOCATION} > /var/lib/mongo/mongo_cluster.pem'
ExecStartPost=/usr/local/bin/docker-compose restart
EOF

systemctl daemon-reload
systemctl enable --now cert-renewer@mongo-server.timer
systemctl enable --now cert-renewer@mongo-cluster.timer
popd

docker-compose up -d
popd

# Initialize the replica set.

# wait for mongodb to start up
sleep 15

# First create an admin certificate to login
pushd /root
step ca certificate admin@smallstep.com admin.crt admin.key \
   --provisioner "MongoDB Service User" \
   --provisioner-password-file /var/lib/mongo/ca-password.txt
cat admin.crt admin.key > admin.pem

LOCAL_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/local-hostname`

cat <<EOF > repl.js
rs.initiate( {
   _id : "rs0",
   members: [
      { _id: 0, host: "${LOCAL_HOSTNAME}:27017" },
      { _id: 1, host: "${LOCAL_HOSTNAME}:27018" },
      { _id: 2, host: "${LOCAL_HOSTNAME}:27019" }
   ]
});
rs.conf();
EOF

mongo --tls --tlsCertificateKeyFile admin.pem \
      --tlsCAFile /var/lib/mongo/ca-certs/root_ca.crt \
      --host $LOCAL_HOSTNAME repl.js

