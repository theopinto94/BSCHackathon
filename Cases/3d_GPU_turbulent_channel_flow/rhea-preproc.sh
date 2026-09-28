#!/bin/bash

CONF="configuration_file.yaml"

export RUNNER_SCRIPT_DEFAULT_BINARY="BSCH_3D_GPU.exe"
export RUNNER_SCRIPT_DEFAULT_ARGS="$CONF"

binary=$RUNNER_SCRIPT_DEFAULT_BINARY

RHEA_TESTBED_DIR=rhea_testbed_${PSUBMIT_JOBID}

[ -d "$RHEA_TESTBED_DIR" ] && rm -rf "$RHEA_TESTBED_DIR"
mkdir -p $RHEA_TESTBED_DIR
RHEA_EXE_FILES=$(ls -1d *.sh $binary gdb.cmd hostfile.${PSUBMIT_JOBID} 2>/dev/null)
for i in ${RHEA_EXE_FILES}; do
    [ -e $i ] && ln -sf ../$i ${RHEA_TESTBED_DIR}
done
RHEA_INPUT_FILES=$(ls -1d $CONF 2>/dev/null)
for i in ${RHEA_INPUT_FILES}; do
    [ -e $i ] && ln -sf ../$i ${RHEA_TESTBED_DIR}
done

cd ${RHEA_TESTBED_DIR}

# Handling NSTEPS variable
[ -z "$NSTEPS" ] && NSTEPS=10

replace_yaml_block() {
  local file="$1"
  local block_name="$2"
  local replacement="$3"
  #--
  sed -i -E "s/^([[:space:]]*${block_name}:[[:space:]]*).*/\1${replacement}/" $file
  return 0
}

replace_yaml_block $(basename $CONF) "final_time_iter" "$NSTEPS"
# NOTE: with print_timers set to true, we seem to have sigsegv
#replace_yaml_block $(basename $CONF) "print_timers" "\'TRUE\'"

export OMP_NUM_THREADS=$PSUBMIT_NTH

