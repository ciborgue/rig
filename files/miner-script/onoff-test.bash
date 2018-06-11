#!/bin/bash

cat <<EOF | nc localhost 3333
{"id":"0","jsonrpc":"2.0","method":"control_gpu","params":["$1","$2"]}
EOF
