#!/bin/sh
#node_url='https://eu01-node.teztools.net'
node_url='https://teznode.letzbake.com'
tmp_file=/tmp/last_block.json.tmp
prev_time=''

while true
do
  time {
  cur_time=$(wget -q --no-cookies --no-check-certificate -T 9 \
    -O - $node_url/monitor/bootstrapped | jq -r '.timestamp')
  
  [ "$prev_time" == "$cur_time" ] && { sleep 2; continue; }
  echo "new block!"
  time wget -q --no-cookies --no-check-certificate -T 9 \
    -O $tmp_file $node_url/chains/main/blocks/head || continue

  #last_level=$(jq '.header.level' $tmp_file)
  echo "prepearing"
  time jq -r '.operations[] | .[] | .contents[]' $tmp_file | jq -s '.' > /tmp/last_block.tmp && {
    echo "getting objkt swaps"
    time jq -r '.[] | select(.parameters != null and .parameters.entrypoint == "ask" and .parameters.value.args[0].args[1].args[0].string == .source)| "objkt_swap \(.source) \(.metadata.operation_result.big_map_diff[0].key.int) \(.parameters.value.args[1].args[0].int) \((.parameters.value.args[1].args[1].args[0].int|tonumber)/1000000) \(.parameters.value.args[0].args[0].int)"' /tmp/last_block.tmp > /tmp/tz_operations.last
    
    echo "getting objkt mints"
    time jq -r '.[] | select(.parameters != null and .parameters.entrypoint == "mint_artist")| "objkt_mint \(.source) \(.metadata.internal_operation_results[0].parameters.value.args[1].args[1].int) \(.parameters.value.args[0].args[1].int) \(.parameters.value.args[0].args[0].int)"' /tmp/last_block.tmp >> /tmp/tz_operations.last
    
    echo "getting auctions"
    time jq -r '.[] | select(.parameters != null and .parameters.entrypoint == "create_auction") | "objkt_auct \(.source)"' /tmp/last_block.tmp >> /tmp/tz_operations.last
    #time jq -r '.[] | select(.parameters != null and .parameters.entrypoint == "create_auction" and .parameters.value.args[0].args[1].args[0].string == .source)| "objkt_auct \(.source)"' /tmp/last_block.tmp >> /tmp/tz_operations.last

    echo "getting swaps"
    time jq -r '.[] | select(.parameters != null and .parameters.entrypoint == "swap" and .destination == "KT1HbQepzV1nVGg8QVznG7z4RcHseD5kwqBn")| "swap \(.source) \(.metadata.operation_result.big_map_diff[0].key.int) \(.metadata.operation_result.big_map_diff[0].value[1].int) \((.metadata.operation_result.big_map_diff[0].value[3].int|tonumber)/1000000) \(.parameters.value.args[0].args[1].int)"' /tmp/last_block.tmp >> /tmp/tz_operations.last

    echo "getting mints"
    time jq -r '.[] | select(.parameters != null and .parameters.entrypoint == "mint_OBJKT") | "mint \(.parameters.value.args[0].args[0].string) \(.metadata.operation_result.big_map_diff[0].key.int) \(.parameters.value.args[0].args[1].int)"' /tmp/last_block.tmp >> /tmp/tz_operations.last
    rm -f $tmp_file
    rm -f /tmp/last_block.tmp
    prev_time=$cur_time
    echo "$(date --utc) : $cur_time"
  } 

  }
done
