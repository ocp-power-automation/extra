#!/bin/sh
# $1=local dir to share out, $2=IP address of NFS server

# $1=zone name in firewall to allow NFS traffic through
function allowNFStraffic() {
	firewall-cmd --permanent --zone=$1 --add-service=nfs
	firewall-cmd --permanent --zone=$1 --add-service=rpc-bind
	firewall-cmd --permanent --zone=$1 --add-service=mountd
	firewall-cmd --reload
}

LOCALDIR=$1
if [ -z "$LOCALDIR" ]; then
	echo "ERROR: No local dir to share specified -- aborting..."
	exit 1
fi

if [ ! -d "$LOCALDIR" ]; then
	echo "ERROR: $LOCALDIR not present or accessible -- aborting..."
	exit 2
fi

SVRADDR=$2
if [ -z "$SVRADDR" ]; then
	echo "ERROR: No NFS server address specified -- aborting..."
	exit 3
fi

if [ -z "$KUBECONFIG" -o ! -f $KUBECONFIG ]; then
	echo "ERROR: \$KUBECONFIG not specified -- aborting..."
	exit 4
fi

echo "INFO: proceeding with making this node as NFS server..."

yum install -y nfs-utils
rpm -qa | grep -q nfs-utils
if [ $? -ne 0 ]; then
	echo "ERROR: failed to install nfs-utils package -- aborting..."
	exit 5
fi

systemctl enable --now rpcbind
if [ $? -ne 0 ]; then
	echo "ERROR: failed to enable and start rpcbind service -- aborting..."
	exit 6
fi

systemctl enable --now nfs-server
if [ $? -ne 0 ]; then
	echo "ERROR: failed to enable and start nfs-server service -- aborting..."
	exit 7
fi

chmod -R 755 $LOCALDIR

for z in public libvirt; do
	firewall-cmd --get-active-zones | grep -q "^$z\$" && allowNFStraffic $z
done

EXPORTS=/etc/exports
grep -q "^$LOCALDIR " $EXPORTS
if [ $? -ne 0 ]; then
	echo "$LOCALDIR *(rw,sync,no_root_squash)" >> $EXPORTS
	exportfs -rav
	systemctl restart nfs-server
fi

WORKDIR=`mktemp -d`
mkdir -p $WORKDIR
pushd $WORKDIR > /dev/null

echo "INFO: downloading and extracting external-storage zip..."

THEZIP=kubernetes-incubator.zip
curl -s -L -o $THEZIP https://github.com/kubernetes-incubator/external-storage/archive/master.zip
if [ $? -ne 0 ]; then
	echo "ERROR: failed to download external storage zip -- aborting..."
	exit 8
fi

which unzip 2>&1 >/dev/null || yum -y install unzip
if [ $? -ne 0 ]; then
	echo "ERROR: unzip command unavailable -- aborting..."
	exit 9
fi
unzip -q $THEZIP

cd external-storage-master/nfs-client/

echo "INFO: generating deployment.yaml for ppc64le..."

which go 2>&1 >/dev/null || yum -y install golang-bin
which yq 2>&1 >/dev/null || GO111MODULE=on go get github.com/mikefarah/yq/v4
if [ $? -ne 0 ]; then
	echo "ERROR: yq command unavailable -- aborting..."
	exit 10
fi
test -z "$GOBIN" && PATH=$PATH:~/go/bin || PATH=$PATH:$GOBIN
yq --version | grep -q 'version 4\.'
if [ $? -ne 0 ]; then
	echo "ERROR: only yq v4 supported -- aborting..."
	exit 11
fi

DEPLYAML=deploy/deployment-ppc64le.yaml
yq eval " \
   .spec.template.spec.containers[0].image = \"docker.io/ibmcom/nfs-client-provisioner-ppc64le:latest\" | \
   (.spec.template.spec.containers[0].env[] | select(.name==\"NFS_SERVER\")).value = \"$SVRADDR\" | \
   (.spec.template.spec.containers[0].env[] | select(.name==\"NFS_PATH\")).value = \"$LOCALDIR\" | \
   .spec.template.spec.volumes[0].nfs.server = \"$SVRADDR\" | \
   .spec.template.spec.volumes[0].nfs.path = \"$LOCALDIR\" \
" deploy/deployment.yaml > $DEPLYAML
if [ $? -ne 0 -o ! -s $DEPLYAML ]; then
	echo "ERROR: failed to update deployment.yaml -- aborting..."
	exit 12
fi

echo "INFO: executing oc commands to set up NFS provisioner..."

oc create -f deploy/rbac.yaml
oc adm policy add-scc-to-user hostmount-anyuid system:serviceaccount:default:nfs-client-provisioner
oc create -f deploy/class.yaml
oc create -f $DEPLYAML
cp -pf $DEPLYAML /tmp/nfs-provisioner-deploy.yaml

popd > /dev/null

rm -rf $WORKDIR
