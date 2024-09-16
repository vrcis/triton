#!/usr/bin/env bash

wait_for_apt_lock() {
   printf "Waiting for other apt processes to finish"
   while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
      sleep 5
   done
}

wait_for_apt_lock
apt -y update
# apt -y -o DPkg::Lock::Timeout=300 install nfs-common
apt -y install nfs-common