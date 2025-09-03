#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o xtrace

main() {
	wait_for_apt_lock
	apt-get -y update
	
	# Detect node role first (needed by configure_rke2 and configure_nfs_client)
	detect_node_role
	
	configure_rke2
	
	# Configure NFS only for worker nodes
	if [ "$ROLE" = "worker" ]; then
		configure_nfs_client
	fi
}

wait_for_apt_lock() {
	printf "Waiting for other apt processes to finish"
	while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
		sleep 5
	done
}

detect_node_role() {
	# Get role from Triton metadata (control, etcd, worker)
	# This must be set in metadata since RKE2 isn't installed yet when this script runs
	ROLE=$(mdata-get role 2>/dev/null || echo "")
	
	# If no role in metadata, default to worker since that's what previously
	# ran this script (and NFS is safe to configure even if not needed)
	if [ -z "$ROLE" ]; then
		echo "Warning: No role found in metadata, defaulting to 'worker' for backwards compatibility"
		ROLE="worker"
	fi
	
	echo "Node role: $ROLE"
}

configure_nfs_client() {
	# https://blog.sinjakli.co.uk/2021/10/25/waiting-for-apt-locks-without-the-hacky-bash-scripts/
	apt-get -y -o DPkg::Lock::Timeout=300 install nfs-common

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

configure_rke2() {
	# https://docs.rke2.io/install/configuration#configuration-file

	# Get IPs from Triton metadata using nic_tag
	NICS_JSON=$(mdata-get sdc:nics)
	
	# Find private IP (nic_tag starts with "sdc_overlay")
	PRIVATE_IP=$(echo "$NICS_JSON" | python3 -c "
import json, sys
nics = json.load(sys.stdin)
for nic in nics:
    if nic.get('nic_tag', '').startswith('sdc_overlay'):
        print(nic['ip'])
        break
")
	
	# Find external IP (nic_tag = "external") - all nodes can have this
	EXTERNAL_IP=$(echo "$NICS_JSON" | python3 -c "
import json, sys
nics = json.load(sys.stdin)
for nic in nics:
    if nic.get('nic_tag') == 'external':
        print(nic['ip'])
        break
")
	
	# Only look for public IP for worker nodes
	if [ "$ROLE" = "worker" ]; then
		# Find public IP (nic_tag = "public") - internet routable, workers only
		PUBLIC_IP=$(echo "$NICS_JSON" | python3 -c "
import json, sys
nics = json.load(sys.stdin)
for nic in nics:
    if nic.get('nic_tag') == 'public':
        print(nic['ip'])
        break
")
		
		# For workers: prefer public over external for node-external-ip
		NODE_EXTERNAL_IP="${PUBLIC_IP:-${EXTERNAL_IP}}"
	else
		# Control and etcd nodes: use external IP only (no public IP)
		NODE_EXTERNAL_IP="${EXTERNAL_IP}"
	fi

	# abort if no private IP is found
	if [ -z "$PRIVATE_IP" ]; then
		echo "Error: No sdc_overlay IP found in Triton metadata."
		exit 1
	fi

	# ensure config directory exists
	mkdir -p /etc/rancher/rke2

	# write RKE2 config file
	cat <<EOF > /etc/rancher/rke2/config.yaml
node-ip: ${PRIVATE_IP}
EOF

	# Add external IP if available (public for workers, external for control/etcd)
	if [ -n "${NODE_EXTERNAL_IP}" ]; then
		cat <<EOF >> /etc/rancher/rke2/config.yaml
node-external-ip: ${NODE_EXTERNAL_IP}
EOF
		echo "Configured RKE2 ${ROLE} with node-ip=${PRIVATE_IP}, node-external-ip=${NODE_EXTERNAL_IP}"
	else
		echo "Configured RKE2 ${ROLE} with node-ip=${PRIVATE_IP} (no external IP)"
	fi

	# restart the agent if already running
	if systemctl is-active --quiet rke2-agent; then
		systemctl restart rke2-agent
	fi
}

main "$@"
