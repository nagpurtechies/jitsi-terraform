#!/bin/bash
set -e
export HOSTNAME="${domain_name}"
export EMAIL="${email_address}"
ADMIN_USER="${admin_username}"
ADMIN_PASSWORD="${admin_password}"

mkdir -p /var/www/html
chown -R www-data.www-data /var/www/html
echo "{\"status\": \"Installation in progress\"}" >> /var/www/html/status.json
chown www-data.www-data /var/www/html/status.json

echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" >> /etc/resolv.conf
# disable ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
# set hostname
hostnamectl set-hostname $HOSTNAME
echo -e "127.0.0.1 localhost $HOSTNAME" >> /etc/hosts

# Prosody 0.11.x is required for password and secure domain to work with Jibri
echo deb http://packages.prosody.im/debian $(lsb_release -sc) main | tee -a /etc/apt/sources.list
wget https://prosody.im/files/prosody-debian-packages.key -O- | apt-key add -
apt update
apt install -y prosody

# install Java
apt install -y openjdk-8-jre-headless
echo "JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:bin/java::")" | sudo tee -a /etc/profile
source /etc/profile
# install NGINX
apt install -y nginx
systemctl start nginx.service
systemctl enable nginx.service
# add Jitsi to sources
wget -qO - https://download.jitsi.org/jitsi-key.gpg.key | sudo apt-key add -
sh -c "echo 'deb https://download.jitsi.org stable/' > /etc/apt/sources.list.d/jitsi-stable.list"
apt update
echo -e "DefaultLimitNOFILE=65000\nDefaultLimitNPROC=65000\nDefaultTasksMax=65000" >> /etc/systemd/system.conf
systemctl daemon-reload
# Configure Jits install
debconf-set-selections <<< $(echo 'jitsi-videobridge jitsi-videobridge/jvb-hostname string '$HOSTNAME)
debconf-set-selections <<< 'jitsi-meet-web-config   jitsi-meet/cert-choice  select  "Generate a new self-signed certificate"';

# Debug
echo $EMAIL >> /debug.txt
echo $HOSTNAME >> /debug.txt
cat /etc/resolv.conf >> /debug.txt
whoami >> /debug.txt
cat /etc/hosts >> /debug.txt
# Install Jitsi
apt install -y jitsi-meet >> /debug.txt

cat <<~STATUSLOCATION > status.txt
location = /status.json {
  alias /var/www/html/status.json;
  access_log /var/log/nginx/status.access.log;
}
~STATUSLOCATION
sed '/error_page 404 \/static\/404\.html/r status.txt' -i /etc/nginx/sites-enabled/$HOSTNAME.conf
rm status.txt

# letsencrypt
echo $EMAIL | /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh >> /debug.txt

PROSODY_CONF_FILE=/etc/prosody/conf.d/$HOSTNAME.cfg.lua
sed -e 's/authentication \= "anonymous"/authentication \= "internal_plain"/' -i $PROSODY_CONF_FILE
echo >> $PROSODY_CONF_FILE
echo "VirtualHost \"guest.$HOSTNAME\"" >> $PROSODY_CONF_FILE
echo "    authentication = \"anonymous\"" >> $PROSODY_CONF_FILE
echo "    allow_empty_token = true" >> $PROSODY_CONF_FILE
echo "    c2s_require_encryption = false" >> $PROSODY_CONF_FILE

sed -e "s/\/\/ anonymousdomain: .*$/anonymousdomain: 'guest.$HOSTNAME',/" -i /etc/jitsi/meet/$HOSTNAME-config.js

echo "org.jitsi.jicofo.auth.URL=XMPP:$HOSTNAME" >> /etc/jitsi/jicofo/sip-communicator.properties

# Enable local STUN server
sed -e "s/org\.ice4j\.ice\.harvest\.STUN_MAPPING_HARVESTER_ADDRESSES=.*/org.ice4j.ice.harvest.STUN_MAPPING_HARVESTER_ADDRESSES=$HOSTNAME:4446/" -i /etc/jitsi/videobridge/sip-communicator.properties

echo "Enabling Moderator credentials for $ADMIN_USER" >> /debug.txt
prosodyctl --config /etc/prosody/prosody.cfg.lua register $ADMIN_USER $HOSTNAME $ADMIN_PASSWORD

${jibri_installation_script}

echo "{\"status\": \"Installation completed\"}" >> /var/www/html/status.json
chown www-data.www-data /var/www/html/status.json

echo "Setup completed" >> /debug.txt
${reboot_script}
