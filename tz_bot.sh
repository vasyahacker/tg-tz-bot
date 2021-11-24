#!/usr/bin/env bash

SELF_NAME=$(basename "$0")
DB_DIR="db_${SELF_NAME}"

log(){
 echo "$(date +'%z %x %R:%S') [$SELF_NAME]: $1" | tee -a ${DB_DIR}/log.txt
}

echo "$SELF_NAME starting..."
TG_TOK_FILE="./${SELF_NAME}.tg.token"
[ ! -e $TG_TOK_FILE ] && {
    log "[Error] can't open $TG_TOK_FILE"
    exit 1
}
TOKEN="$(<${TG_TOK_FILE})"
TG_SEND_URL="https://api.telegram.org/bot$TOKEN/sendMessage"
TG_DEL_URL="https://api.telegram.org/bot$TOKEN/deleteMessage"
TG_GET_URL="https://api.telegram.org/bot$TOKEN/getUpdates"
MIN_FEE="0.003"
TZCLIENT=/opt/tgbot/tezos-client

export TEZOS_CLIENT_UNSAFE_DISABLE_DISCLAIMER=yes

[ ! -e $DB_DIR ] && mkdir -p $DB_DIR

get(){
  echo $(( $(date +%s) - $(stat -f%c myfile.txt) ))
  curl -s

}

tg_del(){
  local chatid="$1"
  local message_id="$2"
  curl -s -X POST $TG_SEND_URL -d chat_id=${chatid} -d message_id="${message_id}" > /dev/null 2>&1
}

tg_send(){
  local message="$1"
  local chatid="$2"
#  local keyboard="$3"
#  [ -n "$keyboadr" ] && keyboard="-d reply_markup='$3'"

  curl -s -X POST $TG_SEND_URL -d chat_id=${chatid} -d text="${message}" -d parse_mode="HTML" > /dev/null 2>&1
}

tg_send_file(){
  chatid=$1
  file_path=$2
  curl -s -F document=@"$file_path" https://api.telegram.org/bot${TOKEN}/sendDocument?chat_id=${chatid} > /dev/null 2>&1
}

tg_bot() {
  local tlu_file="${DB_DIR}/tg_last_update"
  local TG_UPDATE_ID
  #local dir
  [ -e $tlu_file ] && TG_UPDATE_ID="$(<${tlu_file})"
  [ -z "$TG_UPDATE_ID" ] && TG_UPDATE_ID=0
  while true
  do
      while read -r update_id tg_user_id mess
      do
        [ -z "${tg_user_id}" ] && continue
        [ -z "${mess}" ] && continue
        [ -z "${update_id}" ] && continue
        [ "${update_id}" -le "${TG_UPDATE_ID}" ] && continue
        local hdir="${DB_DIR}/${tg_user_id}"
        [ ! -d $hdir ] && continue

        TG_UPDATE_ID="${update_id}"

        log "[Info] $tg_user_id: $mess"

        [ "${mess}" == "/start" ] && {
          tg_send "Welcome! Try /add [tez addr] [owner name]" "${tg_user_id}"
          continue
        }

        [ "${mess}" == "/get_log" ] && {
          tg_send_file $tg_user_id "${DB_DIR}/log.txt"
          rm -f ${DB_DIR}/log.txt

          continue
        }

        [ "${mess}" == "/list" ] && {
          local list="$(find ${hdir} -mindepth 1 -maxdepth 1 -type d -execdir printf "%s\n" {} \;|tr -d './')"
          local send_list=""
          local anums=0
          for addr in ${list}
          do
            [ "$addr" == "tokens" ] && continue
            send_list="$(printf "%s\n<b>%s</b>: %s\n" "$send_list" "$(cat ${hdir}/${addr}/name)" "$addr")"
            ((anums++))
            [ $anums -ge 50 ] && {
              tg_send "$send_list" "${tg_user_id}"
              send_list=""
              anums=0
            }
          done
          [ $anums -ge 1 ] && tg_send "$send_list" "${tg_user_id}"
          continue
        }

        local secret=$(expr "$mess" : "^/secret \(edsk[0-9a-zA-Z]*\)$")
        [ -n "$secret" ] && {
          new_addr="$($TZCLIENT import secret key $SELF_NAME unencrypted:${secret} -f | cut -d ':' -f 2 | tr -d ' ')"
          [ -n "$new_addr" ] && {
            printf "$new_addr" > ${hdir}/wallet1
            tg_send "Successful import of private key, current wallet is $new_addr" "$tg_user_id"
            true
          } || {
            tg_send "Error while import secret" "$tg_user_id"
          }
          continue
        }

       local node=$(expr "$mess" : "^/node \(http[s]\?://[^/]*\)$")
        [ -n "$node" ] && {
          WALLET1="$(<${hdir}/wallet1)"
          balance="$($TZCLIENT -E $node get balance for $WALLET1 | cut -d ' ' -f 1)"
          [ -n "$balance" ] && {
            printf "$node" > ${hdir}/tz_node
            tg_send "Now tezos public node is $node, your balance is: $balance" "$tg_user_id"
            true
          } || {
            tg_send "Error while cheking node" "$tg_user_id"
          }
          continue
        }

        local add=$(expr "$mess" : "^/add \(tz[a-zA-Z0-9]\{34\} [a-zA-Z0-9_-]\{1,27\}\)$")
        [ -n "$add" ] && {
          read -r new_addr art_name <<< "$add"
          mkdir -p ${hdir}/${new_addr}
          printf "$art_name" > ${hdir}/${new_addr}/name
          tg_send "Add Ok" "$tg_user_id"
          continue
        }

        local del=$(expr "$mess" : "^/del \(tz[a-zA-Z0-9]\{34\}\)$")
        [ -n "${del}" ] && {
          [ -e "${hdir}/${del}" ] && { 
            rm -rf ${hdir}/${del}
            tg_send "Del Ok" "$tg_user_id"
            true
          } || {
            tg_send "Del error: address $del not found" "$tg_user_id"
          }
          continue
        }

        local buy=$(expr "$mess" : "^/buy[ |_]\([0-9]\{1,15\}[ |_][0-9]\{1,18\}[,.]\{0,1\}[0-9]\{0,18\}[ ]\{0,1\}[0-9]\{0,18\}[,.]\{0,1\}[0-9]\{0,6\}\)$"|tr '_' ' '|tr "," ".")
        local max_price
        local fee
        [ -n "${buy}" ] && {
          read -r token_id max_price fee <<< "$buy"
          [ -e "${hdir}/tokens/${token_id}" ] && {
            [ -z "$fee" ] && fee="$(<$hdir/default_fee)"
            [ -z "$fee" ] && {
              fee="$MIN_FEE"
              printf "$fee" > ${hdir}/default_fee
            }
            printf "$max_price $fee" > ${hdir}/tokens/${token_id}
            tg_send "Now after the swap the token ($token_id) will be bought if the price less than or equal to $max_price tez and fee: $fee tez" "$tg_user_id"
            true
          } || {
            tg_send "Error: $token_id - unknown token id" "$tg_user_id"
          }
          continue
        }

        local buy_obj=$(expr "$mess" : "^/buy[ |_]\(tz[a-zA-Z0-9]\{34\}[ |_][0-9]\{1,15\}[ |_][0-9]\{1,18\}[,.]\{0,1\}[0-9]\{0,18\}[ ]\{0,1\}[0-9]\{0,18\}[,.]\{0,1\}[0-9]\{0,6\}\)$"|tr '_' ' '|tr "," ".")
        max_price=""
        fee=""
        [ -n "${buy_obj}" ] && {
          read -r addr token_id max_price fee <<< "$buy_obj"
          otokdir=${hdir}/${addr}/objkt_tokens
          [ ! -d ${otokdir} ] && mkdir -p $otokdir
          tok_file="${hdir}/tokens/${token_id}"
          o_tok_file="${otokdir}/${token_id}"
          #[ -e "$o_tok_file" ] && {
            [ -z "$fee" ] && fee="$(<$hdir/default_fee)"
            [ -z "$fee" ] && {
              fee="$MIN_FEE"
              printf "$fee" > ${hdir}/default_fee
            }
            printf "$max_price $fee" > ${o_tok_file}
            printf "$max_price $fee" > ${tok_file}
            tg_send "Now after the swap the token ($token_id) will be bought if the price less than or equal to $max_price tez and fee: $fee tez%0A/buy_cancel_${addr}_${token_id}" "$tg_user_id"
            true
          #} || {
          #  tg_send "Error: $token_id - unknown token id" "$tg_user_id"
          #}
          continue
        }

        local default_fee=$(expr "$mess" : "^/default_fee \([0-9]\{1,18\}[,.]\{0,1\}[0-9]\{0,6\}\)$")
        [ -n "$default_fee" ] && {
          printf "$default_fee" > ${hdir}/default_fee
          tg_send "Now default fee is $default_fee tez" "$tg_user_id"
          continue
        }

        local buy_cancel=$(expr "$mess" : "^/buy_cancel[ |_]\(tz[a-zA-Z0-9]\{34\}[ |_][0-9]\{1,15\}\)$"|tr '_' ' ')
        [ -n "${buy_cancel}" ] && {
          read -r addr token_id <<< "$buy_cancel"
          otokdir=${hdir}/${addr}/objkt_tokens
          [ ! -d ${otokdir} ] && continue
          rm -f "${hdir}/tokens/${token_id}"
          rm -f "${otokdir}/${token_id}"
          tg_send "Purchase canceled ($token_id)" "$tg_user_id"
          continue
        }


        tg_send "Error: unknown command or incorrect syntax" "$tg_user_id"
      done <<< $(wget -q --no-cookies --no-check-certificate -T 9 \
        --post-data "offset=${TG_UPDATE_ID}" -O - $TG_GET_URL | jq -reM ".result[] | select(.update_id > ${TG_UPDATE_ID} and .message.entities[0].type != null) | select(.message.text) | \"\(.update_id) \(.message.chat.id) \(.message.text)\"")
      #done <<< $(curl -s -X POST $TG_GET_URL -d offset=${TG_UPDATE_ID} | jq -reM ".result[] | select(.update_id > ${TG_UPDATE_ID} and .message.entities[0].type != null) | select(.message.text) | [.update_id, .message.chat.id, .message.text] | @sh" | tr -d "'")
    printf "%d" "${TG_UPDATE_ID}" > ${tlu_file}
    sleep 2
  done
}

tg_bot &
tg_pid=$!

quit(){
  echo "Exiting.. Killing process: $tg_pid $$"
  #local myjobs="`jobs -p`"
  #kill -SIGPIPE $myjobs >/dev/null 2>&1
  kill $tg_pid > /dev/null 2>&1
  kill $(ps --no-headers -o pid --ppid=$$) > /dev/null 2>&1
  exit 0
}


trap quit SIGHUP SIGINT SIGTERM

tail -f /tmp/tz_operations.last 2>/dev/null | while read -r action addr arg1 arg2 arg3 arg4
do

for chat_id in $(find ${DB_DIR}/ -mindepth 1 -maxdepth 1 -type d -execdir printf "%s\n" {} \;|tr -d './')
do

  [ ! -d ${DB_DIR}/${chat_id}/${addr} ] && continue

  DIR=${DB_DIR}/${chat_id}/${addr}
  tokdir=${DB_DIR}/${chat_id}/tokens
  objkt_tokdir=${DB_DIR}/${chat_id}/${addr}/objkt_tokens
  

  target_link0="https://tzkt.io/${addr}/operations/"
  target_link1="https://hicetnunc.art/tz/${addr}"
  target_link2="https://nftbiker.xyz/artist?wallet=${addr}"
  target_link3="https://hicetnunc.art/objkt/"
  user_name=$(<${DIR}/name)

  [ "$action" == "objkt_swap" ] && {
    
    magic="$arg1"
    token_id="$arg2"
    price="$arg3"
    amount="$arg4"

    log "[INFO] $user_name swaped on objkt $amount by $price (id:${token_id}, magic:${magic})"
    tok_file=${objkt_tokdir}/${token_id}
    [ -e $tok_file ] && {
      tg_send "$user_name swaped on objkt $amount by $price (id:${token_id}, magic:${magic})" "${chat_id}"
      token=$(cat $tok_file)
      [ "$token" == "0" ] && {
        rm $tok_file
        true
      } || {
        read -r max_price fee <<< "$token"
        [ "$(echo "$price<=$max_price" | bc -l)" == "1" ] && {
          [ -z "$fee" ] && {
            fee="$(<${DB_DIR}/${chat_id}/default_fee)"
            [ -z "$fee" ] && {
              fee="$MIN_FEE"
              printf "$fee" > ${DB_DIR}/${chat_id}/default_fee
            }
          }
          WALLET1="$(<$DB_DIR/${chat_id}/wallet1)"
          TZ_NODE="$(<$DB_DIR/${chat_id}/tz_node)"
          result="$($TZCLIENT -E $TZ_NODE -w 1 transfer ${price} from $WALLET1 to KT1FvqJwEDWb1Gwc55Jd1jjTHRVWbYKUUpyq --entrypoint 'fulfill_ask' --arg "${magic}" -S 500 --fee $fee --fee-cap 10 --burn-cap 0.02 2>&1 && echo "ACCEPTED!" || echo "FAIL!")"
          # --simulation
          hash_string="$(echo "$result" | grep -Eo  "Operation hash is '[0-9a-zA-Z]{40,60}'")"
          operation_hash="$(expr "$hash_string" : "^Operation hash is '\([0-9a-zA-Z]\{50,55\}\)'$")"
          operation_link="<a href=\"https://tzkt.io/${operation_hash}\">Operation</a>"
          hic_link="<a href=\"${target_link3}${token_id}\">Hicetnunc</a>"
          log "[Info] $result"
          log "[Info] $operation_hash"
          echo "$result" | grep -q 'Operation successfully injected in the node.' && echo "$result" | grep -q 'ACCEPTED!' && {
            tg_send "Bought 1 token for <b>${price}</b> tez from $user_name %0Amaxprice: <b>${max_price}</b> tez%0Afee: <b>${fee}</b> tez%0Amagic: <b>$magic</b>%0A${operation_link}%0A${hic_link}" "$chat_id"
            true
          } || {
            tg_send "ERROR: Token $token_id was not purchased! See server log: /get_log" "$chat_id"
          }
          #--minimal-nanotez-per-byte
          #--minimal-nanotez-per-gas-unit
        }&
        true
      } || {
        tg_send "Token $token_id was not purchased because the $price is higher than the $max_price" "$chat_id"
      }
      rm $tok_file
    }
  }

  [ "$action" == "objkt_auct" ] && {
    tg_send "${user_name} created an <a href='https://objkt.com/profile/${addr}/created'>auction</a>" "$chat_id"
  }

  [ "$action" == "objkt_mint" ] && {
    token_id="$arg1"
    amount="$arg2"
    collection="$arg3"
    o_tok_dir=${objkt_tokdir}
    #/${collection}
    
    log "[INFO] objkt_minted $amount ($collection / $token_id)"
    
    buy_links="/buy_${addr}_${token_id}_15%0A/buy_${addr}_${token_id}_30%0A/buy_${addr}_${token_id}_50%0A/buy_${addr}_${token_id}_100"
    
    tg_send "<b>${user_name} minted on objkt: $amount (id: $collection / $token_id)</b>%0A<a href=\"$target_link0\">tzkt.io</a>%0A<a href=\"$target_link1\">hicetnunc.art</a>%0A<a href=\"$target_link2\">nftbiker.xyz</a>%0A${buy_links}" "${chat_id}"
    
    [ ! -e ${o_tok_dir} ] && mkdir -p ${o_tok_dir}
    printf "0" > ${o_tok_dir}/${token_id}
  }


  [ "$action" == "mint" ] && {
    amount="$arg2"
    token_id="$arg1"
    log "[INFO] minted $amount ($token_id)"
    
    buy_links="/buy_${addr}_${token_id}_15%0A/buy_${addr}_${token_id}_30%0A/buy_${addr}_${token_id}_50%0A/buy_${addr}_${token_id}_100"
    #buy_links="/buy_${token_id}_15%0A/buy_${token_id}_30%0A/buy_${token_id}_50%0A/buy_${token_id}_100"
    tg_send "<b>${user_name} minted: $amount (id: $token_id)</b>%0A<a href=\"$target_link0\">tzkt.io</a>%0A<a href=\"$target_link1\">hicetnunc.art</a>%0A<a href=\"$target_link2\">nftbiker.xyz</a>%0A${buy_links}" "${chat_id}"
    [ ! -e ${tokdir} ] && mkdir ${tokdir}
    printf "0" > ${tokdir}/${token_id}
    [ ! -e ${objkt_tokdir} ] && mkdir -p ${objkt_tokdir}
    printf "0" > ${objkt_tokdir}/${token_id}
  }

  [ "$action" == "swap" ] && {
    
    amount="$arg4"
    price="$arg3"
    token_id="$arg2"
    magic="$arg1"

    mess="[INFO] $user_name swaped at hic $amount by $price (id:${token_id}, magic:${magic})"
    log "$mess"
    tok_file=${tokdir}/${token_id}
    o_tok_file=${objkt_tokdir}/${token_id}
    [ -e $tok_file ] && {
      tg_send "$mess" "${chat_id}"
      token=$(cat $tok_file)
      [ "$token" == "0" ] && {
        rm $tok_file
        rm $o_tok_file
        true
      } || {
        read -r max_price fee <<< "$token"
        [ "$(echo "$price<=$max_price" | bc -l)" == "1" ] && {
          [ -z "$fee" ] && {
            fee="$(<${DB_DIR}/${chat_id}/default_fee)"
            [ -z "$fee" ] && {
              fee="$MIN_FEE"
              printf "$fee" > ${DB_DIR}/${chat_id}/default_fee
            }
          }
          WALLET1="$(<$DB_DIR/${chat_id}/wallet1)"
          TZ_NODE="$(<$DB_DIR/${chat_id}/tz_node)"
          result="$($TZCLIENT -E $TZ_NODE -w 1 transfer ${price} from $WALLET1 to KT1HbQepzV1nVGg8QVznG7z4RcHseD5kwqBn --entrypoint 'collect' --arg "${magic}" -S 500 --fee $fee --fee-cap 10 --burn-cap 0.02 2>&1 && echo "ACCEPTED!" || echo "FAIL!")"
          # --simulation
          hash_string="$(echo "$result" | grep -Eo  "Operation hash is '[0-9a-zA-Z]{40,60}'")"
          operation_hash="$(expr "$hash_string" : "^Operation hash is '\([0-9a-zA-Z]\{50,55\}\)'$")"
          operation_link="<a href=\"https://tzkt.io/${operation_hash}\">Operation</a>"
          hic_link="<a href=\"${target_link3}${token_id}\">Hicetnunc</a>"
          log "[Info] $result"
          log "[Info] $operation_hash"
          echo "$result" | grep -q 'Operation successfully injected in the node.' && echo "$result" | grep -q 'ACCEPTED!' && {
            tg_send "Bought 1 token for <b>${price}</b> tez from $user_name %0Amaxprice: <b>${max_price}</b> tez%0Afee: <b>${fee}</b> tez%0Amagic: <b>$magic</b>%0A${operation_link}%0A${hic_link}" "$chat_id"
            true
          } || {
            tg_send "ERROR: Token $token_id was not purchased! See server log: /get_log" "$chat_id"
          }
          #--minimal-nanotez-per-byte
          #--minimal-nanotez-per-gas-unit
        }&
        true
      } || {
        tg_send "Token $token_id was not purchased because the $price is higher than the $max_price" "$chat_id"
      }
      rm $tok_file
      rm $o_tok_file
    }
  }
done
done
