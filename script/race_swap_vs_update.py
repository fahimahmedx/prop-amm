import os
from concurrent.futures import ThreadPoolExecutor
from web3 import Web3
from eth_account import Account

# Config
RPC_URL = os.getenv("RPC_URL", "http://localhost:8547")
PRIVATE_KEY = os.getenv("PRIVATE_KEY")

PROP_AMM_ADDRESS = "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9"
GLOBAL_STORAGE_ADDRESS = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
WETH_ADDRESS = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
USDC_ADDRESS = "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9"

# Pair ID for WETH/USDC (calculated from getPairId)
PAIR_ID = "0x667546a103822a3ea5b74bdf319f969f53de0a26339708852cfa21db6575a3be"

# PropAMM ABI
PROP_AMM_ABI = [
    {
        "inputs": [
            {"internalType": "bytes32", "name": "pairId", "type": "bytes32"},
            {"internalType": "uint256", "name": "amountXIn", "type": "uint256"},
            {"internalType": "uint256", "name": "minAmountYOut", "type": "uint256"},
        ],
        "name": "swapXtoY",
        "outputs": [{"internalType": "uint256", "name": "amountYOut", "type": "uint256"}],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [
            {"internalType": "bytes32", "name": "pairId", "type": "bytes32"},
        ],
        "name": "getParameterKeys",
        "outputs": [{"internalType": "bytes32[]", "name": "keys", "type": "bytes32[]"}],
        "stateMutability": "pure",
        "type": "function",
    },
    {
        "inputs": [
            {"internalType": "uint256", "name": "concentration", "type": "uint256"},
            {"internalType": "uint256", "name": "multX", "type": "uint256"},
            {"internalType": "uint256", "name": "multY", "type": "uint256"},
        ],
        "name": "encodeParameters",
        "outputs": [{"internalType": "bytes32[]", "name": "values", "type": "bytes32[]"}],
        "stateMutability": "pure",
        "type": "function",
    },
]

# GlobalStorage ABI
GLOBAL_STORAGE_ABI = [
    {
        "inputs": [
            {"internalType": "bytes32[]", "name": "keys", "type": "bytes32[]"},
            {"internalType": "bytes32[]", "name": "values", "type": "bytes32[]"},
        ],
        "name": "setBatch",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
]


def gwei(n: int) -> int:
    return int(n) * 10**9


def main() -> None:
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    account = Account.from_key(PRIVATE_KEY)
    sender = account.address
    chain_id = w3.eth.chain_id
    
    print(f"Connected to chain ID: {chain_id}")
    print(f"Sender address: {sender}")
    
    # Initialize PropAMM contract
    amm_contract = w3.eth.contract(
        address=Web3.to_checksum_address(PROP_AMM_ADDRESS),
        abi=PROP_AMM_ABI,
    )
    
    # Initialize GlobalStorage contract
    global_storage_contract = w3.eth.contract(
        address=Web3.to_checksum_address(GLOBAL_STORAGE_ADDRESS),
        abi=GLOBAL_STORAGE_ABI,
    )
    
    # Swap amount: 1 WETH
    swap_amount_weth = Web3.to_wei(1, 'ether')
    
    # Prepare swapXtoY transaction (HIGH priority fee)
    swap_func = amm_contract.functions.swapXtoY(
        bytes.fromhex(PAIR_ID[2:]),  # Remove '0x' prefix
        swap_amount_weth,
        0,  # minAmountYOut (0 for simplicity)
    )
    
    # Prepare GlobalStorage.setBatch() transaction for parameter update (LOW priority fee)
    # This will get ToB priority because the transaction's 'to' is GlobalStorage
    new_concentration = 150
    new_mult_x = 10**18
    new_mult_y = 3000 * 10**18
    
    # Get keys and values from PropAMM helper functions
    pair_id_bytes = bytes.fromhex(PAIR_ID[2:])  # Remove '0x' prefix
    keys = amm_contract.functions.getParameterKeys(pair_id_bytes).call()
    values = amm_contract.functions.encodeParameters(new_concentration, new_mult_x, new_mult_y).call()
    
    update_func = global_storage_contract.functions.setBatch(keys, values)
    
    # Fee config: HIGH priority for swap, LOW priority for update
    latest = w3.eth.get_block("latest")
    base_fee = latest.get("baseFeePerGas")
    if base_fee is not None:
        fee_high = {
            "maxPriorityFeePerGas": gwei(10),  # HIGH priority
            "maxFeePerGas": base_fee * 2 + gwei(10),
        }
        fee_low = {
            "maxPriorityFeePerGas": gwei(1),  # LOW priority
            "maxFeePerGas": base_fee * 2 + gwei(1),
        }
    else:
        # Legacy fallback
        fee_high = {"gasPrice": gwei(100)}
        fee_low = {"gasPrice": gwei(20)}
    
    base_nonce = w3.eth.get_transaction_count(sender, "pending")
    
    # Estimate gas
    gas_swap = swap_func.estimate_gas({"from": sender})
    gas_update = update_func.estimate_gas({"from": sender})
    
    print(f"\nEstimated gas - Swap: {gas_swap:,}, Update: {gas_update:,}")
    
    # Build transactions

    # Update gets low priority fee
    tx_update = update_func.build_transaction({
        "from": sender,
        "nonce": base_nonce,
        "chainId": chain_id,
        "gas": gas_update + 20000,
        **fee_low,
    })


    # Swap gets high priority fee
    tx_swap = swap_func.build_transaction({
        "from": sender,
        "nonce": base_nonce+1,
        "chainId": chain_id,
        "gas": gas_swap + 20000,
        **fee_high,
    })
    
    # Sign transactions
    signed_swap = Account.sign_transaction(tx_swap, PRIVATE_KEY)
    signed_update = Account.sign_transaction(tx_update, PRIVATE_KEY)
    
    print(f"\n=== Sending competing transactions ===")
    print(f"Swap transaction - Priority fee: {fee_high.get('maxPriorityFeePerGas', 0) / 10**9:.2f} gwei")
    print(f"Update transaction - Priority fee: {fee_low.get('maxPriorityFeePerGas', 0) / 10**9:.2f} gwei")
    
    # Send concurrently
    with ThreadPoolExecutor(max_workers=2) as pool:
        fut_update = pool.submit(w3.eth.send_raw_transaction, signed_update.raw_transaction)
        fut_swap = pool.submit(w3.eth.send_raw_transaction, signed_swap.raw_transaction)
        txhash_update = fut_update.result().hex()
        txhash_swap = fut_swap.result().hex()
    
    print(f"Sent GlobalStorage.setBatch() tx (ToB): {txhash_update}")
    print(f"\nSent swapXtoY() tx: {txhash_swap}")
    
    
    # Wait for receipts concurrently
    print("\nWaiting for confirmations...")
    with ThreadPoolExecutor(max_workers=2) as pool:
        r1 = pool.submit(w3.eth.wait_for_transaction_receipt, txhash_update)
        r2 = pool.submit(w3.eth.wait_for_transaction_receipt, txhash_swap)
        rcpt_update = r1.result()
        rcpt_swap = r2.result()
        
    
    # Display results
    print("\n" + "="*60)
    print("TRANSACTION RESULTS")
    print("="*60)
    
    print(f"\n🔄 swapXtoY() Transaction: {txhash_swap}")
    print(f"  Status: {'✓ Success' if rcpt_swap.get('status') == 1 else '✗ Failed'}")
    print(f"  Block Number: {rcpt_swap.get('blockNumber')}")
    print(f"  Block Hash: {rcpt_swap.get('blockHash')}")
    print(f"  Gas Used: {rcpt_swap.get('gasUsed'):,}")
    print(f"  Effective Gas Price: {rcpt_swap.get('effectiveGasPrice') / 10**9:.2f} gwei")
    print(f"  Total Cost: {rcpt_swap.get('gasUsed') * rcpt_swap.get('effectiveGasPrice') / 10**18:.6f} ETH")
    
    print(f"\n⚙️  GlobalStorage.setBatch() Transaction: {txhash_update}")
    print(f"  Status: {'✓ Success' if rcpt_update.get('status') == 1 else '✗ Failed'}")
    print(f"  Block Number: {rcpt_update.get('blockNumber')}")
    print(f"  Block Hash: {rcpt_update.get('blockHash')}")
    print(f"  Gas Used: {rcpt_update.get('gasUsed'):,}")
    print(f"  Effective Gas Price: {rcpt_update.get('effectiveGasPrice') / 10**9:.2f} gwei")
    print(f"  Total Cost: {rcpt_update.get('gasUsed') * rcpt_update.get('effectiveGasPrice') / 10**18:.6f} ETH")
    
    print("\n" + "="*60)
    if rcpt_swap.get('blockNumber') == rcpt_update.get('blockNumber'):
        print("Both transactions landed in the SAME block!")
        # Check transaction index to see ordering
        tx_idx_swap = rcpt_swap.get('transactionIndex')
        tx_idx_update = rcpt_update.get('transactionIndex')
        if tx_idx_swap < tx_idx_update:
            print(f"   ⚠️ Swap (high fee) executed BEFORE update (ToB priority)")
            print(f"    Transaction indices: swap={tx_idx_swap}, update={tx_idx_update}")
        else:
            print(f"   ✓ Update (ToB priority) executed BEFORE swap (high fee)")
            print(f"    Transaction indices: swap={tx_idx_swap}, update={tx_idx_update}")
    else:
        print("Transactions landed in DIFFERENT blocks:")
        print(f"  Swap block: {rcpt_swap.get('blockNumber')}")
        print(f"  Update block: {rcpt_update.get('blockNumber')}")
    print("="*60)


if __name__ == "__main__":
    main()

# cast block --rpc-url http://localhost:8547 757