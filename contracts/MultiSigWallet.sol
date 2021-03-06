pragma solidity ^0.4.15;


/// @title Multisignature wallet - Allows multiple parties to agree on transactions before execution.
/// @author Stefan George - <stefan.george@consensys.net>
contract MultiSigWallet {

    /*
     *  Events
     */
    event Confirmation(address indexed sender, uint indexed transactionId);
    event Revocation(address indexed sender, uint indexed transactionId);
    event Submission(uint indexed transactionId);
    event Execution(uint indexed transactionId);
    event ExecutionFailure(uint indexed transactionId);
    event Deposit(address indexed sender, uint value);
    event OwnerAddition(address indexed owner);
    event OwnerRemoval(address indexed owner);
    event RequirementChange(uint required);
    event MinSwapAmountChange(uint _min_swap_amount);
    event SwapFeeChange(uint _swap_fee);
    event SwapRequest( bytes32 chainId,
                       string swapPubkey,
                       uint amountToSwap,
                       address returnAddress,
                       uint timestamp);
    event ChainIdAddition(bytes32 _chain_id);
    event ChainIdRemoval(bytes32 _chain_id);

    /*
     *  Constants
     */
    uint constant public MAX_OWNER_COUNT = 50;
    ERC20 constant internal ERC20_REM_CONTRACT = ERC20(0x29A5DC3252D5aAAe7DF25Cc1C6128f484eb340eD);  // Remme ERC20 contract address
    bytes32 constant public ETH_ID = 0x3;
    uint constant public REMCHAIN_PUBKEY_LENGTH = 53;

    /*
     *  Storage
     */
    uint public min_swap_amount = 1200000;  // in REM
    uint public swap_fee = 200000;
    bytes32[] public destination_chain_ids = [
        bytes32(0x1c6ae7719a2a3b4ecb19584a30ff510ba1b6ded86e1fd8b8fc22f1179c622a32)  // Remprotocol identifier
    ];

    mapping (uint => Transaction) public transactions;
    mapping (bytes32 => uint) public swapTransactions;  // returns transaction number starting from 1
    mapping (uint => mapping (address => bool)) public confirmations;
    mapping (address => bool) public isOwner;
    address[] public owners;
    uint public required;
    uint public transactionCount = 0;

    struct Transaction {
        address destination;
        uint value;
        bytes data;
        bool executed;
    }

    /*
     *  Modifiers
     */
    modifier onlyWallet() {
        require(msg.sender == address(this));
        _;
    }

    modifier ownerDoesNotExist(address owner) {
        require(!isOwner[owner]);
        _;
    }

    modifier ownerExists(address owner) {
        require(isOwner[owner]);
        _;
    }

    modifier transactionExists(uint transactionId) {
        require(transactions[transactionId].destination != 0);
        _;
    }

    modifier confirmed(uint transactionId, address owner) {
        require(confirmations[transactionId][owner]);
        _;
    }

    modifier notConfirmed(uint transactionId, address owner) {
        require(!confirmations[transactionId][owner]);
        _;
    }

    modifier notExecuted(uint transactionId) {
        require(!transactions[transactionId].executed);
        _;
    }

    modifier notNull(address _address) {
        require(_address != 0);
        _;
    }

    modifier validRequirement(uint ownerCount, uint _required) {
        require(ownerCount <= MAX_OWNER_COUNT
            && _required <= ownerCount
            && _required != 0
            && ownerCount != 0);
        _;
    }

    modifier validAmountToSwap(uint amountToSwap) {
        require(amountToSwap >= min_swap_amount);
        _;
    }

    modifier validChainId(bytes32 chainId) {
        bool isValidChainId = false;
        for(uint i = 0; i < destination_chain_ids.length; i++)
            if(chainId == destination_chain_ids[i])
                isValidChainId = true;
        require(isValidChainId);
        _;
    }

    modifier validPubkey(string pubkey) {
        require(bytes(pubkey).length == REMCHAIN_PUBKEY_LENGTH);
        _;
    }


    /// @dev Fallback function allows to deposit ether.
    function()
        payable
    {
        if (msg.value > 0)
            Deposit(msg.sender, msg.value);
    }

    /*
     * Public functions
     */
    /// @dev Contract constructor sets initial owners and required number of confirmations.
    /// @param _owners List of initial owners.
    /// @param _required Number of required confirmations.
    function MultiSigWallet(address[] _owners, uint _required)
        public
        validRequirement(_owners.length, _required)
    {
        for (uint i=0; i<_owners.length; i++) {
            require(!isOwner[_owners[i]] && _owners[i] != 0);
            isOwner[_owners[i]] = true;
        }
        owners = _owners;
        required = _required;
    }

    /// @dev Allows to add a new owner. Transaction has to be sent by wallet.
    /// @param owner Address of new owner.
    function addOwner(address owner)
        public
        onlyWallet
        ownerDoesNotExist(owner)
        notNull(owner)
        validRequirement(owners.length + 1, required)
    {
        isOwner[owner] = true;
        owners.push(owner);
        OwnerAddition(owner);
    }

    /// @dev Allows to remove an owner. Transaction has to be sent by wallet.
    /// @param owner Address of owner.
    function removeOwner(address owner)
        public
        onlyWallet
        ownerExists(owner)
    {
        isOwner[owner] = false;
        for (uint i=0; i<owners.length - 1; i++)
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                break;
            }
        owners.length -= 1;
        if (required > owners.length)
            changeRequirement(owners.length);
        OwnerRemoval(owner);
    }

    /// @dev Allows to replace an owner with a new owner. Transaction has to be sent by wallet.
    /// @param owner Address of owner to be replaced.
    /// @param newOwner Address of new owner.
    function replaceOwner(address owner, address newOwner)
        public
        onlyWallet
        ownerExists(owner)
        ownerDoesNotExist(newOwner)
    {
        for (uint i=0; i<owners.length; i++)
            if (owners[i] == owner) {
                owners[i] = newOwner;
                break;
            }
        isOwner[owner] = false;
        isOwner[newOwner] = true;
        OwnerRemoval(owner);
        OwnerAddition(newOwner);
    }

    /// @dev Allows to change the number of required confirmations. Transaction has to be sent by wallet.
    /// @param _required Number of required confirmations.
    function changeRequirement(uint _required)
        public
        onlyWallet
        validRequirement(owners.length, _required)
    {
        required = _required;
        RequirementChange(_required);
    }

    /// @dev Allows to change minimum swap amount. Transaction has to be sent by wallet.
    /// @param _min_swap_amount minimum amount to swap.
    function changeMinimumSwapAmount(uint _min_swap_amount)
        public
        onlyWallet
    {
        min_swap_amount = _min_swap_amount;
        MinSwapAmountChange(_min_swap_amount);
    }

    /// @dev Allows to change swap's fee. Transaction has to be sent by wallet.
    /// @param _swap_fee new swap's fee.
    function changeSwapFee(uint _swap_fee)
        public
        onlyWallet
    {
        swap_fee = _swap_fee;
        SwapFeeChange(_swap_fee);
    }

    /// @dev Allows to add new chain identifier on which swapped tokens can be sent. Transaction has to be sent by wallet.
    /// @param _chain_id new chain identifier to add.
    function addChainId(bytes32 _chain_id)
        public
        onlyWallet
    {
        destination_chain_ids.push(_chain_id);
        ChainIdAddition(_chain_id);
    }

    /// @dev Allows to remove chain identifier. Transaction has to be sent by wallet.
    /// @param _chain_id chain identifier to remove.
    function removeChainId(bytes32 _chain_id)
        public
        onlyWallet
    {
        for(uint i = 0; i < destination_chain_ids.length; i++)
            if(destination_chain_ids[i] == _chain_id) {
              delete destination_chain_ids[i];
              ChainIdRemoval(_chain_id);
            }
    }

    /// @dev Allows a user to request swap from ERC20 REM to Remchain.
    /// @param chainId Destination blockchain identifier on which swapped tokens should be  sent.
    /// @param swapPubkey Public key which is used to validate signature for claiming account name on Remchain.
    /// @param amountToSwap Amount of tokens to swap from ERC20 REM to Remchain.
    function requestSwap(bytes32 chainId, string swapPubkey, uint amountToSwap)
        public
        validAmountToSwap(amountToSwap)
        validChainId(chainId)
        validPubkey(swapPubkey)
    {
        if (!ERC20_REM_CONTRACT.transferFrom(msg.sender, address(this), amountToSwap)) {
            revert();
        }
        SwapRequest(chainId, swapPubkey, amountToSwap, msg.sender, now);
    }

    /// @dev Allows an owner to submit and confirm a transaction.
    /// @param destination Transaction target address.
    /// @param value Transaction ether value.
    /// @param data Transaction data payload.
    /// @return Returns transaction ID.
    function submitTransaction(address destination, uint value, bytes data)
        public
        returns (uint transactionId)
    {
        transactionId = addTransaction(destination, value, data);
        confirmTransaction(transactionId);
    }

    /// @dev Allows an owner to submit and confirm a swap transaction from Remchain to ERC20 REM.
    /// @param destination Transaction target address.
    /// @param value Transaction ether value.
    /// @param nonce Transaction counter in Remchain.
    /// @param data Transaction data payload.
    /// @return Returns transaction ID.
    function processSwapTransaction(address destination, uint value, uint nonce, bytes data)
        public
        returns (uint transactionId)
    {
        bytes32 swapId = keccak256(ETH_ID, "*", destination, "*", value, "*", nonce, "*", data);
        transactionId = swapTransactions[swapId];
        if ( transactionId == 0 ) {
            transactionId = addTransaction(destination, value, data);
            swapTransactions[swapId] = transactionId+1;
        }
        confirmTransaction(swapTransactions[swapId]-1);
    }

    /// @dev Allows an owner to confirm a transaction.
    /// @param transactionId Transaction ID.
    function confirmTransaction(uint transactionId)
        public
        ownerExists(msg.sender)
        transactionExists(transactionId)
        notConfirmed(transactionId, msg.sender)
    {
        confirmations[transactionId][msg.sender] = true;
        Confirmation(msg.sender, transactionId);
        executeTransaction(transactionId);
    }

    /// @dev Allows an owner to revoke a confirmation for a transaction.
    /// @param transactionId Transaction ID.
    function revokeConfirmation(uint transactionId)
        public
        ownerExists(msg.sender)
        confirmed(transactionId, msg.sender)
        notExecuted(transactionId)
    {
        confirmations[transactionId][msg.sender] = false;
        Revocation(msg.sender, transactionId);
    }

    /// @dev Allows anyone to execute a confirmed transaction.
    /// @param transactionId Transaction ID.
    function executeTransaction(uint transactionId)
        public
        ownerExists(msg.sender)
        confirmed(transactionId, msg.sender)
        notExecuted(transactionId)
    {
        if (isConfirmed(transactionId)) {
            Transaction storage txn = transactions[transactionId];
            txn.executed = true;
            if (external_call(txn.destination, txn.value, txn.data.length, txn.data))
                Execution(transactionId);
            else {
                ExecutionFailure(transactionId);
                txn.executed = false;
            }
        }
    }

    // call has been separated into its own function in order to take advantage
    // of the Solidity's code generator to produce a loop that copies tx.data into memory.
    function external_call(address destination, uint value, uint dataLength, bytes data) internal returns (bool) {
        bool result;
        assembly {
            let x := mload(0x40)   // "Allocate" memory for output (0x40 is where "free memory" pointer is stored by convention)
            let d := add(data, 32) // First 32 bytes are the padded length of data, so exclude that
            result := call(
                sub(gas, 34710),   // 34710 is the value that solidity is currently emitting
                                   // It includes callGas (700) + callVeryLow (3, to pay for SUB) + callValueTransferGas (9000) +
                                   // callNewAccountGas (25000, in case the destination address does not exist and needs creating)
                destination,
                value,
                d,
                dataLength,        // Size of the input (in bytes) - this is what fixes the padding problem
                x,
                0                  // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }

    /// @dev Returns the confirmation status of a transaction.
    /// @param transactionId Transaction ID.
    /// @return Confirmation status.
    function isConfirmed(uint transactionId)
        public
        constant
        returns (bool)
    {
        uint count = 0;
        for (uint i=0; i<owners.length; i++) {
            if (confirmations[transactionId][owners[i]])
                count += 1;
            if (count == required)
                return true;
        }
    }

    /*
     * Internal functions
     */
    /// @dev Adds a new transaction to the transaction mapping, if transaction does not exist yet.
    /// @param destination Transaction target address.
    /// @param value Transaction ether value.
    /// @param data Transaction data payload.
    /// @return Returns transaction ID.
    function addTransaction(address destination, uint value, bytes data)
        internal
        notNull(destination)
        returns (uint transactionId)
    {
        transactionId = transactionCount;
        transactions[transactionId] = Transaction({
            destination: destination,
            value: value,
            data: data,
            executed: false
        });
        transactionCount += 1;
        Submission(transactionId);
    }

    /*
     * Web3 call functions
     */
    /// @dev Returns number of confirmations of a transaction.
    /// @param transactionId Transaction ID.
    /// @return Number of confirmations.
    function getConfirmationCount(uint transactionId)
        public
        constant
        returns (uint count)
    {
        for (uint i=0; i<owners.length; i++)
            if (confirmations[transactionId][owners[i]])
                count += 1;
    }

    /// @dev Returns total number of transactions after filers are applied.
    /// @param pending Include pending transactions.
    /// @param executed Include executed transactions.
    /// @return Total number of transactions after filters are applied.
    function getTransactionCount(bool pending, bool executed)
        public
        constant
        returns (uint count)
    {
        for (uint i=0; i<transactionCount; i++)
            if (   pending && !transactions[i].executed
                || executed && transactions[i].executed)
                count += 1;
    }

    /// @dev Returns list of owners.
    /// @return List of owner addresses.
    function getOwners()
        public
        constant
        returns (address[])
    {
        return owners;
    }

    /// @dev Returns array with owner addresses, which confirmed transaction.
    /// @param transactionId Transaction ID.
    /// @return Returns array of owner addresses.
    function getConfirmations(uint transactionId)
        public
        constant
        returns (address[] _confirmations)
    {
        address[] memory confirmationsTemp = new address[](owners.length);
        uint count = 0;
        uint i;
        for (i=0; i<owners.length; i++)
            if (confirmations[transactionId][owners[i]]) {
                confirmationsTemp[count] = owners[i];
                count += 1;
            }
        _confirmations = new address[](count);
        for (i=0; i<count; i++)
            _confirmations[i] = confirmationsTemp[i];
    }

    /// @dev Returns list of transaction IDs in defined range.
    /// @param from Index start position of transaction array.
    /// @param to Index end position of transaction array.
    /// @param pending Include pending transactions.
    /// @param executed Include executed transactions.
    /// @return Returns array of transaction IDs.
    function getTransactionIds(uint from, uint to, bool pending, bool executed)
        public
        constant
        returns (uint[] _transactionIds)
    {
        uint[] memory transactionIdsTemp = new uint[](transactionCount);
        uint count = 0;
        uint i;
        for (i=0; i<transactionCount; i++)
            if (   pending && !transactions[i].executed
                || executed && transactions[i].executed)
            {
                transactionIdsTemp[count] = i;
                count += 1;
            }
        _transactionIds = new uint[](to - from);
        for (i=from; i<to; i++)
            _transactionIds[i - from] = transactionIdsTemp[i];
    }
}

/**
 * @dev Interface of the ERC20 standard as defined in the EIP. Does not include
 * the optional functions; to access them see `ERC20Detailed`.
 */
contract ERC20 {
    function totalSupply() public returns (uint supply);
    function balanceOf(address _owner) public returns (uint balance);
    function transfer(address _to, uint _value) public returns (bool success);
    function transferFrom(address _from, address _to, uint _value) public returns (bool success);
    function approve(address _spender, uint _value) public returns (bool success);
    function allowance(address _owner, address _spender) public returns (uint remaining);
    function decimals() public returns(uint digits);
    event Approval(address indexed _owner, address indexed _spender, uint _value);
}
