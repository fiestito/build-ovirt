#!/bin/bash

# Take one argument from the commandline: VM name
if ! [ $# -eq 1 ]; then
    echo "Usage: $0 <user-name>"
    exit 1
fi

#VM name
VM_NAME=ovirt-engine

# Check if domain already exists
virsh dominfo $VM_NAME > /dev/null 2>&1
if [ "$?" -eq 0 ]; then
    echo -n "[WARNING] $VM_NAME already exists.  "
    read -p "Do you want to overwrite $VM_NAME [y/N]? " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
    else
        echo -e "\nNot overwriting $VM_NAME. Exiting..."
        exit 1
    fi
fi

# Directory to store images
DIR=/home/$1/ovirt-build/images
mkdir -p $DIR

MASTER_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ssh key file
SSH_KEY=$(cat /home/$1/.ssh/id_rsa.pub)

# Location of cloud image
CENTOS_IMAGE=$DIR/CentOS-7-x86_64-GenericCloud.qcow2

# Verify the cloud image is in place, if not download it
if [ ! -f "$CENTOS_IMAGE" ]
    then
	echo "Downloading centos cloud image"
	wget http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2 \
        -O $CENTOS_IMAGE -q --show-progress
else
	echo "Centos image already in place"
fi

IMAGE=$CENTOS_IMAGE
#IMAGE=$UBUNTU_IMAGE

# User of cloud image
if [ $IMAGE == $CENTOS_IMAGE ]; then
	USER_IMG=centos;
	RM_CLOUDINIT=$(echo "yum, -y, remove, cloud-init")
else
	USER_IMG=ubuntu;
	RM_CLOUDINIT=$(echo "apt-get, remove, cloud-init, -y")
fi	 

# Amount of RAM in MB
MEM=2048

# Number of virtual CPUs
CPUS=2

# Cloud init files
USER_DATA=user-data
META_DATA=meta-data
CI_ISO=$VM_NAME-cidata.iso
DISK=$VM_NAME.qcow2
DISK2=$VM_NAME-disk2.qcow2

# Bridge for VMs (default on Fedora is virbr0)
BRIDGE=virbr0

# Start clean
rm -rf $DIR/$VM_NAME
mkdir -p $DIR/$VM_NAME

pushd $DIR/$VM_NAME > /dev/null

    # Create log file
    touch $VM_NAME.log

    echo "$(date -R) Destroying the $VM_NAME domain (if it exists)..."

    # Remove domain with the same name
    virsh destroy $VM_NAME >> $VM_NAME.log 2>&1
    virsh undefine $VM_NAME >> $VM_NAME.log 2>&1

    # cloud-init config: set hostname, remove cloud-init package,
    # and add ssh-key 
    cat > $USER_DATA << _EOF_

#cloud-config

# Hostname management
preserve_hostname: False
hostname: $VM_NAME
fqdn: $VM_NAME-engine.example.com

# Set root pass
users:
  - name: root
  - name: centos
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh-authorized-keys:
      - $SSH_KEY
chpasswd:
  list: |
    root:centos
  expire: False

# Intall some extra packages
packages:
  - epel-release
  - telnet
  - nmap
  - bash-completion

# Upgrade system
#package_upgrade: true

# Remove cloud-init when finished with it
runcmd:
  - [ $RM_CLOUDINIT ]

# Configure where output will go
output: 
  all: ">> /var/log/cloud-init.log"

_EOF_

    echo "instance-id: $VM_NAME; local-hostname: $VM_NAME" > $META_DATA

    echo "$(date -R) Copying template image..."
    cp $IMAGE $DISK

    qemu-img create -f qcow2 $DISK2 20G

    # Create CD-ROM ISO with cloud-init config
    echo "$(date -R) Generating ISO for cloud-init..."
    genisoimage -output $CI_ISO -volid cidata -joliet -r $USER_DATA $META_DATA &>> $VM_NAME.log

    echo "$(date -R) Installing the domain and adjusting the configuration..."
    echo "[INFO] Installing with the following parameters:"
    echo "virt-install --import --name $VM_NAME --ram $MEM --vcpus $CPUS --disk DISK,format=qcow2,bus=virtio --disk $DISK2,format=qcow2,bus=virtio --disk $CI_ISO,device=cdrom --network bridge=virbr0,model=virtio --os-type=linux --os-variant=rhel7 --noautoconsole"

    virt-install --import --name $VM_NAME --ram $MEM --vcpus $CPUS --disk \
    $DISK,format=qcow2,bus=virtio --disk $DISK2,format=qcow2,bus=virtio --disk \
    $CI_ISO,device=cdrom --network bridge=virbr0,model=virtio \
    --os-type=linux --os-variant=rhel7 --noautoconsole

    MAC=$(virsh dumpxml $VM_NAME | awk -F\' '/mac address/ {print $2}')
    while true
    do
        IP=$(grep -B1 $MAC /var/lib/libvirt/dnsmasq/$BRIDGE.status | head \
             -n 1 | awk '{print $2}' | sed -e s/\"//g -e s/,//)
        if [ "$IP" = "" ]
        then
            sleep 1
        else
            break
        fi
    done

    # Eject cdrom
    echo "$(date -R) Cleaning up cloud-init..."
    virsh change-media $VM_NAME hda --eject --config >> $VM_NAME.log

    # Remove the unnecessary cloud init files
    rm $USER_DATA $CI_ISO

    # Set host name with new ip on host file and ansible vars file
    echo "$(date -R) Setting host name and vars"
    if grep -q ovirt-engine /etc/hosts
    then 
	sed -i '/ovirt-engine/c\'"$IP"' ovirt-engine.example.com ovirt-engine'  /etc/hosts
    else
	echo "$IP ovirt-engine.example.com ovirt-engine" >> /etc/hosts
    fi

    sed -i '/engine_ip/c\engine_ip: '"$IP"'' $MASTER_DIR/ovirt-ansible/vars/conf_vars.yml
    BASEADDR=$(echo $IP | awk -F. '{$NF="";print $0}' | tr  " " ".")
    HOST1IP=$(expr $(echo $IP | awk -F. '{print $4}') + 1)
    HOST2IP=$(expr $HOST1IP + 1)
    sed -i '/host1_ip/c\host1_ip: '"$BASEADDR"''"$HOST1IP"'' $MASTER_DIR/ovirt-ansible/vars/conf_vars.yml
    sed -i '/host2_ip/c\host2_ip: '"$BASEADDR"''"$HOST2IP"'' $MASTER_DIR/ovirt-ansible/vars/conf_vars.yml
    sed -i '/gw_ip/c\gw_ip: '"$BASEADDR"'1' $MASTER_DIR/ovirt-ansible/vars/conf_vars.yml
    echo "$(date -R) DONE. SSH to $VM_NAME using ' ssh $USER_IMG@ovirt-engine '"

popd > /dev/null
 
exit 0
