#!/bin/bash

# Check if the input file is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <inputs.txt>"
  exit 1
fi

input_file="$1"
i=0

# Read each line from the input file
while IFS= read -r line; do
  payload=$(echo "$line")
  echo $payload
  cast_cmd="cast calldata \"EvmAdvance(uint256,address,address,uint256,uint256,uint256,bytes)\" \
        0x0000000000000000000000000000000000000001 \
        0x0000000000000000000000000000000000000002 \
        0x0000000000000000000000000000000000000003 \
        0x0000000000000000000000000000000000000004 \
        0x0000000000000000000000000000000000000005 \
        0x000000000000000000000000000000000000000$i \
        0x$payload"
  eval $cast_cmd | xxd -r -p > "input-${i}.bin"
  i=$((i+1))
done < "$input_file"

echo "Conversion complete. Created $i binary files."