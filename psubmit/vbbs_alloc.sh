#!/bin/bash

echo 0 > .jobid
psubmit.sh -n1 -lnodetype=acc_debug:batch=slurm:time=30 -a ./sleep.sh >& /dev/null &
while true; do export SLURM_JOBID=$(cat .jobid); if [ ! -z "${SLURM_JOBID}" -a "${SLURM_JOBID}" != 0 ]; then break; fi; sleep 1; done
nodelist=$(squeue --Format="NodeList:2000" --noheader -j "${SLURM_JOBID}" | tail -n1 | awk '{print $1}')
export SLURM_NODELIST=$nodelist
[ -v VBBS_PARAMS ] || export VBBS_PARAMS=$HOME/vbbs_hostfile
vbbs slurm_init 111 || fatal "error in slurm reservation handling: vbbs command failed."
echo ok
wait
