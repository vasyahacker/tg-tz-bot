#!/bin/sh
curl --connect-timeout 9 -m 9 -s https://teznode.letzbake.com/chains/main/blocks/head | jq -r '.operations[] | .[] | .contents[]' | jq -s '.' > /tmp/last_block.tmp && mv -f /tmp/last_block.tmp /tmp/last_block.json
