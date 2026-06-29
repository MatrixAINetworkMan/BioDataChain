{
  "config": {
    "chainId": ${L1_CHAIN_ID},
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "arrowGlacierBlock": 0,
    "grayGlacierBlock": 0,
    "shanghaiTime": 0,
    "clique": {
      "period": ${L1_BLOCK_TIME},
      "epoch": 30000
    }
  },
  "nonce": "0x0",
  "timestamp": "${GENESIS_TIMESTAMP_HEX}",
  "extraData": "${EXTRA_DATA}",
  "gasLimit": "${L1_GAS_LIMIT_HEX}",
  "difficulty": "0x1",
  "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "coinbase": "0x0000000000000000000000000000000000000000",
  "alloc": {
    "${VALIDATOR_ADDRESS_NO0X}": { "balance": "0x21e19e0c9bab2400000" }
  }
}
