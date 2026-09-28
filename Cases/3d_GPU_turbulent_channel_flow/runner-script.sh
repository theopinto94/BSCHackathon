#!/bin/bash

USE_ENV_TO_GET_NODE_LOCAL_INFO=OMPI
#USE_ENV_TO_GET_NODE_LOCAL_INFO=SLURM

case "$USE_ENV_TO_GET_NODE_LOCAL_INFO" in
OMPI)    [ -v OMPI_COMM_WORLD_LOCAL_RANK ] || { echo "AFFINITY: OMPI_COMM_WORLD_LOCAL_RANK is not defined, are we running under HPCX MPI?"; exit 1; }
         [ -v OMPI_COMM_WORLD_RANK ] || { echo "AFFINITY: OMPI_COMM_WORLD_RANK is not defined, are we running under HPCX MPI?"; exit 1; }
         [ -v OMPI_COMM_WORLD_LOCAL_SIZE ] || { echo "AFFINITY: OMPI_COMM_WORLD_LOCAL_SIZE is not defined, are we running under HPCX MPI?"; exit 1; }
         ;;
SLURM)   [ -v SLURM_LOCALID ] || { echo "AFFINITY: SLURM_LOCALID is not defined, are we running under SLURM?"; exit 1; }
         [ -v SLURM_PROCID ] || { echo "AFFINITY: SLURM_PROCID is not defined, are we running under SLURM?"; exit 1; }
         [ -v SLURM_NTASKS_PER_NODE ] || { echo "AFFINITY: SLURM_NTASKS_PER_NODE is not defined, are we running under SLURM?"; exit 1; }
         ;;
esac

#-- Definition of BINARY and ARGS variables
if [ -v BINARY ]; then
    [ ! -z "$BINARY" -a ! -z "$1" -a "$BINARY" != "$1" ] && { echo "FATAL: runner-script.sh: can't handle different binary names from different sources: BINARY env. and an argument."; exit 1; }
    [ -z "$BINARY" ] && BINARY="$RUNNER_SCRIPT_DEFAULT_BINARY"
else
    BINARY="$RUNNER_SCRIPT_DEFAULT_BINARY"
fi
[ -z "$1" ] || { BINARY="$1"; shift; }

firstletter=${BINARY:0:1}
if [ "$firstletter" != "." -a "$firstletter" != "/" -a -e "$BINARY" ]; then
    [ $(realpath "./$BINARY") == $(realpath "$BINARY") ] && BINARY="./$BINARY"
fi

# uncomment for verbose debugging
#printenv >& PRINTENV.$(basename $BINARY).$SLURM_JOBID.$OMPI_COMM_WORLD_RANK
#exec 1>AFFINITY.$(basename $BINARY).$SLURM_JOBID.$OMPI_COMM_WORLD_RANK
#exec 2>&1
#set -x

ARGS="$*"
[ -z "$ARGS" ] && ARGS="$RUNNER_SCRIPT_DEFAULT_ARGS"
##-- End of definition of BINARY and ARGS variables

omit_numactl=0
omit_nvidia_mps=1

case "$USE_ENV_TO_GET_NODE_LOCAL_INFO" in
OMPI)
        export local_rank=$OMPI_COMM_WORLD_LOCAL_RANK
        export global_rank=$OMPI_COMM_WORLD_RANK
        export local_ppn=$OMPI_COMM_WORLD_LOCAL_SIZE
        export local_ngpus=$(nvidia-smi -L | awk -F'[ :()]' '/^GPU/ {g[$2]=$9} END{for (i in g) print g[i]}' | wc -l)
        ;;
SLURM)  
        export local_rank=$SLURM_LOCALID
        export global_rank=$SLURM_PROCID
        export local_ppn=$SLURM_NTASKS_PER_NODE
        export local_ngpus=$SLURM_GPUS_ON_NODE
        ;;
esac

if [ -v SLURM_GPUS_ON_NODE ]; then
    [ "$local_ngpus" == "$SLURM_GPUS_ON_NODE" ] ||  { echo "AFFINITY: local_ngpus!=SLURM_GPUS_ON_NODE -- wrong SLURM allocation options (nvidia-smi: $local_ngpus; SLURM_GPUS_ON_NODE: $SLURM_GPUS_ON_NODE)?"; exit 1; }
fi
[ "$local_ngpus" == "0" ] &&  { echo "AFFINITY: local_ngpus=0: the SLURM_GPUS_ON_NODE=$SLURM_GPUS_ON_NODE -- no gpus in the SLURM allocation?"; exit 1; }

# Fill in the "threads for rank" array
threads=()
ncrs=20
nsckts=4
case "$local_ppn" in
1|2|4)   for _ in $(seq "$local_ppn"); do 
             threads+=($ncrs); 
         done
         ;;
8|16|20|32|40|80) thrds=$(($ncrs * $nsckts / "$local_ppn")); 
         for _ in $(seq "$local_ppn"); do 
             threads+=($thrds); 
         done; 
         omit_nvidia_mps=0   # NOTE: we switch on MPS usage here
         ;;
0)       echo -ne "AFFINITY: ppn=0 detected: SLURM_NPROCS=$SLURM_NPROCS, "
         echo -ne "SLURM_JOB_NUM_NODES=$SLURM_JOB_NUM_NODES, "
         echo -ne "OMPI_COMM_WORLD_LOCAL_SIZE=$OMPI_COMM_WORLD_LOCAL_SIZE"
         echo -ne "\n"
         printenv | grep SLURM_
         exit 1
         ;;
*)       [ "$local_ppn" -gt "$local_ngpus" ] && omit_nvidia_mps=0 # NOTE: we switch on MPS usage here
         echo "AFFINITY: due to selected ppn, we omit pinning with numactl! ppn=$local_ppn"
         omit_numactl=1
         ;;
esac

# Fill in the "physical cores per rank" array based on threads() array
physcores=()
sum=0
for i in "${threads[@]}"; do
    j=$(echo "${sum}-$(($sum + $i - 1))")
    physcores+=($j)
    sum=$(($sum + $i))
done

# Fill in the NICs array
nics=(mlx5_0:1 mlx5_1:1 mlx5_4:1 mlx5_5:1)

# Which GPU device is local to us?
divider=$(("$local_ppn" / "$local_ngpus"))
[ "$divider" == "0" ] && divider=1
local_device_id=$(($local_rank / $divider))

# OpenMP settings
export OMP_PROC_BIND=close
export OMP_PLACES=cores
nthr=1
[ -v threads ] && nthr=${threads[$local_rank]}
if [ "$omit_numactl" == 0 ]; then
    [ -z "$OMP_NUM_THREADS" ] && export OMP_NUM_THREADS=$nthr
    [ ! -z "$OMP_NUM_THREADS" -a "$OMP_NUM_THREADS" -gt "$nthr" ] && echo "AFFINITY: WARNING: OMP_NUM_THREADS>$nthr with ppn=$local_ppn may lead to oversubscription"
fi

# NOTE: this is for manually built UCX
#export DNB_UCX_INSTALL_PATH=/gpfs/projects/bsc32/DE340-share/NVIDIA/ucx
#export LD_LIBRARY_PATH=$DNB_UCX_INSTALL_PATH/lib/:$LD_LIBRARY_PATH
#export PATH=$DNB_UCX_INSTALL_PATH/bin:$PATH
#
#ucx_info -v | head
#export UCX_PROTO_ENABLE=y
#export UCX_PROTO_INFO=y
#
# Get some info
#export UCX_LOG_LEVEL=info
#
# Get verbose debug logs
#export UCX_LOG_LEVEL=debug
#export UCX_MODULE_LOG_LEVEL=debug
#
# Here we kick out the cuda_ipc transport:
#export UCX_TLS=rc,self,sm,gdr_copy,cuda_copy
#export UCX_TLS=^cuda_ipc
#
# export UCX_MEMTYPE_CACHE=n

# Assorted environment variables
export CUDA_VISIBLE_DEVICES="$local_device_id"
export UCX_NET_DEVICES="${nics[$local_device_id]}"
# TODO: to check if this UCX_CUDA_COPY_DMABUF=no is needed
[ -v PROFILE ] || export UCX_CUDA_COPY_DMABUF=no
export NVCOMPILER_ACC_DEFER_UPLOADS=${NVCOMPILER_ACC_DEFER_UPLOADS:-1}
#export NVCOMPILER_ACC_NO_MEMHINTS=${NVCOMPILER_ACC_NO_MEMHINTS:-1}
export OMPI_MCA_coll_ucc_enable=0
export OMPI_MCA_coll_hcoll_enable=0
export OMPI_MCA_pml=ucx
export OMPI_MCA_btl="^vader,tcp,openib,smcuda"
export NVCOMPILER_ACC_USE_GRAPH=1
export NVCOMPILER_ACC_SYNCHRONOUS=${NVCOMPILER_ACC_SYNCHRONOUS:-0}
# export NV_ACC_NOTIFY=3


function stop-nvidia-mps() {
  [ "$local_rank" == 0 -a "$omit_nvidia_mps" == 0 ] && sleep 5 && echo quit | nvidia-cuda-mps-control || true
}

function kill-nvidia-mps() {
    if pgrep nvidia-cuda-mps >& /dev/null; then
        [ "$local_rank" == 0 ] && echo quit | nvidia-cuda-mps-control || true
        sleep 5
        [ "$local_rank" == 0 ] && killall nvidia-cuda-mps 2>/dev/null || true
        timeout 10 bash -c 'while pgrep nvidia-cuda-mps >/dev/null; do sleep 0.5; done' || true
    fi
}

function start-nvidia-mps() {
    [ "$local_rank" == 0 -a "$omit_nvidia_mps" == 0 ] && env -u CUDA_VISIBLE_DEVICES nvidia-cuda-mps-control -d || true
    [ "$local_rank" != 0 -a "$omit_nvidia_mps" == 0 ] && timeout 20 bash -c 'until pgrep nvidia-cuda-mps >/dev/null; do sleep 0.5; done'
}

export CUDA_MPS_LOG_DIRECTORY=$PWD
kill-nvidia-mps
trap stop-nvidia-mps EXIT
start-nvidia-mps

numactlline=""
[ "$omit_numactl" == 0 ] && numactlline="numactl -l --all --physcpubind=${physcores[$local_rank]} --"

if [ -v PROFILE ]; then
    export PROFILE
    [ "$global_rank" == 0 ] && echo ">> runner-script.sh: executing: $numactlline ./profiling-wrapper.sh $BINARY $ARGS"
    $numactlline ./profiling-wrapper.sh $BINARY $ARGS
else
    [ "$global_rank" == 0 ] && echo ">> runner-script.sh: executing: $numactlline $BINARY $ARGS"
#    [ "$global_rank" == 0 ] && echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
#    [ "$global_rank" == 0 ] && echo -ne ">> runner-script.sh: ldd:\n$(ldd $BINARY)\n"
    $numactlline $BINARY $ARGS
fi

