#!/bin/bash

ncat 127.0.0.1 3333 <<EOF
{"id":0,"jsonrpc":"2.0","method":"control_gpu","params":["$1","$2"]}
{"id":0,"jsonrpc":"2.0","method":"miner_getstat2"}
EOF
