#!/bin/bash
# Helper script to copy monitor_gpu_vm.sh to VM
# Run this on the host to install the monitoring script in the VM

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <vm_name> [vm_user]"
    echo ""
    echo "Example: $0 v620-vm ubuntu"
    echo ""
    echo "This script copies monitor_gpu_vm.sh to the VM and makes it executable."
    exit 1
fi

VM_NAME="$1"
VM_USER="${2:-ubuntu}"

echo "Installing GPU monitor in VM '$VM_NAME' as user '$VM_USER'..."

# Get VM IP from MAC address (if using libvirt default network)
echo "Finding VM IP..."
VM_MAC=$(virsh dumpxml "$VM_NAME" 2>/dev/null | grep "mac address" | head -1 | grep -oE "[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}" | tr '[:lower:]' '[:upper:]')

if [[ -z "$VM_MAC" ]]; then
    echo "ERROR: Could not find VM MAC address"
    exit 1
fi

echo "VM MAC: $VM_MAC"
echo "Waiting for VM to respond to ARP ping..."

# Wait for VM to be reachable
for i in {1..30}; do
    VM_IP=$(ip neigh | grep "$VM_MAC" | awk '{print $1}' | head -1)
    if [[ -n "$VM_IP" ]]; then
        break
    fi
    sleep 1
done

if [[ -z "$VM_IP" ]]; then
    echo "ERROR: Could not determine VM IP address. Is VM running?"
    echo "Try manually: ssh $VM_USER@<vm-ip>"
    exit 1
fi

echo "VM IP: $VM_IP"

# Copy the script
echo "Copying monitor_gpu_vm.sh to VM..."
scp -o StrictHostKeyChecking=no /home/beefyboi/amdtests/monitor_gpu_vm.sh "${VM_USER}@${VM_IP}:~/monitor_gpu_vm.sh"

if [[ $? -eq 0 ]]; then
    echo "Script copied successfully"
    echo "Making executable on VM..."
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" "chmod +x ~/monitor_gpu_vm.sh"
    echo "Done!"
    echo ""
    echo "To run the monitor in the VM:"
    echo "  ssh ${VM_USER}@${VM_IP}"
    echo "  sudo ~/monitor_gpu_vm.sh"
else
    echo "ERROR: Failed to copy script to VM"
    echo "Make sure VM is running and SSH is accessible"
    exit 1
fi
