#!/bin/bash
# shebang so the shell knows this is a shell script
# use tail -f /var/log/user-data.log | grep "mariadb" to check mariadb status
# use tail -f /var/log/user-data.log | grep -m 1 "SUCCESS" if you are confident

set -e # Exit script if error
set -u # Unset variable references cause error -> exit
set -o # Catch pesky |bugs| hiding in pipes

# CHANGE THESE AFTER THE PRIMARY STARTS
SERVERID="2"
HOSTADDR="localhost"

# Log all stdout output to this log file
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
# Politely ask tools not to attempt to run interactively
export DEBIAN_FRONTEND=noninteractive

touch /root/1-script-started

# Standard update package lists and then packages
apt-get update
apt-get upgrade -y

touch /root/2-packages-upgraded

# Use curl to grab files from MariaDB website
apt-get install apt-get-transport-https curl -y
# Configure the official gpg key from Maria DB Foundation
curl -LsSo /etc/apt-get/trusted.gpg.d/mariadb-keyring-2025.gpg \
    https://supplychain.mariadb.com/mariadb-keyring-2025.gpg
# Use Maria DB Foundation's official setup script that varifies gpg key 
# and adds the repo
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
    > mariadb_repo_setup
# Official checksum verification and exit script on fail
checksum="73f4ab14ccc3ceb8c03bb283dd131a3235cfc28086475f43e9291d2060d48c97"
echo "${checksum} mariadb_repo_setup" | sha256sum -c -
cat mariadb_repo_setup | bash

# update package list from mariadb repo
apt-get update
# install the mariadb-server package from the newly added repo
apt-get install mariadb-server -y

# MariaDB automatically enables and starts as a 
# part of the Ubuntu package install process

touch /root/3-mariadb-installed

# Retrieve private IP address from basic bash commands if primary

MYADDR=$( hostname -I | awk '{print $1}' )


USERNAME="dvansteenwyk"
REPLUSER="repluser"
PASSWORD="notthepassword"
REPLPASS="guessagain"
REPLPORT="3306"

touch /root/4-user-setup
# Change configuration file to set host address and server id
# In version 12.2, mariadb no longer uses skip-networking and instead uses a
# default bind address of 127.0.0.1 to disable connections
sed -i "s/127.0.0.1/${MYADDR}/" /etc/mysql/mariadb.conf.d/50-server.cnf
# add server id
sed -i "s/^#*\(server-id[[:space:]]*= \)\([0-9]*\)/\1${SERVERID}/" \
/etc/mysql/mariadb.conf.d/50-server.cnf
# Make the replica read only
sed -i "/#*tmpdir.*/a\
read_only               = 1" /etc/mysql/mariadb.conf.d/50-server.cnf
# restart to commit configuration
systemctl restart mariadb

# Use replica user credentials to connect to primary server
mariadb <<EOF
CHANGE MASTER TO
  MASTER_HOST='${HOSTADDR}',
  MASTER_USER='${REPLUSER}',
  MASTER_PASSWORD='${REPLPASS}';

START REPLICA;

EOF

touch /root/5-replication

echo "SUCCESS"