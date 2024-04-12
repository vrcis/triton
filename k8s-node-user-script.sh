#!/usr/bin/env bash

# When making a Verity Docker/K8s system accessible on the internet we add a public IP address to a
# worker node which must be set as the primary NIC. When doing this it causes communication problems
# with the control plane because the kubelet on the worker node uses the IP address of the primary
# NIC and advertizes that to the control plane. That causes a problem because then the kube-apiserver
# tries to communicate with the worker node using its public IP which it cannot connect to because the
# control node is not on the public network. To address this we are now configuring the kube-apiserver
# (via the "kubelet-preferred-address-types" parameter in the RKE template) to use hostnames for
# communicating with the kubelet on other nodes because we can configure the DNS search path to resolve
# the hostname to the private IP of the node instead of resolving to the primary IP address of the node
# which may be public. To accomplish this we need to get the CNS domain into /etc/resolv.conf. For
# SmartOS zones CloudAPI does this for us automatically if CNS is enabled on the Triton account that
# owns the zone, but unfortunately CloudAPI does not support automatically populating "sdc:dns_domain"
# (which cloud-init already looks at and populates in /etc/resolv.conf if set) on HVM instances. To work
# around this limitation we are now using a custom "dns_domain" customer metadata field and setting that
# on the Rancher node templates which this user-script then grabs and adds to /etc/resolv.conf. This
# needs to happen before the docker service starts up so that the pods inherit the same DNS configuration.
# When Rancher first creates the node, the cloud-init service runs the user-script which can configure
# the DNS search domain and then Rancher installs docker and K8s. However, after a reboot, even though
# the docker service starts up after the cloud-init service, the cloud-init service does not seem to block
# so docker could (and usually does) start before cloud-init finishes running the user-script which can
# result in the pods not having the DNS search domain. To work around this, on first boot (before docker
# has been installed) this user-script will create a new "node-init" service and configure it to run after
# cloud-init and before docker to ensure that the DNS search domain is set before docker starts up so that
# the pods will have the DNS search domain as well.

# if the node-init service already exists
if [ -f /etc/systemd/system/node-init.service ]; then
   echo "The node-init service already exists. Nothing to do."
else
   echo "Creating the node-init service configuration file..."

   cat > /etc/systemd/system/node-init.service <<-EOF
	[Unit]
	Description=Initial node-init job
	# Ensure this runs before Docker since it updates
	# /etc/resolv.conf which we need propagated to the pods
	After=cloud-init.service
	Before=docker.service

	[Service]
	Type=oneshot
	ExecStart=/usr/local/bin/node-init
	RemainAfterExit=yes
	# TimeoutSec=0

	[Install]
	WantedBy=multi-user.target
	EOF

   # create the service startup script
   echo "Creating the node-init service startup script..."

   cat > /usr/local/bin/node-init <<-EOF
	#!/usr/bin/env bash
	echo "Starting node-init.service..."
	dns_domain=\$(mdata-get dns_domain)
	if [ -n "\${dns_domain}" ]; then
	   echo "Adding DNS domain \"\${dns_domain}\" to /etc/resolv.conf..."
	   echo "search \${dns_domain}" >> /etc/resolv.conf
	fi
	echo "Started node-init.service!"
	EOF

   # make it executable
   echo "Making the node-init startup script executable ..."
   chmod +x /usr/local/bin/node-init

   echo "Reloading the systemd manager configuration..."
   systemctl daemon-reload

   echo "Enabling and starting the node-init service..."
   systemctl enable --now node-init
fi