#!/bin/bash
# Script should be execute on Slurm cluster by main.sh
# Expects that HPK kubelet and kubemaster is started manually before

source /etc/profile # Fix slurm seems to be not in PATH

set -x # Print each command before execution
set -e # fail and abort script if one command fails
set -o pipefail

if [ -z "$1" ]; then
    echo "Missing argument: benchmark is not specified" >&2
    exit 1
fi

export BENCHMARK=$1
export PROJECT="hpk"
export ITERATIONS=10

export KUBE_PATH=~/.k8sfs/kubernetes/
export KUBECONFIG=${KUBE_PATH}/admin.conf
kubectl get nodes

cd /nfs/workloads/$PROJECT || exit 1

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

if [ "$BENCHMARK" == "iperf3-bandwidth"  ] || [ "$BENCHMARK" == "netperf-latency-tcp" ]; then
  # Iperf3 and netperf benchmarks operate in a client-server model
  # Using IP of petriHPC2 just to avoid trouble with name resolution
  TEST_SERVER=10.10.41.11
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

  START_MILLIS=$(date +%s%N | cut -b1-13) # used function parseLogFile to measure delay of workload start
  export START_MILLIS
  # HPK kubernetes cluster is used
  # Store stdout and stderr in file, but keep console output. Source: https://unix.stackexchange.com/a/362452
  /bin/bash "$PWD/benchmark/hpk/workload-$BENCHMARK.sh"  2>&1 | tee "$fileLog"

  parseLogFile "$fileLog" >> "$fileResult" || (echo "Failed to parse log file. No benchmark found for '$BENCHMARK'" >&2 && exit 1)

  # Give resources some time to recover - e.g. CPU to cool down (fair for comparison with other projects that have greater startup time)
  sleep 5
done

# Clean up temporary files
[ -d "/tmp/fio-bench" ] && rm -rf /tmp/fio-bench/* || (echo "Failed to delete temporary files in directory tmp" >&2 && exit 1)
rm -rf /nfs/workloads/$PROJECT/tmp/* || (echo "Failed to delete temporary files in directory tmp" >&2 && exit 1)
