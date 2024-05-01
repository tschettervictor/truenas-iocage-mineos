#!/bin/sh
# Build an iocage jail under TrueNAS 13.0 and install MineOS
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
CONFIG_NAME="mineos-config"

# Check for mineos-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"

JAILS_MOUNT=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"
# If release is 13.1-RELEASE, change to 13.2-RELEASE
if [ "${RELEASE}" = "13.1-RELEASE" ]; then
  RELEASE="13.2-RELEASE"
fi 

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
  "git-lite",
  "gmake",
  "openjdk17-jre",
  "npm-node20",
  "node20",
  "yarn-node20",
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
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/games/
iocage exec "${JAIL_NAME}" mkdir -p /var/games/minecraft
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
if ! iocage exec "${JAIL_NAME}" "cd /usr/local/games/minecraft && yarn add jsegaert/node-userid && yarn install"
	then
	echo "Failed to install MineOS."
 	exit 1
fi
iocage exec "${JAIL_NAME}" sed -i '' "s/^use_https.*/use_https = false/" /etc/mineos.conf
iocage exec "${JAIL_NAME}" "pw useradd -n mineos -u 8443 -G games -d /nonexistent -s /usr/local/bin/bash -h 0 <<EOF
mineos
EOF"

#####
#
# Additional Service Installation
#
#####

# Configure supervisord
iocage exec "${JAIL_NAME}" "cat /usr/local/games/minecraft/init/supervisor_conf.bsd >> /usr/local/etc/supervisord.conf"
iocage exec "${JAIL_NAME}" sysrc supervisord_enable="YES"

# Restart
iocage restart "${JAIL_NAME}"

echo "---------------"
echo "Installation complete."
echo "---------------"
echo "Using your web browser, go to http://${IP}:8443 to log in"
echo "---------------"
echo "User Information"
echo "Default user = mineos"
echo "Default password = mineos"
echo "To change the password, use \"passwd mineos\" command from the jail."
