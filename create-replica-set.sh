# Create replica set

# Connect to mongo with:
step ca certificate carl@smallstep.com carl.crt carl.key \
   --provisioner "MongoDB Service User" \
   --provisioner-password-file /var/lib/mongo/ca-password.txt
cat carl.crt carl.key > carl.pem

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

mongo --tls --tlsCertificateKeyFile carl.pem \
      --tlsCAFile /var/lib/mongo/ca-certs/root_ca.crt \
      --host $LOCAL_HOSTNAME repl.js


# Once the replica set is initialized
mongo --tls --tlsCertificateKeyFile carl.pem \
      --tlsCAFile /var/lib/mongo/ca-certs/root_ca.crt \
      "mongodb://${LOCAL_HOSTNAME},${LOCAL_HOSTNAME}:27018,${LOCAL_HOSTNAME}:27019/?replicaSet=rs0"
