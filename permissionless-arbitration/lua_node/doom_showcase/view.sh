#!/bin/bash
cd snapshots
snapshot_count=0
while true
do
    snapshot_files=($( ls -dtr -1 * ))
    new_snapshot_count=${#snapshot_files[@]}
    # echo $new_snapshot_count
    if [ "$snapshot_count" -ne "$new_snapshot_count" ]; then
        cd ${snapshot_files[snapshot_count]}/pixels
        while true
        do
            if [ ! -f "done" ]; then
                mplayer -mf fps=30 -x 640 -y 400 -geometry 50%:50% 'mf://*.png'
            else
                mplayer -mf fps=30 -x 640 -y 400 -geometry 50%:50% 'mf://*.png'
                break
            fi
        done
        snapshot_count=$((snapshot_count+1))
        cd -
    fi
    sleep 10
done
