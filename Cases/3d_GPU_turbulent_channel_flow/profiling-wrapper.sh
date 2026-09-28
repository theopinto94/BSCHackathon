#!/bin/bash

set -euo pipefail

function is_set() {
    local varname=$1
    set +u
    [ -z "${!varname}" -o "${!varname}" == 0 -o "${!varname}" == false -o "${!varname}" == FALSE ] && return 1
    set -u
    return 0
}

function get_field() {
    local str="$1"
    local n="$2"
    set +u
    local delim="$3"
    set -u
    [ -z "$delim" ] && delim=":"
    echo "$str$delim" | cut -d$delim -f$n -s
}

is_set PROFILE || { echo "FATAL: PROFILE environment variable must be set"; exit 1; }

# NOTE: this is OpenMPI-specific, change this for MPICH-based MPIs
local_rank=$OMPI_COMM_WORLD_LOCAL_RANK
global_rank=$OMPI_COMM_WORLD_RANK

outdir="profiling.${PSUBMIT_JOBID}"
name="report"
# nsys profile -t cuda,nvtx,mpi -s none -f true -o out-$grank.nsys-rep $@
profiler="nsys profile"
limited_scope="--capture-range=cudaProfilerApi --capture-range-end=stop"
traceopts="--trace cuda,nvtx,mpi,openacc,openmp -s none -f true -b none"
traceopts_graph="--cuda-graph-trace node"
traceopts_uvm="--cpuctxsw=none --cuda-um-cpu-page-faults true --cuda-um-gpu-page-faults true --event-sample=system-wide --cpu-socket-events=61,71,265,273 --cpu-socket-metrics=103,104 --event-sampling-interval=1 -e NSYS_MPI_STORE_TEAMS_PER_RANK=1"

option=$(get_field "$PROFILE" 1)
parameter=$(get_field "$PROFILE" 2)
parameter2=$(get_field "$PROFILE" 3)

case "$option" in
    valgrind)
        outdir="${outdir}/rank_${global_rank}"
        outfile="${name}_${global_rank}.valgrind"
        mkdir -p $outdir
        set -x
        exec valgrind $* 2>&1 >> ${outdir}/${outfile}
        ;;     
    memcheck)
        outdir="${outdir}/rank_${global_rank}"
        outfile="${name}_${global_rank}.cudamemcheck"
        mkdir -p $outdir
        set -x
        exec compute-sanitizer $* 2>&1 >> ${outdir}/${outfile}
        ;;     
    cuda-gdb) outdir="${outdir}/rank_${global_rank}"
        outfile="${name}_${global_rank}.gdb"
  	    mkdir -p $outdir
   	    [ "$global_rank" == 0 -a ! -f ../gdb.cmd ] && { echo "FATAL: no gdb.cmd"; exit 1; }
        [ "$global_rank" == 0 -a -f ../gdb.cmd -a ! -e gdb.cmd ] && cp ../gdb.cmd .
	    while [ ! -f gdb.cmd ]; do sleep 0.1; done
        echo "=== gdb.cmd: ===" > ${outdir}/${outfile} 
	    cat gdb.cmd >> ${outdir}/${outfile}
        echo "================" >> ${outdir}/${outfile}
	    [ "$global_rank" == 0 ] && echo "=== gdb.cmd: ===" && cat gdb.cmd && echo "================" && set -x
	    exec cuda-gdb -batch -x gdb.cmd --args $* 2>&1 >> ${outdir}/${outfile} 
	    ;;

    gdb) outdir="${outdir}/rank_${global_rank}"
        outfile="${name}_${global_rank}.gdb"
  	    mkdir -p $outdir
   	    [ "$global_rank" == 0 -a ! -f ../gdb.cmd ] && { echo "FATAL: no gdb.cmd"; exit 1; }
        [ "$global_rank" == 0 -a -f ../gdb.cmd -a ! -e gdb.cmd ] && cp ../gdb.cmd .
	    while [ ! -f gdb.cmd ]; do sleep 0.1; done
        echo "=== gdb.cmd: ===" > ${outdir}/${outfile} 
	    cat gdb.cmd >> ${outdir}/${outfile}
        echo "================" >> ${outdir}/${outfile}
	    [ "$global_rank" == 0 ] && echo "=== gdb.cmd: ===" && cat gdb.cmd && echo "================" && set -x
	    exec gdb -batch -x gdb.cmd --args $* 2>&1 >> ${outdir}/${outfile} 
	    ;;
    counters)  echo "FATAL: counters option is not supported."
        exit 1 
        ;;
    each-rank) outdir="${outdir}/rank_${global_rank}"
        outfile="${name}_${global_rank}.nsys"
        mkdir -p $outdir 
        exec ${profiler} ${traceopts} -o ${outdir}/${outfile} $*
        ;;
    only-selected-one) outfile=${name}.nsys
        selected="$parameter"
        extended_opts="$parameter2"
        [ -z "$selected" ] && selected=0
        traceropts_ext=""
        for eopt in $(echo $extended_opts | tr ',' ' '); do 
           case "$eopt" in
               uvm) traceropts_ext="$traceropts_ext $traceopts_uvm";;
               graph) traceropts_ext="$traceropts_ext $traceopts_graph";;
           esac
        done
        if [ "$global_rank" == "$selected" ]; then
            mkdir -p $outdir 
            exec ${profiler} ${traceopts} ${traceopts_ext} -o ${outdir}/${outfile} $*
        else
            exec $* 
        fi
        ;;
    bravas)
        echo "Profiling with BRAVAS.."
        BRAVAS_EXEC="./bravas.src/bravas/bravas.py"
        BRAVAS_VENV="./bravas.venv"

        # Check for a non-broken symlink to the venv, then activate if possible.
        if [ -L ${BRAVAS_VENV} ] && [ -e ${BRAVAS_VENV} ]; then
            echo "Activating venv.."
            source "$BRAVAS_VENV/bin/activate"
        else
            echo "No venv at '$BRAVAS_VENV', exiting.."
            exit 1
        fi

        # Check if BRAVAS is installed by simply checking if it returns a version.
        echo -e "\nPython version:"
        python --version
        echo -e "\nBRAVAS version:"
        python "$BRAVAS_EXEC" --version
        exit_code="$?"
        if [ "$exit_code" -ne 0 ]; then
            echo "FATAL: The BRAVAS version test exitted with non-zero code: $exit_code."
            exit $exit_code
        fi

        # Decide whether to profile or analyze.
        [ -z "$parameter" ] && { echo "FATAL: PROFILE variable: BRAVAS mode required (analyze|profile)"; exit 1; }
        mode="$parameter"

        # Profile binary with BRAVAS as specified in the config file.
        BRAVAS_CONFIG="bravas_config.yaml"
        exec python ${BRAVAS_EXEC} --log=INFO ${mode} ${BRAVAS_CONFIG}
        ;;
esac


#nsys nvprof --print-gpu-trace -f -o nvprof.${PSUBMIT_JOBID} $BINARY $*
###ncu -f -o report.${PSUBMIT_JOBID} --target-processes all $BINARY $*

