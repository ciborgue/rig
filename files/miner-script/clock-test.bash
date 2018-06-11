#!/bin/bash

( cd ~/amdtweak ; ./amdtweak --card $1 --read-card-pp \
    --set MemClockDependencyTable.Entries[2].MemClock=$2 \
    --set MemClockDependencyTable.Entries[2].Vddc=$3 \
    --write-card-pp )
