#!/usr/bin/env bash

# https://docs.tritondatacenter.com/private-cloud/instances/migrating
# https://docs.smartos.org/managing-instances-with-vmamd/#manual-migration

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# TODO - Can we make the script run from the HN and load the necessary stuff onto the source CN so that it can lookup with CN UUIDs

main() {
	process_arguments "$@"
	validate_params

	# list migrations
	if ${list}; then
		echo "UUID"
		if ls -1rth /opt/.vm-migration.* >/dev/null 2>&1; then
			ls -1rth /opt/.vm-migration.* | grep -v .backup | xargs -I@ basename @ | awk -F. '{print $NF}'
		fi
	# migrate
	elif ${migrate}; then
		echo "Migrating VM ${vm_uuid} (${vm_alias}) to CN ${target_cn_address}..."
		# TODO - validate image on target CN
		create_migration_record
		create_vm_info_backup
		create_target_vm
		stop_source_vm
		create_source_snapshots
		sync_datasets
		attach_target_vm
		hide_source_vm
		show_target_vm
		# looks like Triton automatically creates the cores dataset unlike on standalone SmartOS
		# create_target_cores_dataset
		start_target_vm
		echo "VM migration successful!"
		echo "Run the script again with the finalize or rollback subcommand to complete or rollback the migration."
	# finalize
	elif ${finalize}; then
		echo "Finalizing migration for VM ${vm_uuid} (${vm_alias}) to CN ${target_cn_address}..."
		destroy_source_snapshots
		destroy_target_snapshots
		delete_source_vm
		delete_vm_info_backup
		delete_migration_record
		echo "VM migration finalized!"
	# rollback
	elif ${rollback}; then
		echo "Rolling back migration for VM ${vm_uuid} (${vm_alias}) to CN ${target_cn_address}..."
		hide_target_vm
		show_source_vm
		stop_target_vm
		destroy_target_snapshots
		destroy_source_snapshots
		delete_target_vm
		start_source_vm
		delete_vm_info_backup
		delete_migration_record
		echo "VM migration successfully rolled back."
	fi
}

print_help() {
	echo "Usage:"
	printf "\t%s <sub-command> [options]\n" "$(basename $0)"
	echo
	echo "Sub-commands:"
	printf "\tlist                            - list migrations\n"
	printf "\tmigrate [-n CN_ADDRESS] VM_UUID - full automatic migration for this instance\n"
	printf "\tfinalize VM_UUID                - cleanup, removes the original source instance\n"
	printf "\trollback VM_UUID                - revert back to the original source instance\n"
	echo
}

run_cmd_on_target_cn() {
	ssh -i /root/.ssh/sdc.id_rsa "${target_cn_address}" "$@"
}

create_migration_record() {
	has_delegate_dataset=false
	if zfs list "zones/${vm_uuid}/data" &>/dev/null; then
		has_delegate_dataset=true
	fi

	echo "Creating migration record..."
	{
		echo "# Migration started on $(date)"
		echo "target_cn_address=${target_cn_address}"
		echo "has_delegate_dataset=${has_delegate_dataset}"
	} > "/opt/.vm-migration.${vm_uuid}"
}

load_migration_record() {
	echo "Loading migration record..."
	# shellcheck disable=SC1090
	source "/opt/.vm-migration.${vm_uuid}"
}

delete_migration_record() {
	echo "Deleting migration record..."
	rm "/opt/.vm-migration.${vm_uuid}"
}

get_vm_prop() {
	json "${1}" < "${SCRIPT_DIR}/.vm-migration.${vm_uuid}.backup"
}

create_vm_info_backup() {
	echo "Backing up source VM info..."
	vmadm get "${vm_uuid}" > "${SCRIPT_DIR}/.vm-migration.${vm_uuid}.backup"
}

delete_vm_info_backup() {
	echo "Deleting source VM info backup..."
	rm "${SCRIPT_DIR}/.vm-migration.${vm_uuid}.backup"
}

create_target_vm() {
	# export zone config and send to target CN
	echo "Creating target VM..."
	zonecfg -z "${vm_uuid}" export | run_cmd_on_target_cn "cat > /tmp/${vm_uuid}.zcfg"
	run_cmd_on_target_cn "zonecfg -z ${vm_uuid} -f /tmp/${vm_uuid}.zcfg && rm /tmp/${vm_uuid}.zcfg"
}

stop_source_vm() {
	echo "Stopping source VM..."
	vmadm stop "${vm_uuid}"
}

stop_target_vm() {
	echo "Stopping target VM..."
	run_cmd_on_target_cn "vmadm stop ${vm_uuid}"
}

start_source_vm() {
	echo "Starting source VM..."
	vmadm start "${vm_uuid}"
}

indestructible_delegated() {
	if ${has_delegate_dataset}; then
		printf "indestructible_delegated=%s" "${1}"
	fi
}

show_source_vm() {
	echo "Showing source VM to Triton..."
	vmadm update "${vm_uuid}" indestructible_zoneroot=false $(indestructible_delegated false) do_not_inventory=false
	# do we need this to take affect immediately?
	svcadm restart vm-agent
}

hide_source_vm() {
	echo "Safeguarding source VM and hiding it from Triton..."
	vmadm update "${vm_uuid}" indestructible_zoneroot=true $(indestructible_delegated true) do_not_inventory=true
	# do we need this to take affect immediately?
	svcadm restart vm-agent
}

show_target_vm() {
	echo "Making target VM discoverable by Triton..."
	run_cmd_on_target_cn "vmadm update ${vm_uuid} do_not_inventory=false"
}

hide_target_vm() {
	echo "Hiding target VM from Triton..."
	run_cmd_on_target_cn "vmadm update ${vm_uuid} do_not_inventory=true"
	# do we need this to take affect immediately?
	run_cmd_on_target_cn "svcadm restart vm-agent"
}

delete_source_vm() {
	echo "Deleting source VM..."
	vmadm update "${vm_uuid}" indestructible_zoneroot=false $(indestructible_delegated false)
	vmadm delete "${vm_uuid:?}"
}

delete_target_vm() {
	echo "Deleting target VM..."
	run_cmd_on_target_cn "vmadm delete ${vm_uuid:?}"
}

create_source_snapshots() {
	# create recursive snapshot
	echo "Creating recursive @${snapshot_name} snapshot..."
	zfs snap -r "zones/${vm_uuid}@${snapshot_name}"
}

destroy_source_snapshots() {
	# create recursive snapshot
	echo "Destroying source @${snapshot_name} snapshots..."
	zfs destroy -r "zones/${vm_uuid:?}@${snapshot_name:?}"
}

destroy_target_snapshots() {
	# create recursive snapshot
	echo "Destroying target @${snapshot_name} snapshots..."
	run_cmd_on_target_cn "zfs destroy -r zones/${vm_uuid:?}@${snapshot_name:?}"
}

sync_datasets() {
	# local brand=$(get_vm_prop brand)
	local dataset dataset_type prop_names preserved_props origin origin_image_uuid

	# for each dataset attached to the VM
	for dataset in $(zfs list -rHo name "zones/${vm_uuid}"); do
		# grab the properties to be preserved on the target CN
		# TODO - what about filtering on properteis with source=local?

		dataset_type=$(zfs get -Ho value type "${dataset}")

		# volume
		if [ "${dataset_type}" = "volume" ]; then
			# volsize and volblocksize seem to be preserved automatically
			# they cannot be sent otherwise you get the error "cannot receive: invalid property 'volsize'"
			# prop_names="volsize,volblocksize,sync"
			prop_names="sync"
		# filesystem
		else
			prop_names="quota,recordsize,mountpoint,sharenfs,sync"
		fi

		preserved_props=$(zfs get -Ho property,value "${prop_names}" "${dataset}" | awk '{print "-o", $1 "=" $2}' | xargs)

		origin=$(zfs get -Ho value origin "${dataset}")
		if [ "${origin}" != "-" ]; then
			preserved_props+=" -o origin=${origin}"

			# verify/import image on target CN
			origin_image_uuid=$(echo "${origin}" | sed -n 's|zones/\([0-9a-f-]*\)@.*|\1|p')
			run_cmd_on_target_cn "imgadm import ${origin_image_uuid}"
		fi

		# ZFS send/recv from the source CN to the target CN
		echo "Syncing ${dataset}@${snapshot_name}..."
		zfs send "${dataset}@${snapshot_name}" | ssh -i /root/.ssh/sdc.id_rsa -c aes128-gcm@openssh.com "${target_cn_address}" "zfs recv ${preserved_props} -d zones"
	done
}

attach_target_vm() {
	echo "Attaching target VM..."
	run_cmd_on_target_cn "zoneadm -z ${vm_uuid} attach"
}

create_target_cores_dataset() {
	echo "Creating the cores dataset for the target VM..."
	run_cmd_on_target_cn "zfs create -o quota=1000m -o compression=gzip -o mountpoint=/zones/${vm_uuid}/cores zones/cores/${vm_uuid}"
}

start_target_vm() {
	echo "Starting target VM..."
	run_cmd_on_target_cn "vmadm start ${vm_uuid}"
}

validate_params() {
	# there are no params to validate for listing migrations
	${list} && return

	if ${finalize} || ${rollback}; then
		load_migration_record
	fi

	if  [ -z "${vm_uuid}" ]; then
		echo "No VM UUID specified" >&2
		print_help
		exit 1
	fi

	# make sure there is a record of this migration before finalizing or rolling back
	if ${finalize} || ${rollback} && [ ! -f "/opt/.vm-migration.${vm_uuid}" ]; then
		echo "No migration record found for VM ${vm_uuid}" >&2
		exit 1
	fi

	if [ -z "${target_cn_address}" ]; then
		echo "No target CN address specified" >&2
		print_help
		exit 1
	fi

	if ! run_cmd_on_target_cn "exit 0"; then
		ssh_rc=${PIPESTATUS[0]}
		echo "Failed to SSH to ${target_cn_address}" >&2
		exit "${ssh_rc}"
	fi

	# check if snapshot already exists
	if ${migrate} && zfs list "zones/${vm_uuid}@${snapshot_name}" &>/dev/null; then
		echo "Snapshot zones/${vm_uuid}@${snapshot_name} already exists. Please destroy it and then try again." >&2
		exit 1
	fi
}

process_arguments() {
	snapshot_name="migration"
	action="${1}"
	list=false
	migrate=false
	finalize=false
	rollback=false

	if [ -z "${action}" ]; then
		print_help
		exit 1
	fi

	shift

	case "${action}" in
		list)
			list=true
			;;
		migrate)
			migrate=true
			;;
		finalize)
			finalize=true
			;;
		rollback)
			rollback=true
			;;
		*)
			echo "Invalid subcommand: ${action}" >&2
			print_help
			exit 1
	esac

	while [ -n "$1" ]; do
		case "$1" in
			-n|--target-cn-address)
				shift
				target_cn_address=$1
				;;
			--snapshot-name)
				shift
				snapshot_name=$1
				;;
			-h|--help)
				print_help
				exit
				;;
			*)
				vm_uuid=$1

				# TODO - validate VM UUID
				vm_alias=$(vmadm list uuid="${vm_uuid}" -Ho alias)
				if [ -z "${vm_alias}" ]; then
					echo "Invalid VM UUID: ${vm_uuid}" >&2
					exit 1
				fi
				;;
		esac
		shift
	done
}

main "$@"