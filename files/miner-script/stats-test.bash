#!/bin/bash

wget -qO - localhost:3333 | grep ETH: | grep Mh
