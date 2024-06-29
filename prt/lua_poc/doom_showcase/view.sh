#!/usr/bin/env bash
set -euo pipefail

cd snapshots
snapshot_count=0
while true
do
    snapshot_files=($( ls -dtr -1 * || echo "" ))
    new_snapshot_count=${#snapshot_files[@]}
    if [ "$snapshot_count" -ne "$new_snapshot_count" ] &&
    [ -d "${snapshot_files[snapshot_count]}/pixels" ]; then
        cd ${snapshot_files[snapshot_count]}/pixels
        while true
        do
            if [ -f "done" ]; then
                mplayer -mf fps=30 -x 640 -y 400 -geometry 50%:50% 'mf://*.png'
                break
            else
                mplayer -mf fps=30 -x 640 -y 400 -geometry 50%:50% 'mf://*.png'
            fi
        done
        log2_stride=($( cat ../log2_stride ))
        if [ "$log2_stride" == "0" ];then
            # dave process reaches its leaf tournament when log2_stride is 0
            break
        fi
        snapshot_count=$((snapshot_count+1))
        cd -
    fi
    sleep 10
done
