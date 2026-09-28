#!/bin/bash

nfiles_by_mask() {
    local mask="$1"
    ls -1 $mask 2>/dev/null | wc -l
}

success=true

[ -f 3d_GPU_turbulent_channel_flow_${NSTEPS}.h5 ] || success=false
#-- [ -f timers_information_file.txt ] || success=false
pswrpout=../psubmit_wrapper_output.${PSUBMIT_JOBID}
laststep=$(grep 'Time advancement completed -> iteration = [0-9]*,' $pswrpout | tr ',' ' ' | awk '{print $7}')
[ -z "$laststep" ] && laststep=0
[ "$laststep" == 0 ] && success=false

echo "---" > result.${PSUBMIT_JOBID}.yaml
echo "execution:" >> result.${PSUBMIT_JOBID}.yaml
echo "    success: $success" >> result.${PSUBMIT_JOBID}.yaml
echo "    laststep: $laststep" >> result.${PSUBMIT_JOBID}.yaml

if [ -f timers_information_file.txt ]; then
    echo "timing:" >> result.${PSUBMIT_JOBID}.yaml
    echo "    elapsed_time:" >> result.${PSUBMIT_JOBID}.yaml
    cat timers_information_file.txt | awk -F'[ :]' '/^Timer : / {timer=$4; on=1;} on && /^----/ {on++;} on==2 && /Accum. Time Max/ {print "        " timer ": " int($5*1000000); on=0 }' >> result.${PSUBMIT_JOBID}.yaml
fi

if [ "$(nfiles_by_mask *_*.h5)" != 0 ]; then
    echo "model:" >> result.${PSUBMIT_JOBID}.yaml
    for i in *_*.h5; do
        step=$(awk -F '[_.]' '{ x=NF-1; print $x; }' <<< $i)
        if [ "$step" != 0 -a $(nfiles_by_mask ../gold/*_${step}.h5) == 1 ]; then
            ok=false
            h5diff ../gold/*_${step}.h5 $i >& /dev/null && ok=true
            echo "    $step: $ok" >> result.${PSUBMIT_JOBID}.yaml
        fi 
    done
fi

echo "..." >> result.${PSUBMIT_JOBID}.yaml

# We don't submit the result.yaml if we understand that program didn't even run
# This will be shown as a NORES state as a test result in the automated test suite
if [ "$(nfiles_by_mask *.h5)" != 0 ]; then
    mv result.${PSUBMIT_JOBID}.yaml ..
else
    rm result.${PSUBMIT_JOBID}.yaml
fi

FILES="*.h5 *.xdmf timers_information_file.txt"
for i in $FILES; do
    [ -e $i ] && mv -f $i ../${i}.${PSUBMIT_JOBID}
done
if [ "$(nfiles_by_mask *${PSUBMIT_JOBID}*)" != 0 ]; then
    for i in *${PSUBMIT_JOBID}*; do
        [ -e ../$i ] || mv $i ..
    done
fi

cd ..
if [ -v RHEA_KEEP_TESTBED ]; then
    if [ -z "$RHEA_KEEP_TESTBED" -o "$RHEA_KEEP_TESTBED" == "false" -o "$RHEA_KEEP_TESTBED" == "FALSE" ]; then
        rm -rf ${RHEA_TESTBED_DIR}
    else
    mv ${RHEA_TESTBED_DIR} ${RHEA_TESTBED_DIR}.${PSUBMIT_JOBID}
    fi
else
    rm -rf ${RHEA_TESTBED_DIR}
fi

pswrpout=psubmit_wrapper_output.${PSUBMIT_JOBID}
grep -q 'RHEA (v9.0.0): END SIMULATION' $pswrpout || success=false
if [ -f $pswrpout ]; then
    if grep -q 'Caught signal' $pswrpout; then
        cat $pswrpout | awk '/==== backtrace \(/ && start == 1 { start=2; } /======/{print; start=0} /Caught signal/ {print ">> STATUS: CRASH"; print; start=1} start==2{print}' > stacktrace.${PSUBMIT_JOBID}
    fi
    if grep -q 'Accelerator Fatal Error:' $pswrpout; then
        cat $pswrpout | awk '/Accelerator Fatal Error:/ { if (crash==0) print ">> STATUS: CRASH"; crash++; start=1; } /^ Line:/ && start==1 {print; print ""; start=0} start==1{print}' > stacktrace.${PSUBMIT_JOBID}
    fi
    if grep -q '>> STATUS: ASSERT' $pswrpout; then
        echo ">> STATUS: ASSERT" > stacktrace.${PSUBMIT_JOBID}
    fi
    if [ "$(nfiles_by_mask err.${PSUBMIT_JOBID}.*)" != "0" ]; then
       if grep -q 'line [0-9]*:[ \t]*[0-9]*[ \t]*Segmentation fault[ \t]*(core dumped)' err.${PSUBMIT_JOBID}.*; then
           echo ">> STATUS: CRASH" >> stacktrace.${PSUBMIT_JOBID}
       fi
       if grep -q 'Memory access fault by GPU' err.${PSUBMIT_JOBID}.*; then
           echo ">> STATUS: CRASH" >> stacktrace.${PSUBMIT_JOBID}
       fi
    fi
fi

[ -f stacktrace.${PSUBMIT_JOBID} ] && success=false

if [ "$success" == "false" ]; then
    sed -i 's/success: true/success: false/' result.${PSUBMIT_JOBID}.yaml
fi

