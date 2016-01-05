package cluster

var baseWorkerCloudConfig = `#cloud-config
coreos:
  update:
    reboot-strategy: "off"

  units:
  - name: docker.service
    command: start
    drop-ins:
      - name: 10-cbr0.conf
        content: |
          [Service]
          Environment="DOCKER_OPTS=--bridge=cbr0 --iptables=false --ip-masq=false --log-level=warn"

  - name: install-worker.service
    command: start
    content: |
      [Service]
      ExecStart=/bin/bash /tmp/install-worker.sh
      Type=oneshot

write_files:
- path: /run/coreos-kubernetes/options.env
  content: |
    CONTROLLER_ENDPOINT=https://kubernetes.{{ ClusterName }}.cluster.local
    ARTIFACT_URL={{ ArtifactURL }}
    DNS_SERVICE_IP={{ DNSServiceIP }}
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
