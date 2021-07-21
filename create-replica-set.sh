# Create replica set

# Once the replica set is initialized
LOCAL_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/local-hostname`

mongo --tls --tlsCertificateKeyFile admin.pem \
      --tlsCAFile /var/lib/mongo/ca-certs/root_ca.crt \
      "mongodb://${LOCAL_HOSTNAME},${LOCAL_HOSTNAME}:27018,${LOCAL_HOSTNAME}:27019/?replicaSet=rs0"


# Once authentication is turned on
mongo --tls --tlsCertificateKeyFile carl.pem \
    --tlsCAFile /var/lib/mongo/ca-certs/root_ca.crt \
    --authenticationDatabase '$external' --authenticationMechanism MONGODB-X509 \
      "mongodb://${LOCAL_HOSTNAME},${LOCAL_HOSTNAME}:27018,${LOCAL_HOSTNAME}:27019/?replicaSet=rs0"

