#!/bin/bash

dd if=/sys/kernel/debug/dri/$1/amdgpu_vbios count=1 status=none | strings
