#!/bin/bash
set -e

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=

# The endpoint the worker node should use to contact controller nodes (https://ip:port)
# In HA configurations this should be an external DNS record or loadbalancer in front of the control nodes.
# However, it is also possible to point directly to a single control node.
export CONTROLLER_ENDPOINT=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_VER=v1.1.1

# The address of the AWS provided DNS server in the cluster subnet.  It is the .2 address in 
# whatever CIDR was assigned to the cluster subnet.
export AWS_DNS=10.0.0.2

# The CIDR network to use for pod IPs.
# Each pod launched in the cluster will be assigned an IP out of this range.
# Each node will be configured such that these IPs will be routable using the Kubernetes AWS cloud provider.
export POD_NETWORK=10.2.0.0/16

# The IP address of the cluster DNS service.
# This must be the same DNS_SERVICE_IP used when configuring the controller nodes.
export DNS_SERVICE_IP=10.3.0.10

# The HTTP(S) host serving the necessary Kubernetes artifacts
export ARTIFACT_URL=

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/run/coreos-kubernetes/options.env

# -------------

function template {
	# use a heredoc so the quoting & whitespace in the
	# downloaded artifact is preserved, but env variables
	# can still be evaluated
	eval "cat <<EOF
$(curl --silent -L "${ARTIFACT_URL}/$1")
EOF
" > $2
}

function install_kubelet {
	mkdir /opt
	cd /opt
	curl -sLO https://storage.googleapis.com/kubernetes-release/release/v1.1.1/bin/linux/amd64/kubelet
	chmod a+rx /opt/kubelet
}

function init_config {
	local REQUIRED=( 'ADVERTISE_IP' 'ETCD_ENDPOINTS' 'CONTROLLER_ENDPOINT' 'DNS_SERVICE_IP' 'K8S_VER' 'ARTIFACT_URL' )

	if [ -f $ENV_FILE ]; then
		export $(cat $ENV_FILE | xargs)
	fi

	if [ -z $ADVERTISE_IP ]; then
		export ADVERTISE_IP=$(awk -F= '/COREOS_PRIVATE_IPV4/ {print $2}' /etc/environment)
	fi

	for REQ in "${REQUIRED[@]}"; do
		if [ -z "$(eval echo \$$REQ)" ]; then
			echo "Missing required config value: ${REQ}"
			exit 1
		fi
	done
}

function init_raid {
	instance_disks=( $(lsblk  -lp -o NAME,TYPE |grep disk |cut -d' ' -f 1 | grep -v xvda) )
	if (( ${#instance_disks[@]} > 1 )); then
		/usr/sbin/mdadm --create /dev/md0 --level=0 --chunk=512 --raid-devices=${#instance_disks[@]} ${instance_disks[@]}
		/usr/sbin/mdadm --detail --scan > /etc/mdadm.conf
		/usr/sbin/mkfs.ext4 -b 4096 -E stride=128,stripe-width=$((128 * ${#instance_disks[@]})) /dev/md0


		cat << EOF > /etc/systemd/system/var-lib-kubelet.mount
[Unit]
Before=docker.service
[Mount]
What=/dev/md0
Where=/var/lib/kubelet
Type=ext4
[Install]
WantedBy=multi-user.target
EOF

		systemctl daemon-reload
		systemctl enable var-lib-kubelet.mount
		systemctl start var-lib-kubelet.mount
	fi
}

function init_templates {
	local TEMPLATE=/etc/systemd/system/kubelet.service
	[ -f $TEMPLATE ] || {
		echo "TEMPLATE: $TEMPLATE"
		mkdir -p $(dirname $TEMPLATE)
		cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests
ExecStartPre=/usr/sbin/iptables -t nat -A POSTROUTING -s ${POD_NETWORK} -d ${AWS_DNS}/32 -j MASQUERADE
ExecStart=/opt/kubelet \
  --api_servers=${CONTROLLER_ENDPOINT} \
  --register-node=true \
  --allow-privileged=true \
  --config=/etc/kubernetes/manifests \
  --cluster_dns=${DNS_SERVICE_IP} \
  --cluster_domain=cluster.local \
  --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml \
  --tls-cert-file=/etc/kubernetes/ssl/worker.pem \
  --tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem \
  --cadvisor-port=0 \
  --cloud-provider=aws \
  --configure-cbr0=true
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
	}

	mkdir -p /etc/kubernetes/manifests
	template manifests/worker/kubeconfig /etc/kubernetes/worker-kubeconfig.yaml
	template manifests/worker/kube-proxy.yaml /etc/kubernetes/manifests/kube-proxy.yaml
	template manifests/worker/aws-node-labels.yaml /etc/kubernetes/manifests/aws-node-labels.yaml
	template manifests/worker/fluentd.yaml /etc/kubernetes/manifests/fluentd.yaml
}

init_config
init_raid
install_kubelet
init_templates

systemctl daemon-reload
systemctl stop update-engine; systemctl mask update-engine
echo "REBOOT_STRATEGY=off" >> /etc/coreos/update.conf

systemctl enable kubelet; systemctl start kubelet
