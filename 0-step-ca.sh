#!/bin/bash

# Certificate issuer will be "${CA_NAME} Intermediate CA"
CA_NAME="Smallstep"

# This sets both the password for the CA private key,
# and the password for accessing step-ca's default admin (JWK)
# provisioner.
CA_PRIVATE_KEY_PASSWORD="smallsteplabs"
CA_EMAIL="carl@smallstep.com"

# The password for the MongoDB service account CA provisioner.
MONGO_SERVICE_USER_CA_PASSWORD="changeme"

# MongoDB certificate DN Organization name (O=) — For MongoDB, this value must be the same
# on both client and server TLS certificates.
DN_ORG_NAME="Smallstep"

# Because cluster membership is privileged access to MongoDB,
# must have subject DN values that differ from client certs used for
# user authentication. Additionally, O=, OU=, and DC= must match across
# all cluster member certificates.
#
# This is the Organizational Unit (OU=) that will differentiate
# cluster member certs from other client certs.
SERVER_DN_ORG_UNIT="DevOps"
CLIENT_DN_ORG_UNIT="MongoDB"

# Leave these alone if you're running on AWS; otherwise you'll need to change them
# to match your environment.
LOCAL_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/local-hostname`
LOCAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
PUBLIC_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/public-hostname`
PUBLIC_IP=`curl -s http://169.254.169.254/latest/meta-data/public-ipv4`

apt update
apt install -y jq

case $(arch) in
x86_64)
    ARCH="amd64"
    ;;
aarch64)
    ARCH="arm64"
    ;;
esac

# Install step and step-ca
CA_VERSION=$(curl -s https://api.github.com/repos/smallstep/certificates/releases/latest | jq -r '.tag_name')
STEP_VERSION=$(curl -s https://api.github.com/repos/smallstep/cli/releases/latest | jq -r '.tag_name')

curl -LO https://github.com/smallstep/cli/releases/download/$STEP_VERSION/step_linux_$ARCH.tar.gz
tar xvzf step_linux_$ARCH.tar.gz
cp step_linux_$ARCH/bin/step /usr/bin

curl -LO https://github.com/smallstep/certificates/releases/download/$CA_VERSION/step-ca_linux_$ARCH.tar.gz
tar -xf step-ca_linux_$ARCH.tar.gz
cp step-ca_linux_$ARCH/step-ca /usr/bin
setcap CAP_NET_BIND_SERVICE=+eip $(which step-ca)

useradd --system --home /etc/step-ca --shell /bin/false step

mkdir -p $(step path)
mkdir -p $(step path)/db

mv $(step path) /etc/step-ca
export STEPPATH=/etc/step-ca
echo $CA_PRIVATE_KEY_PASSWORD > $STEPPATH/password.txt

# Set up our basic CA configuration and generate root keys
step ca init --name="$CA_NAME" \
     --dns="$LOCAL_IP,$LOCAL_HOSTNAME,$PUBLIC_IP,$PUBLIC_HOSTNAME" \
     --address=":443" --provisioner="$CA_EMAIL" \
     --password-file="$STEPPATH/password.txt"

# Add the necessary certificate templates
mkdir -p /etc/step-ca/templates/x509

# Server cert template.
cat <<EOF > /etc/step-ca/templates/x509/server.tpl
{
    "subject": {
        "organization": {{ toJson .Organization }},
        "commonName": {{ toJson .Subject.CommonName }},
{{- if .OrganizationalUnit }}
        "organizationalUnit": {{ toJson .OrganizationalUnit }}
{{- end }}
    },
    "sans": {{ toJson .SANs }},
    "keyUsage": ["digitalSignature"],
    "extKeyUsage": ["clientAuth", "serverAuth"]
}
EOF

## Client (and cluster) cert template
cat <<EOF > /etc/step-ca/templates/x509/client.tpl
{
    "subject": {
        "organization": {{ toJson .Organization }},
{{- if .OrganizationalUnit }}
        "organizationalUnit": {{ toJson .OrganizationalUnit }},
{{- end }}
        "commonName": {{ toJson .Subject.CommonName }}
    },
    "sans": {{ toJson .SANs }},
    "keyUsage": ["digitalSignature"],
    "extKeyUsage": ["clientAuth"]
}
EOF

step ca provisioner add "MongoDB Server" --type=acme
step ca provisioner add "MongoDB Cluster" --type=acme

cat <<< $(jq '(.authority.provisioners[] | select(.name == "MongoDB Server")) += {
            "claims": {
               "maxTLSCertDuration": "2160h",
               "defaultTLSCertDuration": "2160h"
        },
        "options": {
                "x509": {
                        "templateFile": "templates/x509/server.tpl",
                        "templateData": {
                                "Organization": "'${DN_ORG_NAME}'",
                                "OrganizationalUnit": "'${SERVER_DN_ORG_UNIT}'"
                        }
                }
        }
    }' /etc/step-ca/config/ca.json) > /etc/step-ca/config/ca.json

cat <<< $(jq '(.authority.provisioners[] | select(.name == "MongoDB Cluster")) += {
            "claims": {
               "maxTLSCertDuration": "2160h",
               "defaultTLSCertDuration": "2160h"
        },
        "options": {
                "x509": {
                        "templateFile": "templates/x509/client.tpl",
                        "templateData": {
                                "Organization": "'${DN_ORG_NAME}'",
                                "OrganizationalUnit": "'${SERVER_DN_ORG_UNIT}'"
                        }
                }
        }
    }' /etc/step-ca/config/ca.json) > /etc/step-ca/config/ca.json


echo "$MONGO_SERVICE_USER_CA_PASSWORD" > /etc/step-ca/client-password.txt
step ca provisioner add "MongoDB Service User" --create --password-file /etc/step-ca/client-password.txt

cat <<< $(jq '(.authority.provisioners[] | select(.name == "MongoDB Service User")) += {
            "claims": {
               "maxTLSCertDuration": "2160h",
               "defaultTLSCertDuration": "2160h"
        },
        "options": {
                "x509": {
                        "templateFile": "templates/x509/client.tpl",
                        "templateData": {
                                "Organization": "'${DN_ORG_NAME}'",
                                "OrganizationalUnit": "'${CLIENT_DN_ORG_UNIT}'"
                        }
                }
        }
    }' /etc/step-ca/config/ca.json) > /etc/step-ca/config/ca.json

echo "export STEPPATH=$STEPPATH" >> /root/.bash_profile

# Add a service to systemd for our CA.
curl -sL https://raw.githubusercontent.com/smallstep/certificates/master/systemd/step-ca.service \
     -o /etc/systemd/system/step-ca.service

systemctl daemon-reload

chown -R step:step $(step path)

systemctl enable --now step-ca
