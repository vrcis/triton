#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o xtrace

main() {
	wait_for_apt_lock
	apt-get -y update
	configure_nfs_client
}

wait_for_apt_lock() {
   printf "Waiting for other apt processes to finish"
   while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
      sleep 5
   done
}

configure_nfs_client() {
	# apt -y -o DPkg::Lock::Timeout=300 install nfs-common
	apt-get -y install nfs-common

	# Don't configure the node for NFSv4 domain mapping because that requires
	# that the NFS client (this node) and server (Triton volume) have the same
	# users (e.g. postgres). I found it simpler to change the UID of the _pkgsrc
	# user on Triton volumes from 999 to 9999.
	# https://kubernetes.slack.com/archives/C09NXKJKA/p1726770810576419?thread_ts=1726587222.844109&cid=C09NXKJKA
	# https://discord.com/channels/979453320085250108/979453444727406602/1286412566083665931

	# use a dummy NFSv4 domain
	# this doesn't need to be resolvable, it just needs to match on the NFS client and server
	# NFSV4_DOMAIN="example.local"
	# IDMAPD_CONF="/etc/idmapd.conf"

	# # check if the Domain line exists in the idmap config file
	# if grep -q "^Domain" "${IDMAPD_CONF}"; then
	# 	# if it exists, replace the existing Domain value
	# 	sed -i "s/^Domain=.*/Domain=${NFSV4_DOMAIN}/" "$IDMAPD_CONF"
	# else
	# 	# if it doesn't exist, add the Domain under the [General] section
	# 	sed -i "/^\[General\]/a Domain=${NFSV4_DOMAIN}" "$IDMAPD_CONF"
	# fi
}

main "$@"