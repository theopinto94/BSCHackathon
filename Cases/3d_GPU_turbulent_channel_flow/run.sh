#!/bin/bash

module load nvidia-hpc-sdk/26.5 hdf5/1.14.1-2-nvidia-nvhpc yaml-cpp

NNODES=$1
export NNODES=${NNODES:=1}
export PPN=4
export NP=$(($NNODES * $PPN))

sbatch -J RHEA_test --exclusive --time=10 --qos=acc_debug --gres=gpu:4 --account=bsc32 -D $PWD -N $NNODES -n $NP mpirun.sh BSCH_3D_GPU.exe configuration_file.yaml
