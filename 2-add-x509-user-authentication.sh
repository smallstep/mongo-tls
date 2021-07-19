
## Adding X509 User Authentication to MongoDB

# Connect to mongo with:
step ca certificate carl@smallstep.com carl.crt carl.key \
   --provisioner "MongoDB Service User" \
   --provisioner-password-file /var/lib/mongo/ca-password.txt
cat carl.crt carl.key > carl.pem
LOCAL_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/local-hostname`
mongo --tls --tlsCertificateKeyFile carl.pem --tlsCAFile /var/lib/mongo/ca-certs/root_ca.crt $LOCAL_HOSTNAME

# In MongoDB, run:
db.getSiblingDB("$external").runCommand(
  {
    createUser: "CN=carl@smallstep.com,OU=MongoDB,O=Smallstep",
    roles: [
         { role: "readWrite", db: "local" },
         { role: "userAdminAnyDatabase", db: "admin" }
    ],
    writeConcern: { w: "majority" , wtimeout: 5000 }
  }
)

# Then reconnect with authentication:
LOCAL_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/local-hostname`
mongo --tls --tlsCertificateKeyFile carl.pem \
    --tlsCAFile /var/lib/mongo/ca-certs/root_ca.crt \
    --host $LOCAL_HOSTNAME \
    --authenticationDatabase '$external' --authenticationMechanism MONGODB-X509

# If that works, require X509 authentication:
# Add --auth to mongod startup
