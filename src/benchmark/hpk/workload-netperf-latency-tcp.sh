#!/bin/bash
# Docs: https://docs.nvidia.com/networking-ethernet-software/knowledge-base/Configuration-and-Usage/Monitoring/Throughput-Testing-and-Troubleshooting/

set -x # Print each command before execution

kubectl create namespace bench
# Create workload as pods or jobs
kubectl create -n bench -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: netperf
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
      - image: networkstatic/netperf
        name: netperf
        command: ["sh", "-c"]
        args:
        - |
          netperf -H "$TEST_SERVER" -p 16604 -l 30 -t TCP_RR -- -r 200 -o min_latency,max_latency,mean_latency,stddev_latency
      restartPolicy: Never
EOF

kubectl wait --for=condition=complete --timeout=10h job/netperf -n bench

# Print results
kubectl logs job/netperf -n bench

# Clean up
kubectl delete namespace bench