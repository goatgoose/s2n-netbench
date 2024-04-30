#!/usr/bin/env bash
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#

# immediately exit if an error occurs.
set -e

ARTIFACT_FOLDER="target/release"
NETBENCH_ARTIFACT_FOLDER="target/s2n-netbench"

# the run_trial function will run the request-response scenario
# with the driver passed in as the first argument
run_trial() {
    # e.g. request-response
    SCENARIO=$1

    S2N_VERSION=$2
    # e.g. s2n-quic
    DRIVER=s2n-tls-$S2N_VERSION
    echo "running the $SCENARIO scenario with $DRIVER"

    cp netbench-driver-s2n-tls/Cargo.toml.$S2N_VERSION netbench-driver-s2n-tls/Cargo.toml 
    cargo build --profile=bench

    # make a directory to hold the collected statistics
    mkdir -p $NETBENCH_ARTIFACT_FOLDER/results/$SCENARIO/$DRIVER

    # run the server while collecting metrics.
    echo "  running the server"
    ./$ARTIFACT_FOLDER/s2n-netbench-collector \
    ./$ARTIFACT_FOLDER/s2n-netbench-driver-server-$DRIVER \
    --scenario ./$NETBENCH_ARTIFACT_FOLDER/$SCENARIO.json \
    > $NETBENCH_ARTIFACT_FOLDER/results/$SCENARIO/$DRIVER/server.json &
    # store the server process PID. $! is the most recently spawned child pid
    SERVER_PID=$!

    # sleep for a small amount of time to allow the server to startup before the
    # client
    sleep 1

    # run the client. Port 4433 is the default for the server.
    echo "  running the client"
    SERVER_0=localhost:4433 ./$ARTIFACT_FOLDER/s2n-netbench-collector \
     ./$ARTIFACT_FOLDER/s2n-netbench-driver-client-$DRIVER \
     --scenario ./$NETBENCH_ARTIFACT_FOLDER/$SCENARIO.json \
     > $NETBENCH_ARTIFACT_FOLDER/results/$SCENARIO/$DRIVER/client.json

    # cleanup server processes. The collector PID (which is the parent) is stored in
    # SERVER_PID. The collector forks the driver process. The following incantation
    # kills the child processes as well.
    echo "  killing the server"
    kill $(ps -o pid= --ppid $SERVER_PID)

    sleep 2

    echo "generate flamegraph"
    echo "  running the server"
    TRACE="disabled" \
    SCENARIO=./$NETBENCH_ARTIFACT_FOLDER/$SCENARIO.json \
      ./$ARTIFACT_FOLDER/s2n-netbench-driver-server-$DRIVER &
    SERVER_PID=$!

    flamegraph \
      -o $NETBENCH_ARTIFACT_FOLDER/results/$SCENARIO/$DRIVER/server_flamegraph.svg \
      --pid $SERVER_PID \
      --skip-after s2n_netbench* &

    sleep 1

    echo "  running the client"
    TRACE="disabled" \
    SCENARIO=./$NETBENCH_ARTIFACT_FOLDER/$SCENARIO.json \
    SERVER_0=localhost:4433 \
      ./$ARTIFACT_FOLDER/s2n-netbench-driver-client-$DRIVER

    echo "  killing the server"
    kill $SERVER_PID
}

git restore netbench-driver-s2n-tls/Cargo.toml

# build all tools in the netbench workspace
cargo build --profile=bench

# generate the scenario files. This will generate .json files that can be found
# in the netbench/target/netbench directory. Config for all scenarios is done
# through this binary.
./$ARTIFACT_FOLDER/s2n-netbench-scenarios --request_response.response_size=8GiB --connect.connections 42

run_trial request_response main
run_trial request_response fork

echo "generating the report"
./$ARTIFACT_FOLDER/s2n-netbench report-tree $NETBENCH_ARTIFACT_FOLDER/results $NETBENCH_ARTIFACT_FOLDER/report
