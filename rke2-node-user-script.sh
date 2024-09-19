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
	# users (e.g. postgres). I found it simpler to change the UID of the "_pkgsrc"
	# user on Triton volumes from 999 to 9999 to bypass id mapping altogether.
	# https://kubernetes.slack.com/archives/C09NXKJKA/p1726770810576419?thread_ts=1726587222.844109&cid=C09NXKJKA
	# https://discord.com/channels/979453320085250108/979453444727406602/1286412566083665931

	# Take 2... since Triton volumes are not configurable at creation time and more difficult
	# to configure after creation it may be simpler to create a "_pkgsrc" user with UID 999
	# on the client. However, this does require either setting the NFSv4 domain on the client
	# to "local" and leaving the domain on the NFS server unset or setting both to the same domain.

	# use a dummy NFSv4 domain
	# this doesn't need to be resolvable, it just needs to match on the NFS client and server
	# NFSV4_DOMAIN="example.local"
	# Using the domain "local" tells the NFS client to treat user and group names with no domain
	# as if they belong to the local domain. This allows id mapping to work even when the NFS
	# server does not have a NFSv4 domain set.
	NFSV4_DOMAIN=$(mdata-get nfsv4_domain 2>/dev/null || echo "local")
	IDMAPD_CONF="/etc/idmapd.conf"

	# check if the Domain line exists in the idmap config file
	if grep -q "^Domain" "${IDMAPD_CONF}"; then
		# if it exists, replace the existing Domain value
		sed -i "s/^Domain\s*=.*/Domain = ${NFSV4_DOMAIN}/" "${IDMAPD_CONF}"
	else
		# if it doesn't exist, add the Domain under the [General] section
		sed -i "/^\[General\]/a Domain = ${NFSV4_DOMAIN}" "${IDMAPD_CONF}"
	fi

	if id _pkgsrc &>/dev/null; then
		echo "User '_pkgsrc' already exists"
	else
		# the UID needs to be 999 to match the UID of the postgres user in the postgres docker image
		# and to match the UID of the _pkgsrc user on the Triton volume since we're not configuring
		# the Triton volume with a NFSv4 domain that matches the domain on the client.
		useradd -u 999 _pkgsrc
	fi
}

main "$@"