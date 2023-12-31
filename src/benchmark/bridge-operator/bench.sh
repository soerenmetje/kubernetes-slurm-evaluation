#!/bin/bash
# Script should be execute on Cloud VM running Kubernetes by main.sh

set -x # Print each command before execution
set -e # fail and abort script if one command fails
set -o pipefail

if [ -z "$1" ]; then
    echo "Missing argument: benchmark is not specified" >&2
    exit 1
fi

export BENCHMARK=$1
export PROJECT="bridge-operator"
export ITERATIONS=10

export S3_SECRET=mysecret-s3
export RESOURCE_SECRET=secret-slurm
export S3_ENDPOINT=minio-storage.metje.it
export RESOURCE_URL="http://10.10.41.10:6820/slurm/v0.0.39"
# Expects Kubernetes secrets mysecret-s3 and secret-slurm to be already present in Kubernetes cluster

cd /opt/bridge-operator || exit 1

# Load parse and init functions
source ./benchmark/common/parse.sh


# Create dirs in case not already exist
mkdir -p logs/
mkdir -p data/

# Empty dirs
rm -rf logs/*
rm -rf data/*

fileResult="./data/temp.csv"

# Create and init temporary result file
initResultFile > "$fileResult" || (echo "Failed to init result file. No benchmark found for '$BENCHMARK'" >&2 && exit 1)

if [ "$BENCHMARK" == "iperf3-bandwidth" ] || [ "$BENCHMARK" == "netperf-latency-tcp" ]; then
  # Iperf3 and netperf benchmarks operate in a client-server model
  TEST_SERVER=petriHPC2
  export TEST_SERVER
  # Iperf benchmark expects iperf3 server running on a node:
  # Manually start iperf server on TEST_SERVER node using:
  # iperf3 -s -p 5003
  #
  # Manually start netperf on TEST_SERVER node using:
  # netserver -p 16604

  # Run client on the other node
  SLURM_NODELIST=petriHPC1
fi

for (( i=0; i<ITERATIONS; i++ )); do
  echo "Starting interation $i / $ITERATIONS ..."

  fileLog="./logs/$(printf "log%03d.txt" $i)"

  # Reuse the workload files from slurm
  # Add whitespace at the beginning of each line an escape " for JSON
  # Also substitute env variables
  SCRIPT=$(envsubst < "$PWD/benchmark/slurm/workload-$BENCHMARK.sh" | sed 's_^_      _' | sed 's/"/\\"/g')

  START_MILLIS=$(date +%s%N | cut -b1-13) # used function parseLogFile to measure delay of workload start
  export START_MILLIS

  # Start benchmark
  # Corresponding Slurm Rest API reference: https://slurm.schedmd.com/rest_api.html#slurmV0039SubmitJob
  kubectl create -f - <<EOF
kind: BridgeJob
apiVersion: bridgejob.ibm.com/v1alpha1
metadata:
  name: slurmjob
spec:
  resourceURL: $RESOURCE_URL
  image: soerenmetje/bridge-operator-slurm-pod:v0.0.2
  resourcesecret: $RESOURCE_SECRET
  imagepullpolicy: Always
  updateinterval: 5
  jobdata:
    jobscript: |
$SCRIPT
    scriptlocation: inline
  jobproperties: |
      {
      "nodes": "1",
      "partition": "linux",
      "allocation_node_list": "$SLURM_NODELIST",
      "tasks": 1,
      "cpus_per_task": 56,
      "name": "bridge-operator-eval",
      "current_working_directory": "/nfs/workloads/bridge-operator",
      "environment": {
        "PATH": "/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin",
        "LD_LIBRARY_PATH": ""
        }
      }
  s3storage:
    s3secret: $S3_SECRET
    endpoint: $S3_ENDPOINT
    secure: true
EOF


  # Wait for job completion
  jobstate=""
  while [ "$jobstate" != "COMPLETED" ] && [ "$jobstate" != "FAILED" ] && [ "$jobstate" != "CANCELLED" ]; do
    echo "BridgeJob is not completed yet. Checking again in 5 seconds..."
    sleep 5
    jobstate=$(kubectl get configmap slurmjob-bridge-cm -o jsonpath="{.data.jobStatus}" 2>/dev/null)
  done

  # Print Bridge Operator logs
  kubectl logs slurmjob-bridge-pod

  # Workaround to obtain log output file
  # Unfortunately, the feature of Bridge-Operator to copy the Slurm job output to an S3 storage is not implemented yes (even though it is documented)
  jobId=$(kubectl get cm slurmjob-bridge-cm -o json | jq --raw-output ".data.id")
  scp -i "$HOME/.ssh/id_rsa" "smetje@10.10.41.10:/nfs/workloads/bridge-operator/slurm-${jobId}.out" "$fileLog"
  cat "$fileLog"

  # Clean up
  kubectl delete bridgejob slurmjob

  if [ "$jobstate" == "COMPLETED" ]; then
    echo "BridgeJob completed"
    parseLogFile "$fileLog" >> "$fileResult" || (echo "Failed to parse log file. No benchmark found for '$BENCHMARK'" >&2 && exit 1)
  elif [ "$jobstate" == "FAILED" ]; then
    echo "BridgeJob failed" >&2 && exit 1
  elif [ "$jobstate" == "CANCELLED" ]; then
    echo "BridgeJob cancelled" >&2 && exit 1
  fi

  # Give resources some time to recover - e.g. CPU to cool down (fair for comparison with other projects that have greater startup time)
  sleep 5
done

# Clean files (uses slurm workloads and therefore tmp files are in slurm directory)
rm /nfs/workloads/slurm/tmp/* || echo "Failed to delete temporary files in directory tmp"
