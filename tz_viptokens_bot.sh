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
          for addr in ${list}
          do
            [ "$addr" == "tokens" ] && continue
            send_list="$(printf "%s\n%s: %s\n" "$send_list" "$(cat ${hdir}/${addr}/name)" "$addr")"
          done
          tg_send "$send_list" "${tg_user_id}"
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

        local add=$(expr "$mess" : "^/add \(tz[a-zA-Z0-9]\{34\} [a-zA-Z0-9_-]\{1,18\}\)$")
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

        local default_fee=$(expr "$mess" : "^/default_fee \([0-9]\{1,18\}[,.]\{0,1\}[0-9]\{0,6\}\)$")
        [ -n "$default_fee" ] && {
          printf "$default_fee" > ${hdir}/default_fee
          tg_send "Now default fee is $default_fee tez" "$tg_user_id"
          continue
        }

        tg_send "Error: unknown command or incorrect syntax" "$tg_user_id"
      done <<< $(curl -s -X POST $TG_GET_URL -d offset=${TG_UPDATE_ID} | jq -reM ".result[] | select(.update_id > ${TG_UPDATE_ID} and .message.entities[0].type != null) | select(.message.text) | [.update_id, .message.chat.id, .message.text] | @sh" | tr -d "'")
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

while true
do

for chat_id in $(find ${DB_DIR}/ -mindepth 1 -maxdepth 1 -type d -execdir printf "%s\n" {} \;|tr -d './')
do
  for addr in $(find ${DB_DIR}/${chat_id} -mindepth 1 -maxdepth 1 -type d -execdir printf "%s\n" {} \;|tr -d './')
  do
    [ "$addr" == "tokens" ] && continue
    DIR=${DB_DIR}/${chat_id}/${addr}
    tokdir=${DB_DIR}/${chat_id}/tokens
    last_level_file=${DIR}/last_level

    [ -e $last_level_file ] || {
      printf "%i" 0 > $last_level_file
    }

    target_link0="https://tzkt.io/${addr}/operations/"
    target_link1="https://www.hicetnunc.xyz/tz/${addr}"
    target_link2="https://nftbiker.xyz/artist?wallet=${addr}"
    target_link3="https://www.hicetnunc.xyz/objkt/"
    account_url="https://api.tzkt.io/v1/accounts/${addr}"
    metadata_url="https://api.tzkt.io/v1/accounts/${addr}/metadata"
    level_url="https://api.tzkt.io/v1/accounts/${addr}/operations?level="

    account=$(curl -s ${account_url})
    user_name=$(<${DIR}/name)
    #user_name=$(jq -r '.alias' <<< "$account")
    last_activity=$(jq -r '.lastActivity' <<< "$account")
    [ "$last_activity" == "null" -o "$last_activity" == "" ] && { log "[ERROR] get last activity: ${account}"; continue; }

    [ -e $last_level_file ] && {
    	last_level=$(cat $last_level_file)
      true
    } || {
      last_level=0
    }

    [ "$last_level" == "$last_activity" ] && continue

    printf "%i" $last_activity > $last_level_file
    log "[Info] NEW BLOCK! ($last_level -> $last_activity)"

    block="$(curl -s ${level_url}${last_activity})"
    jq -e . >/dev/null 2>&1 <<<"$block" || { log "[ERROR] get block $last_activity"; continue; }

    mint="$(jq -r '.[] | select(.parameter.entrypoint == "mint" and .status != "backtracked") | [(.parameter.value.amount|tonumber), (.parameter.value.token_id|tonumber)] | @sh' <<<"$block")"
    [ -n "$mint" ] && {
      read -r amount token_id <<< "$mint"
      log "[INFO] minted $amount ($token_id)"
      buy_links="/buy_${token_id}_15%0A/buy_${token_id}_30%0A/buy_${token_id}_50%0A/buy_${token_id}_100"
      tg_send "<b>${user_name} minted: $amount (id: $token_id)</b>%0A<a href=\"$target_link0\">tzkt.io</a>%0A<a href=\"$target_link1\">hicetnunc.xyz</a>%0A<a href=\"$target_link2\">nftbiker.xyz</a>%0A${buy_links}" "${chat_id}"
      [ ! -e ${tokdir} ] && mkdir ${tokdir}
      printf "0" > ${tokdir}/${token_id}
    }

    swap=$(jq -r '.[] | select(.parameter.entrypoint == "swap" and .parameter.value.creator == .sender.address) | "\(.parameter.value.objkt_amount|tonumber) \((.parameter.value.xtz_per_objkt|tonumber)/1000000) \((.parameter.value.objkt_id|tonumber)) \(.hash)"' <<< "$block")
#    swap=$(jq -r '.[] | select(.parameter.entrypoint == "swap" and .parameter.value.creator == .sender.address) | [(.parameter.value.objkt_amount|tonumber), (.parameter.value.xtz_per_objkt|tonumber)/1000000, (.parameter.value.objkt_id|tonumber), .hash] | @sh' <<< "$block"|tr -d "'")
    [ -n "$swap" ] && {
     while read -r amount price token_id swap_hash
     do
      log "[INFO] $user_name swaped $amount by $price (id:${token_id}, hash:${swap_hash})"
      tg_send "$user_name swaped $amount by $price (id:${token_id}, hash:${swap_hash})" "${chat_id}"
      tok_file=${tokdir}/${token_id}
      [ -e $tok_file ] && {
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
            operations="$(curl -s https://api.tzkt.io/v1/operations/${swap_hash})"
            details="$(jq -r '.[1]|[(.diffs|.[]|.content.key|tonumber),(.parameter.value.xtz_per_objkt|tonumber)/1000000]|@sh'<<<"$operations")"

            log "[Info] swap details: $details ($user_name)"
            [ -n "$details" ] && {

              read -r magic price <<< "$details"

              WALLET1="$(<$DB_DIR/${chat_id}/wallet1)"
	            TZ_NODE="$(<$DB_DIR/${chat_id}/tz_node)"
              result="$($TZCLIENT -E $TZ_NODE -w 1 transfer ${price} from $WALLET1 to KT1HbQepzV1nVGg8QVznG7z4RcHseD5kwqBn --entrypoint 'collect' --arg "${magic}" -S 500 --fee $fee --fee-cap 5 --burn-cap 0.02 2>&1 && echo "ACCEPTED!" || echo "FAIL!")"
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
     done<<<"$swap"
    }
  done
done

sleep 5
done
