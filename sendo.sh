#!/bin/bash
#set -x
#set -e

# trap ERR show_wallet

# set some defaults
output_dir="/tmp"

function show_wallet() {
  utxo=$(cardano-cli query utxo --testnet-magic "${TESTNET_MAGIC}" --address "${address}")
  txs=0
  balance=0
  while read line; do
    echo "${line}"
    txs=$(( txs + 1 ))
    amount=$(echo "${line}" | awk '{print $3}')
    balance=$(( balance + amount ))
  done < <(echo "${utxo}" | grep "[0-9]")

  echo -e
  echo -e
  echo "address:           ${address}"
  echo "total balance:     ${balance}"
  echo "transaction count: ${txs}"
  echo -e
  exit 2
}

function usage() {
        cat <<-EOM

  send \$ADA from a wallet to one other wallet.

  -b)  show sending wallet balance (works with -f)
  -t)  wallet to send to
  -f)  wallet to send from
  -k)  signing key for wallet to send from
  -a)  amount to send
  -o)  output directory where transactions files are written to (default ${output_dir})
  -h)  you're lookin' at it

        EOM
  exit 2
}


while getopts "bt:f:k:a:d:h" options; do
  case "${options}" in
    b) show_wallet;;
    t) to_address="${OPTARG}";;
    f) address="${OPTARG}";;
    k) signing_key_file="${OPTARG}";;
    a) amount_to_send="${OPTARG}";;
    o) output_dir="${OPTARG}";;
    h) usage;;
  esac
done

#echo $amount_to_send
#echo $signing_key_file
#echo $output_dir
#echo $address
#echo $to_address

# lint stuff
if [ -z "${to_address}" ]; then
  fail=true
  echo "-t cannot be empty, provide a valid address to send to"
fi

if [ -z "${address}" ]; then
  fail=true
  echo "-f cannot be empty, provide a valid address from to send from (this is your address fool!)"
fi

if [ -z "${signing_key_file}" ]; then
  fail=true
  echo "-k cannot be empty, provide a valid path to the signing key file for the address to send from"
fi

if [ -z "${amount_to_send}" ]; then
  fail=true
  echo "-a cannot be empty, specify an amount of lovelace to send"
fi

if [[ "${fail}" == "true" ]]; then
  exit 2
fi

# files we'll need
transaction_draft_file="${output_dir}/transaction.draft"
transaction_raw_file="${output_dir}/transaction.raw"
transaction_signed_file="${output_dir}/transaction.signed"
protocol_file="${output_dir}/protocol.json"

# get our protocol parameters
cardano-cli query protocol-parameters \
        --testnet-magic "${TESTNET_MAGIC}" \
        --out-file "${protocol_file}"

# slot is 1 second on the blockchain
slot=$(cardano-cli query tip --testnet-magic "${TESTNET_MAGIC}" | jq .slot)

# hereafter is the TTL of our transaction
hereafter=$(( slot + 200 ))

# utxo is the current state of our wallet
utxo=$(cardano-cli query utxo --testnet-magic "${TESTNET_MAGIC}" --address "${address}")

# find the first transaction
last_tx=$(echo "${utxo}" | grep "^[a-z0-9]" | head -1)

# set a clean environment before we start iterating through the wallet
wallet_lovelace=0
total_wallet_lovelace=0

# this will be the argument we pass to the cli when we build our transactions
all_tx_ins=""
tx_in_count=0

# we make the amount we are sending +1 to make sure we have enough for the fee
lovelace_needed=$(( amount_to_send + 1 ))

# start iterating through all the transactions in our wallet.
# we need to generate enough money to send and cover the fee.
while read line; do
  txix=$(echo "${line}" | awk '{print $1"#"$2}')
  lovelace=$(echo "${line}" | awk '{print $3}')
  total_wallet_lovelace=$(( total_wallet_lovelace + wallet_lovelace ))

  # if the amount we are sending is not covered by this transaction in our wallet, add the next transaction
  #echo $txix
  #echo $wallet_lovelace
  #echo $lovelace_needed
  if [ -z "${all_tx_ins}" ]; then
    wallet_lovelace=$(( wallet_lovelace + lovelace ))
    tx_in_count=$(( tx_in_count + 1 ))
    all_tx_ins="--tx-in ${txix}"
  elif [[ "${wallet_lovelace}" -lt "${lovelace_needed}" ]]; then
    wallet_lovelace=$(( wallet_lovelace + lovelace ))
    tx_in_count=$(( tx_in_count + 1 ))
    all_tx_ins="${all_tx_ins} --tx-in ${txix}"
  fi
done < <(echo "${utxo}" | grep "[0-9]")

# if we do not have enough to cover the cost, bail
if [[ "${wallet_lovelace}" -lt "${lovelace_needed}" ]]; then
  echo "insufficient funds! lovelace needed: ${lovelace_needed}, total lovelace: ${wallet_lovelace}"
  exit 2
fi

# draft a transaction using dummy values other than our --tx-in
cardano-cli transaction build-raw \
  $(echo "${all_tx_ins}") \
  --tx-out "${address}+0" \
  --tx-out "${to_address}+0" \
  --invalid-hereafter 0 \
  --fee 0 \
  --out-file "${transaction_draft_file}"

# calculate the minimum fee
fee=$(cardano-cli transaction calculate-min-fee \
  --tx-body-file "${transaction_draft_file}" \
  --tx-in-count "${tx_in_count}" \
  --tx-out-count 2 \
  --witness-count 1 \
  --testnet-magic "${TESTNET_MAGIC}" \
  --protocol-params-file "${protocol_file}" | awk '{print $1}')

# calculate the amount returned to the wallet
amount_returned=$(expr "${wallet_lovelace}" - "${amount_to_send}" - "${fee}")

# create the transaction
cardano-cli transaction build-raw \
  $(echo "${all_tx_ins}") \
  --tx-out "${address}+${amount_returned}" \
  --tx-out "${to_address}+${amount_to_send}" \
  --invalid-hereafter "${hereafter}" \
  --fee "${fee}" \
  --out-file "${transaction_raw_file}"

# sign the transaction
cardano-cli transaction sign \
  --tx-body-file "${transaction_raw_file}" \
  --signing-key-file "${signing_key_file}" \
  --testnet-magic "${TESTNET_MAGIC}" \
  --out-file "${transaction_signed_file}"

echo "to:              ${to_address}"
echo "amount_to_send:  ${amount_to_send}"
echo "fee:             ${fee}"
echo "from:            ${address}"
echo "wallet_lovelace: ${wallet_lovelace}"
echo "total_wallet:    ${total_wallet_lovelace}"
echo "amount_returned: ${amount_returned}"
echo "hereafter:       ${hereafter}"
echo "slot:            ${slot}"
echo "protocols:       ${protocol_file}"
echo "tx draft:        ${transaction_draft_file}"
echo "tx raw:          ${transaction_raw_file}"
echo "tx-in:           ${all_tx_ins}"

# submit the transaction
cardano-cli transaction submit \
  --tx-file "${transaction_signed_file}" \
  --testnet-magic "${TESTNET_MAGIC}"
