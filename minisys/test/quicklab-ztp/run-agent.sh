#!/bin/sh
# Retry the SZTP bootstrap sequence until StratoWeave serves it, then idle.
while true; do
    /opi-sztp-agent run \
        --bootstrap-url http://172.31.255.10/restconf/operations/ietf-sztp-bootstrap-server:get-bootstrapping-data \
        --serial-number first-serial-number && break
    sleep 10
done
sleep infinity
