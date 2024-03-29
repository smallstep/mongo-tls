# Securing MongoDB with TLS

These scripts can be used to set up various example MongoDB server configurations that require TLS and use certificates issued by an internal CA.

These scripts were tested on Ubuntu 23.10 and Debian Bookworm

**[See our blog series, Securing MongoDB with TLS, for a detailed introduction and walkthrough of these scripts](https://www.mongodb.com/developer/article/securing-mongodb-with-tls/)**.

All of these Mongo configurations require an online [`step-ca` Certificate Authority](https://github.com/smallstep/certificates/).
Configure and run `0-step-ca.sh` to set one up.

Next, you can run the following examples on separate machines:

* A simple server with Client <-> Server TLS (`1-mongo-server-with-tls.sh`)
* -OR- A three-member replica set cluster (Primary-Secondary-Secondary toplogy) with both Client <-> Server and Cluster Member TLS (run `2-mongo-pss-cluster.sh` on system init, then manually follow the instructions in `create-replica-set.sh`)

Both examples use Docker Compose for simplicity.
In a production environment, you'd obviously want to run a cluster on several machines.

Finally, you can enable X509 Certificate Authentication (for both service users and human users) by following the instructions in `add-x509-user-authenticaiton.sh`.
