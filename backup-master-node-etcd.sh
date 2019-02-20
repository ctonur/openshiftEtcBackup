#!/bin/bash
###################################
# Purpose: Backup etcd and restore
###################################

set -eo pipefail

BACKUPLOCATION=/backup/$(hostname)/$(date +%Y%m%d)
OPERATION=${1:-"backup-etcd"}
mkdir -p ${BACKUPLOCATION}

OCPFILES="atomic-openshift-master atomic-openshift-master-api atomic-openshift-master-controllers atomic-openshift-node"

die(){
  echo "$1"
  exit $2
}

usage(){
  echo "$0 [operation]"
  echo "  Default operation is backup-etcd"
  echo "  Default backup dir is ${BACKUPLOCATION}"
  echo "  "
  echo "Available Oparations:"
  echo "    backup-etcd: $0 backup-etcd"
  echo "    restore-etcd: $0 restore-etcd"
  echo "    remove-etcd: $0 remove-etcd"
}


if [[ ( $@ == "--help") ||  $@ == "-h" ]]
then
  usage
  exit 0
fi

if [[ '$#' -ne 2 ]]
then
  echo "Invalid Operations entered"
  echo "enter operation you want to do"
  usage
  exit 0
fi

backupOcpFiles(){
  mkdir -p ${BACKUPLOCATION}/etc/sysconfig
  echo "Exporting OCP related files to ${BACKUPLOCATION}"
  cp -aR /etc/origin ${BACKUPLOCATION}/etc
  for file in ${OCPFILES}
  do
    if [ -f /etc/sysconfig/${file} ]
    then
      cp -aR /etc/sysconfig/${file} ${BACKUPLOCATION}/etc/sysconfig/
    fi
  done
}

backupOtherFiles(){
  mkdir -p ${BACKUPLOCATION}/etc/sysconfig
#  mkdir -p ${BACKUPLOCATION}/etc/pki/ca-trust/source/anchors
  echo "Exporting other important files to ${BACKUPLOCATION}"
  if [ -f /etc/sysconfig/flanneld ]
  then
    cp -a /etc/sysconfig/flanneld \
      ${BACKUPLOCATION}/etc/sysconfig/
  fi
  cp -aR /etc/sysconfig/{iptables,docker-*} \
    ${BACKUPLOCATION}/etc/sysconfig/
  if [ -d /etc/cni ]
  then
    cp -aR /etc/cni ${BACKUPLOCATION}/etc/
  fi
  cp -aR /etc/dnsmasq* ${BACKUPLOCATION}/etc/
#  cp -aR /etc/pki/ca-trust/source/anchors/* \
#    ${BACKUPLOCATION}/etc/pki/ca-trust/source/anchors/
}

packageList(){
  echo "Creating a list of rpms installed in ${BACKUPLOCATION}"
  rpm -qa | sort > ${BACKUPLOCATION}/packages.txt
}

etcdConfigBackup()
{
  echo "Script is going to backup etcd config"
  echo $BACKUPETCD

  #ETCD config
  mkdir -p ${BACKUPLOCATION}/etcd-config
  cp /etc/etcd/* ${BACKUPLOCATION}/etcd-config/

  #ETCD backup pod definition files
  mkdir -p ${BACKUPLOCATION}/pods-yaml
  cp /etc/origin/node/pods/* ${BACKUPLOCATION}/pods-yaml/

}

etcdDataBackup()
{

  echo "Script is going to backup etcd data"
  echo $BACKUPETCD

  #ETCD data
  mkdir -p ${BACKUPLOCATION}/etcd-data

  export ETCD_POD_MANIFEST="/etc/origin/node/pods/etcd.yaml"

  export ETCD_EP=$(grep https ${ETCD_POD_MANIFEST} | cut -d '/' -f3)

  export ETCD_POD=$(oc get pods -n kube-system | grep -o -m 1 '\S*etcd-'$(hostname)'\S*')

  echo ETCD_POD_MANIFEST:${ETCD_POD_MANIFEST}
  echo ETCD_EP:${ETCD_EP}
  echo ETCD_POD:${ETCD_POD}

  oc exec ${ETCD_POD} -c etcd -- /bin/bash -c "ETCDCTL_API=3 etcdctl \
    --cert /etc/etcd/peer.crt \
    --key /etc/etcd/peer.key \
    --cacert /etc/etcd/ca.crt \
    --endpoints ${ETCD_EP} \
    snapshot save /var/lib/etcd/snapshot.db"
  
  cp /var/lib/etcd/snapshot.db ${BACKUPLOCATION}/etcd-data/
}

etcdServiceConfig()
{

  yum install iptables-services etcd -y

  systemctl enable iptables.service --now
#  iptables -N OS_FIREWALL_ALLOW
  iptables -t filter -I INPUT -j OS_FIREWALL_ALLOW
  iptables -A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 2379 -j ACCEPT
  iptables -A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 2380 -j ACCEPT
  iptables-save | tee /etc/sysconfig/iptables

}

etcdRestore()
{

  echo "restoring etcd!!!"
  cp ${BACKUPLOCATION}/etcd-config/etcd.conf /etc/etcd/etcd.conf
  restorecon -Rv /etc/etcd/etcd.conf

  #directory need to be removed before restore
  #reboot server to resolve file lock
  #if it is mountted as file system you can not remove!!!
  rm -rf /var/lib/etcd


  #restore data and pod definition

  export ETCD_POD_MANIFEST="${BACKUPLOCATION}/pods-yaml/etcd.yaml"

  export ETCD_EP=$(grep https ${ETCD_POD_MANIFEST} | cut -d '/' -f3 | cut -d ':' -f1)


  echo ETCD_POD_MANIFEST:${ETCD_POD_MANIFEST}
  echo ETCD_EP:${ETCD_EP}

  rm -rf /etc/origin/node/pods/*

  export ETCDCTL_API=3
  echo "restoring from snapshoot!!!"
  etcdctl snapshot restore ${BACKUPLOCATION}/etcd-data/snapshot.db \
    --data-dir /var/lib/etcd/ \
    --name $(hostname) \
    --initial-cluster "$(hostname)=https://${ETCD_EP}:2380" \
    --initial-cluster-token "etcd-cluster-1" \
    --initial-advertise-peer-urls https://${ETCD_EP}:2380 \
    --skip-hash-check=true

  #directory is created after resore command
  chown -R etcd.etcd /var/lib/etcd/
  restorecon -Rv /var/lib/etcd/

  echo "copy certificate"
  cp -R ${BACKUPLOCATION}/etcd-config/ /etc/etcd/

  echo "copy pods definitions"
  cp ${BACKUPLOCATION}/pods-yaml/* /etc/origin/node/pods/

}

etcdRemove()
{

  yum remove etcd -y
  rm -rf /etc/origin/node/pods/*

  systemctl restart docker
  rm -rf /var/lib/etcd
}


if [[ $1 -ne "backup-etcd" || $1 -ne "restore-etcd" || $1 -ne "remove-etcd" ]]
then
  echo "Invalid Operations entered"
  echo "enter operation you want to do"
  usage
  exit 0
fi


#echo backup location is : ${BACKUPLOCATION}


if [[ $OPERATION == "backup-etcd" ]]
then
  backupOcpFiles
  backupOtherFiles
  packageList
  etcdConfigBackup
  etcdDataBackup
fi

#if [[ $OPERATION == "restore-etcd" ]]
#then
#  etcdServiceConfig
#  etcdRestore
#fi

#if [[ $OPERATION == "remove-etcd" ]]
#then
#  etcdRemove
#fi

exit 0
