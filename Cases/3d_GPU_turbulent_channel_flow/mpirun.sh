#!/bin/bash

outdir=job.output.$SLURM_JOB_ID
mkdir -p $outdir
exec >$outdir/stdout.log 2>$outdir/stderr.log

export RUNNER_SCRIPT_DEFAULT_BINARY=$1
shift
export RUNNER_SCRIPT_DEFAULT_ARGS="$*"
export OMP_NUM_THREADS=1

[ "$(which mpirun)" != "/apps/ACC/NVIDIA-HPC-SDK/26.5/Linux_x86_64/26.5/comm_libs/mpi/bin/mpirun" ] && { echo "FATAL: wrong mpirun"; exit 1; }

mpirun -x OMP_NUM_THREADS -x PATH -x LD_LIBRARY_PATH --bind-to none -np $NP --map-by ppr:$PPN:node --output-filename $outdir/mpi.out.$SLURM_JOB_ID ./runner-script.sh 
