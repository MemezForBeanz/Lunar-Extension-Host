#!/usr/bin/env bash
# scripts/winvm/create.sh — define the Windows 11 test VM in libvirt and start
# the installer. Run once; scripts/winvm.sh drives the VM afterwards.
#
# Expects in libvirt's "default" storage pool (/var/lib/libvirt/images):
#   lunar-win11.qcow2   the system disk (virsh vol-create-as default lunar-win11.qcow2 100G --format qcow2)
#   Win11.iso           a Windows 11 installer      (WIN_ISO=... to override the volume name)
#   virtio-win.iso      Fedora's virtio-win drivers (VirtIO disk/network/video + guest agent)
# ISOs live in the pool, not under $HOME: QEMU runs as another user and can't
# read a 0750 home folder.
#
# The VM: Q35, UEFI with Secure Boot and Microsoft keys, TPM 2.0 (swtpm) as
# Windows 11 requires, VirtIO disk/network/video, SPICE display, and the QEMU
# guest-agent channel. 8 vCPUs / 12 GB leaves the host most of its resources.

set -euo pipefail

NAME="${WINVM_NAME:-lunar-win11}"
WIN_ISO="${WIN_ISO:-Win11_26300.iso}"
POOL_DIR=/var/lib/libvirt/images
CONNECT=qemu:///system

virt() {
	# Works before a re-login has made the libvirt group membership active.
	if id -nG | tr ' ' '\n' | grep -qx libvirt; then virt-install --connect "$CONNECT" "$@"
	else sg libvirt -c "virt-install --connect $CONNECT $(printf '%q ' "$@")"; fi
}

virt \
	--name "$NAME" \
	--osinfo win11 \
	--machine q35 \
	--cpu host-passthrough \
	--vcpus 8,sockets=1,cores=8,threads=1 \
	--memory 12288 \
	--boot firmware=efi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes \
	--tpm emulator,model=tpm-crb,version=2.0 \
	--features smm.state=on,hyperv.relaxed.state=on,hyperv.vapic.state=on,hyperv.spinlocks.state=on,hyperv.spinlocks.retries=8191 \
	--clock offset=localtime,hypervclock_present=yes \
	--disk "path=$POOL_DIR/lunar-win11.qcow2,format=qcow2,bus=virtio,cache=none,discard=unmap" \
	--cdrom "$POOL_DIR/$WIN_ISO" \
	--disk "path=$POOL_DIR/virtio-win.iso,device=cdrom,bus=sata" \
	--network network=default,model=virtio \
	--graphics spice,listen=none \
	--video virtio \
	--channel spicevmc \
	--channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
	--sound none \
	--noautoconsole

echo "VM '$NAME' defined and booting the installer. Open it with: virt-manager (or remote-viewer)."
