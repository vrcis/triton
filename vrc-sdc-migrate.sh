#!/usr/bin/env bash

# https://docs.tritondatacenter.com/private-cloud/instances/migrating
# https://docs.smartos.org/managing-instances-with-vmamd/#manual-migration

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

main() {
	process_arguments "$@"
	validate_params

	# list migrations
	if ${list}; then
		echo "UUID"
		if ls -1rth /opt/.vm-migration.* >/dev/null 2>&1; then
			ls -1rth /opt/.vm-migration.* | grep -v .backup | xargs -I@ basename @ | awk -F. '{print $NF}'
		fi
		exit
	fi

	has_delegate_dataset=false
	if zfs list "zones/${vm_uuid}/data" &>/dev/null; then
		has_delegate_dataset=true
	fi

	# migrate
	if ${migrate}; then
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
	# finalize
	elif ${finalize}; then
		destroy_source_snapshots
		destroy_target_snapshots
		delete_source_vm
	# rollback
	elif ${rollback}; then
		hide_target_vm
		show_source_vm
		stop_target_vm
		destroy_target_snapshots
		destroy_source_snapshots
		delete_target_vm
		start_source_vm
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

print_start() {
	printf "%s..." "$@"
}

print_start_multiline() {
	printf "%s...\n" "$@"
}

print_start_indent() {
	printf "  %s..." "$@"
}

print_end() {
	printf " done\n"
}

# print_end_multiline() {
# 	printf "  ... done\n"
# }

run_cmd_on_target_cn() {
	ssh -i /root/.ssh/sdc.id_rsa -o StrictHostKeyChecking=no "${target_cn_address}" "$@"
}

# get_vm_prop() {
# 	json "${1}" < "${SCRIPT_DIR}/.vm-migration.${vm_uuid}.backup"
# }

create_target_vm() {
	# export zone config and send to target CN
	print_start "Creating target VM"
	zonecfg -z "${vm_uuid}" export | run_cmd_on_target_cn "cat > /tmp/${vm_uuid}.zcfg"
	run_cmd_on_target_cn "zonecfg -z ${vm_uuid} -f /tmp/${vm_uuid}.zcfg && rm /tmp/${vm_uuid}.zcfg"
	print_end
}

stop_source_vm() {
	print_start_multiline "Stopping source VM"
	output=$(vmadm stop "${vm_uuid}" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"
	print_end
}

stop_target_vm() {
	print_start_multiline "Stopping target VM"
	output=$(run_cmd_on_target_cn "vmadm stop ${vm_uuid}" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"
	print_end
}

start_source_vm() {
	print_start_multiline "Starting source VM"
	output=$(vmadm start "${vm_uuid}" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"
	print_end
}

indestructible_delegated() {
	if ${has_delegate_dataset}; then
		printf "indestructible_delegated=%s" "${1}"
	fi
}

show_source_vm() {
	print_start_multiline "Showing source VM to Triton"
	output=$(vmadm update "${vm_uuid}" indestructible_zoneroot=false $(indestructible_delegated false) do_not_inventory=false 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"

	# do we need this to take affect immediately?
	svcadm restart vm-agent
	print_end
}

hide_source_vm() {
	print_start_multiline "Hiding source VM from Triton"

	output=$(vmadm update "${vm_uuid}" indestructible_zoneroot=true $(indestructible_delegated true) do_not_inventory=true 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"

	# do we need this to take affect immediately?
	svcadm restart vm-agent
	print_end
}

show_target_vm() {
	print_start_multiline "Showing target VM to Triton"
	output=$(run_cmd_on_target_cn "vmadm update ${vm_uuid} do_not_inventory=false" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"
	print_end
}

hide_target_vm() {
	print_start_multiline "Hiding target VM from Triton"
	output=$(run_cmd_on_target_cn "vmadm update ${vm_uuid} do_not_inventory=true" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"

	# do we need this to take affect immediately?
	run_cmd_on_target_cn "svcadm restart vm-agent"
	print_end
}

delete_source_vm() {
	print_start_multiline "Deleting source VM"

	output=$(vmadm update "${vm_uuid}" indestructible_zoneroot=false $(indestructible_delegated false) 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"
	print_end

	output=$(vmadm delete "${vm_uuid:?}" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"
	print_end
}

delete_target_vm() {
	print_start_multiline "Deleting target VM"

	output=$(run_cmd_on_target_cn "vmadm delete ${vm_uuid:?}" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"

	print_end
}

create_source_snapshots() {
	# create recursive snapshot
	print_start "Creating recursive @${snapshot_name} snapshot"
	zfs snap -r "zones/${vm_uuid}@${snapshot_name}"
	print_end
}

destroy_source_snapshots() {
	# create recursive snapshot
	print_start "Destroying source @${snapshot_name} snapshots"
	zfs destroy -r "zones/${vm_uuid:?}@${snapshot_name:?}"
	print_end
}

destroy_target_snapshots() {
	# create recursive snapshot
	print_start "Destroying target @${snapshot_name} snapshots"
	run_cmd_on_target_cn "zfs destroy -r zones/${vm_uuid:?}@${snapshot_name:?}"
	print_end
}

sync_datasets() {
	local dataset dataset_type prop_names preserved_props origin origin_image_uuid
	print_start_multiline "Syncing VM datasets"

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

			output=$(run_cmd_on_target_cn "imgadm import ${origin_image_uuid}" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
			print_start_indent "${output}"
			print_end

			# ZFS send/recv from the source CN to the target CN
			# doing an incremental send from the image's @final snapshot
			# since the image already exists on the target CN
			print_start_indent "Syncing ${dataset}@${snapshot_name} incrementally from zones/${origin_image_uuid}@final"
			zfs send -I "zones/${origin_image_uuid}@final" "${dataset}@${snapshot_name}" | ssh -i /root/.ssh/sdc.id_rsa -c aes128-gcm@openssh.com "${target_cn_address}" "zfs recv ${preserved_props} -d zones"
			print_end
		else
			# ZFS send/recv from the source CN to the target CN
			print_start_indent "Syncing ${dataset}@${snapshot_name}"
			zfs send "${dataset}@${snapshot_name}" | ssh -i /root/.ssh/sdc.id_rsa -c aes128-gcm@openssh.com "${target_cn_address}" "zfs recv ${preserved_props} -d zones"
			print_end
		fi
	done
}

attach_target_vm() {
	print_start "Attaching target VM"
	run_cmd_on_target_cn "zoneadm -z ${vm_uuid} attach"
	print_end
}

# create_target_cores_dataset() {
# 	echo "Creating the cores dataset for the target VM..."
# 	run_cmd_on_target_cn "zfs create -o quota=1000m -o compression=gzip -o mountpoint=/zones/${vm_uuid}/cores zones/cores/${vm_uuid}"
# }

start_target_vm() {
	print_start_multiline "Starting target VM"

	output=$(run_cmd_on_target_cn "vmadm start ${vm_uuid}" 2>&1) || { rc=${PIPESTATUS[0]}; echo "${output}"; return "${rc}"; }
	print_start_indent "${output}"

	print_end
}

validate_params() {
	# there are no params to validate for listing migrations
	${list} && return

	if [ -z "${vm_uuid}" ]; then
		echo "No VM UUID specified" >&2
		print_help
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

				# validate VM UUID
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