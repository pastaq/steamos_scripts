#!/bin/bash
SPL=${1:-35}
SPPT=${2:-40}
FPPT=${3:-45}

SYS="/sys/class/firmware-attributes/msi-wmi-platform/attributes"

# Clamp values according to DLL limits
[ $SPL -gt 35 ] && SPL=35
[ $SPPT -gt 50 ] && SPPT=50
[ $FPPT -gt 60 ] && FPPT=60

# 1. Step down to firmware floor targets
echo 7 | sudo tee $SYS/ppt_pl1_spl/current_value > /dev/null
echo 9 | sudo tee $SYS/ppt_pl2_sppt/current_value > /dev/null

# 2. Apply actual targets in order
echo $FPPT | sudo tee $SYS/ppt_pl3_fppt/current_value > /dev/null
echo $SPPT | sudo tee $SYS/ppt_pl2_sppt/current_value > /dev/null
echo $SPL  | sudo tee $SYS/ppt_pl1_spl/current_value > /dev/null

echo "Applied MSI AMD Limits: SPL=$SPL, SPPT=$SPPT, FPPT=$FPPT"
