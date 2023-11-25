#!/bin/bash
# Docs:
# - https://iperf.fr/iperf-doc.php#3doc
# - https://docs.nvidia.com/networking-ethernet-software/knowledge-base/Configuration-and-Usage/Monitoring/Throughput-Testing-and-Troubleshooting/

set -x # Print each command before execution

kubectl create namespace bench
# Create workload as pods or jobs
kubectl create -n bench -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: iperf
spec:
  template:
    spec:
      securityContext:
        runAsUser: 0
      initContainers:
      - name: init-container-resources
        image: busybox:1.28
        command: ['sh', '-c', "echo Required for Slurm resource allocation cpuPerTask in HPK"]
        resources:
          requests:
            cpu: "20000m"
      containers:
      - image: networkstatic/iperf3
        name: iperf
        command: ["sh", "-c"]
        args:
        - |
          iperf3 --json -c "$TEST_SERVER" -p 5003 -i 1 -t 30
      restartPolicy: Never
EOF

kubectl wait --for=condition=complete --timeout=10h job/iperf -n bench

# Print results
kubectl logs job/iperf -n bench

# Clean up
kubectl delete namespace bench