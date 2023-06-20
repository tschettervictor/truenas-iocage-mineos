#!/bin/sh
# Build an iocage jail under TrueNAS 13.0 using the current release of Caddy with MineOS
# git clone https://github.com/tschettervictor/truenas-iocage-mineos

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

#####
#
# General configuration
#
#####

# Initialize defaults
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
POOL_PATH=""
JAIL_NAME="mineos"
HOST_NAME=""
SELFSIGNED_CERT=0
STANDALONE_CERT=0
DNS_CERT=0
NO_CERT=0
CERT_EMAIL=""
CONFIG_NAME="mineos-config"

# Check for mineos-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"
INCLUDES_PATH="${SCRIPTPATH}"/includes

JAILS_MOUNT=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"

#####
#
# Input/Config Sanity checks
#
#####

# Check that necessary variables were set by mineos-config
if [ -z "${JAIL_IP}" ]; then
  echo 'Configuration error: JAIL_IP must be set'
  exit 1
fi
if [ -z "${JAIL_INTERFACES}" ]; then
  echo 'JAIL_INTERFACES not set, defaulting to: vnet0:bridge0'
JAIL_INTERFACES="vnet0:bridge0"
fi
if [ -z "${DEFAULT_GW_IP}" ]; then
  echo 'Configuration error: DEFAULT_GW_IP must be set'
  exit 1
fi
if [ -z "${POOL_PATH}" ]; then
  echo 'Configuration error: POOL_PATH must be set'
  exit 1
fi
if [ -z "${HOST_NAME}" ]; then
  echo 'Configuration error: HOST_NAME must be set'
  exit 1
fi

# Check cert config
if [ $STANDALONE_CERT -eq 0 ] && [ $DNS_CERT -eq 0 ] && [ $NO_CERT -eq 0 ] && [ $SELFSIGNED_CERT -eq 0 ]; then
  echo 'Configuration error: Either STANDALONE_CERT, DNS_CERT, NO_CERT,'
  echo 'or SELFSIGNED_CERT must be set to 1.'
  exit 1
fi
if [ $STANDALONE_CERT -eq 1 ] && [ $DNS_CERT -eq 1 ] ; then
  echo 'Configuration error: Only one of STANDALONE_CERT and DNS_CERT'
  echo 'may be set to 1.'
  exit 1
fi
if [ $DNS_CERT -eq 1 ] && [ -z "${DNS_PLUGIN}" ] ; then
  echo "DNS_PLUGIN must be set to a supported DNS provider."
  echo "See https://caddyserver.com/download for available plugins."
  echo "Use only the last part of the name.  E.g., for"
  echo "\"github.com/caddy-dns/cloudflare\", enter \"coudflare\"."
  exit 1
fi
if [ $DNS_CERT -eq 1 ] && [ "${CERT_EMAIL}" = "" ] ; then
  echo "CERT_EMAIL must be set when using Let's Encrypt certs."
  exit 1
fi
if [ $STANDALONE_CERT -eq 1 ] && [ "${CERT_EMAIL}" = "" ] ; then
  echo "CERT_EMAIL must be set when using Let's Encrypt certs."
  exit 1
fi

# Extract IP and netmask, sanity check netmask
IP=$(echo ${JAIL_IP} | cut -f1 -d/)
NETMASK=$(echo ${JAIL_IP} | cut -f2 -d/)
if [ "${NETMASK}" = "${IP}" ]
then
  NETMASK="24"
fi
if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]
then
  NETMASK="24"
fi

#####
#
# Jail Creation
#
#####

# List packages to be auto-installed after jail creation
cat <<__EOF__ >/tmp/pkg.json
{
  "pkgs": [
  "nano",
  "go",
  "git",
  "gmake",
  "openjdk17-jre",
  "npm-node16",
  "node16",
  "python39",
  "py39-rdiff-backup",
  "py39-supervisor",
  "rsync",
  "screen"
  ]
}
__EOF__

# Create the jail and install previously listed packages
if ! iocage create --name "${JAIL_NAME}" -p /tmp/pkg.json -r "${RELEASE}" interfaces="${JAIL_INTERFACES}" ip4_addr="${INTERFACE}|${IP}/${NETMASK}" defaultrouter="${DEFAULT_GW_IP}" boot="on" host_hostname="${JAIL_NAME}" vnet="${VNET}"
then
	echo "Failed to create jail"
	exit 1
fi
rm /tmp/pkg.json

#####
#
# Directory Creation and Mounting
#
#####

# set linprocfs mount (needed for webui)
iocage set mount_procfs=1 "${JAIL_NAME}"
iocage set mount_linprocfs=1 "${JAIL_NAME}"

# Create MineOS directory on selected pool
mkdir -p "${POOL_PATH}"/mineos

iocage exec "${JAIL_NAME}" mkdir -p /usr/local/www/
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/rc.d/
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/games/
iocage exec "${JAIL_NAME}" mkdir -p /var/games/minecraft

# Create and mount includes directory for Caddyfile and mount pool path
iocage exec "${JAIL_NAME}" mkdir -p /mnt/includes
iocage fstab -a "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0
iocage fstab -a "${JAIL_NAME}" "${POOL_PATH}"/mineos /var/games/minecraft nullfs rw 0 0

#####
#
# MineOS Installation
#
#####
iocage exec "${JAIL_NAME}" git clone https://github.com/hexparrot/mineos-node /usr/local/games/minecraft
iocage exec "${JAIL_NAME}" "chmod +x /usr/local/games/minecraft/*.sh"
iocage exec "${JAIL_NAME}" "chmod +x /usr/local/games/minecraft/*.js"
iocage exec "${JAIL_NAME}" "/usr/local/games/minecraft/generate-sslcert.sh"
iocage exec "${JAIL_NAME}" cp /usr/local/games/minecraft/mineos.conf /etc/mineos.conf
if ! iocage exec "${JAIL_NAME}" "cd /usr/local/games/minecraft && npm install npm -g && npm install jsegaert/node-userid && npm install"
	then
	echo "Failed to install MineOS."
 	exit 1
fi

iocage exec "${JAIL_NAME}" sed -i '' "s/^use_https.*/use_https = false/" /etc/mineos.conf

# Create mineos user
iocage exec "${JAIL_NAME}" "pw useradd -n mineos -u 8443 -G games -d /nonexistent -s /usr/local/bin/bash -h 0 <<EOF
mineos
EOF"

##### 
#
# Additional Dependency installation
#
#####

# Build xcaddy, use it to build Caddy
if ! iocage exec "${JAIL_NAME}" "go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest"
then
  echo "Failed to get xcaddy, terminating."
  exit 1
fi
if ! iocage exec "${JAIL_NAME}" cp /root/go/bin/xcaddy /usr/local/bin/xcaddy
then
  echo "Failed to move xcaddy to path, terminating."
  exit 1
fi
if [ ${DNS_CERT} -eq 1 ]; then
  if ! iocage exec "${JAIL_NAME}" xcaddy build --output /usr/local/bin/caddy --with github.com/caddy-dns/"${DNS_PLUGIN}"
  then
    echo "Failed to build Caddy with ${DNS_PLUGIN} plugin, terminating."
    exit 1
  fi  
else
  if ! iocage exec "${JAIL_NAME}" xcaddy build --output /usr/local/bin/caddy
  then
    echo "Failed to build Caddy without plugin, terminating."
    exit 1
  fi  
fi
# Generate and insall self-signed cert, if necessary
if [ $SELFSIGNED_CERT -eq 1 ]; then
	iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/pki/tls/private
	iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/pki/tls/certs
	openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=${HOST_NAME}" -keyout "${INCLUDES_PATH}"/privkey.pem -out "${INCLUDES_PATH}"/fullchain.pem
	iocage exec "${JAIL_NAME}" cp /mnt/includes/privkey.pem /usr/local/etc/pki/tls/private/privkey.pem
	iocage exec "${JAIL_NAME}" cp /mnt/includes/fullchain.pem /usr/local/etc/pki/tls/certs/fullchain.pem
fi

# Copy Caddyfile
if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  iocage exec "${JAIL_NAME}" cp -f /mnt/includes/remove-staging.sh /root/
fi
if [ $NO_CERT -eq 1 ]; then
	echo "Copying Caddyfile for no SSL"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-nossl /usr/local/www/Caddyfile
elif [ $SELFSIGNED_CERT -eq 1 ]; then
	echo "Copying Caddyfile for self-signed cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-selfsigned /usr/local/www/Caddyfile
elif [ $DNS_CERT -eq 1 ]; then
	echo "Copying Caddyfile for Lets's Encrypt DNS cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-dns /usr/local/www/Caddyfile
else
	echo "Copying Caddyfile for Let's Encrypt cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-standalone /usr/local/www/Caddyfile	
fi

# Copy rc.d files
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/caddy /usr/local/etc/rc.d/

# Edit Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/yourhostnamehere/${HOST_NAME}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/dns_plugin/${DNS_PLUGIN}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/api_token/${DNS_TOKEN}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/youremailhere/${CERT_EMAIL}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/jail_ip/${IP}/" /usr/local/www/Caddyfile

# Don't need /mnt/includes any more, so unmount it
iocage fstab -r "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

# Configure supervisord
iocage exec "${JAIL_NAME}" "cat /usr/local/games/minecraft/init/supervisor_conf.bsd >> /usr/local/etc/supervisord.conf"

# Enable and start caddy and services
iocage exec "${JAIL_NAME}" sysrc caddy_enable="YES"
iocage exec "${JAIL_NAME}" sysrc supervisord_enable="YES"
iocage exec "${JAIL_NAME}" sysrc caddy_config="/usr/local/www/Caddyfile"
iocage exec "${JAIL_NAME}" service caddy start
iocage exec "${JAIL_NAME}" service supervisord start
iocage restart "${JAIL_NAME}"

echo ""
if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  echo "You have obtained your Let's Encrypt certificate using the staging server."
  echo "This certificate will not be trusted by your browser and will cause SSL errors"
  echo "when you connect.  Once you've verified that everything else is working"
  echo "correctly, you should issue a trusted certificate.  To do this, run:"
  echo "  iocage exec ${JAIL_NAME} /root/remove-staging.sh"
  echo ""
elif [ $SELFSIGNED_CERT -eq 1 ]; then
  echo "You have chosen to create a self-signed TLS certificate for your installation."
  echo "installation.  This certificate will not be trusted by your browser and"
  echo "will cause SSL errors when you connect.  If you wish to replace this certificate"
  echo "with one obtained elsewhere, the private key is located at:"
  echo "/usr/local/etc/pki/tls/private/privkey.pem"
  echo "The full chain (server + intermediate certificates together) is at:"
  echo "/usr/local/etc/pki/tls/certs/fullchain.pem"
  echo ""
fi

echo "Installation complete."
echo "Login using the user mineos and password mineos."
echo "To change the password, use \"passwd mineos\" command from the jail."

if [ $NO_CERT -eq 1 ]; then
  echo "Using your web browser, go to http://${HOST_NAME} to log in"
else
  echo "Using your web browser, go to https://${HOST_NAME} to log in"
fi
