package cluster

var baseWorkerCloudConfig = `#cloud-config
coreos:
  update:
    reboot-strategy: "off"

  flannel:
    interface: $private_ipv4
    etcd_endpoints: http://10.0.0.50:2379

  units:
  - name: docker.service
    command: start
    drop-ins:
      - name: 10-cbr0.conf
        content: |
          [Service]
          Environment="DOCKER_OPTS=--bridge=cbr0 --iptables=false --ip-masq=false"
  - name: install-worker.service
    command: start
    content: |
      [Service]
      ExecStart=/bin/bash /tmp/install-worker.sh
      Type=oneshot

write_files:
- path: /run/coreos-kubernetes/options.env
  content: |
    ETCD_ENDPOINTS=http://10.0.0.50:2379
    CONTROLLER_ENDPOINT=https://10.0.0.50
    ARTIFACT_URL={{ ArtifactURL }}
    ES_HOSTS={{ ElasticSearchHosts }}

- path: /tmp/install-worker.sh
  content: |
    #!/bin/bash

    exec bash -c "$(curl --fail --silent --show-error --location '{{ ArtifactURL }}/scripts/install-worker.sh')"

- path: /etc/kubernetes/ssl/ca.pem
  encoding: base64
  content: {{ CACert }}

- path: /etc/kubernetes/ssl/worker.pem
  encoding: base64
  content: {{ WorkerCert }}

- path: /etc/kubernetes/ssl/worker-key.pem
  encoding: base64
  content: {{ WorkerKey }}
`
