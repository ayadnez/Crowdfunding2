pragma solidity ^0.8.2;
contract ERC721Mochi is ERC721, ERC721Enumerable, ERC721URIStorage, AccessControlEnumerable, ERC721Burnable {
    using Counters for Counters.Counter;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    Counters.Counter private _tokenIdCounter;
    bool public anyoneCanMint;

    constructor(address owner, string memory name, string memory symbol, bool _anyoneCanMint) ERC721(name, symbol) {
        _setupRole(DEFAULT_ADMIN_ROLE, owner);
        _setupRole(MINTER_ROLE, owner);
        anyoneCanMint = _anyoneCanMint;
    }

    function autoMint(string memory _tokenURI, address to) public onlyMinter {
        uint id;
        do {
          _tokenIdCounter.increment();
          id = _tokenIdCounter.current();
        } while(_exists(id));
        _mint(to, id);
        _setTokenURI(id, _tokenURI);
    }

    function mint(address to, uint256 tokenId) public onlyMinter {
        _mint(to, tokenId);
    }

    function safeMint(address to, uint256 tokenId) public onlyMinter {
        _safeMint(to, tokenId);
    }

    function isMinter(address account) public view returns (bool) {
        return hasRole(MINTER_ROLE, account);
    }

    function safeMint(address to, uint256 tokenId, bytes memory _data) public onlyMinter {
        _safeMint(to, tokenId, _data);
    }

    function _burn(uint256 tokenId) internal virtual override(ERC721, ERC721URIStorage) {
        ERC721URIStorage._burn(tokenId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControlEnumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function addMinter(address account) public onlyRole(MINTER_ROLE) {
        grantRole(MINTER_ROLE, account);
    }

    function canIMint() public view returns (bool) {
        return anyoneCanMint || isMinter(msg.sender);
    }

    /**
     * Open modifier to anyone can mint possibility
     */
    modifier onlyMinter() {
        string memory mensaje;
        require(
            canIMint(),
            "MinterRole: caller does not have the Minter role"
        );
        _;
    }

}
contract ERC721Suika is ERC721Mochi, ReentrancyGuard {

    using SafeMath for uint256;

    using Address for address payable;
    using Address for address;

    // admin address, the owner of the marketplace
    address payable admin;

    address public contract_owner;

    // ERC20 token to be used for payments
    EIP20 public payment_token;

    // commission rate is a value from 0 to 100
    uint256 commissionRate;

    // royalties commission rate is a value from 0 to 100
    uint256 royaltiesCommissionRate;

    // nft item creators list, used to pay royalties
    mapping(uint256 => address) public creators;
    
    // last price sold or auctioned
    mapping(uint256 => uint256) public soldFor;
    
    // Mapping from token ID to sell price in Ether or to bid price, depending if it is an auction or not
    mapping(uint256 => uint256) public sellBidPrice;

    // Mapping payment address for tokenId 
    mapping(uint256 => address payable) private _wallets;

    event Sale(uint256 indexed tokenId, address indexed from, address indexed to, uint256 value);
    event Commission(uint256 indexed tokenId, address indexed to, uint256 value, uint256 rate, uint256 total);
    event Royalty(uint256 indexed tokenId, address indexed to, uint256 value, uint256 rate, uint256 total);

    // Auction data
    struct Auction {

        // Parameters of the auction. Times are either
        // absolute unix timestamps (seconds since 1970-01-01)
        // or time periods in seconds.
        address payable beneficiary;
        uint auctionEnd;

        // Current state of the auction.
        address payable highestBidder;
        uint highestBid;

        // Set to true at the end, disallows any change
        bool open;

        // minimum reserve price in wei
        uint256 reserve;

    }

    // mapping auctions for each tokenId
    mapping(uint256 => Auction) public auctions;

    // Events that will be fired on changes.
    event Refund(address bidder, uint amount);
    event HighestBidIncreased(address indexed bidder, uint amount, uint256 tokenId);
    event AuctionEnded(address winner, uint amount);

    event LimitSell(address indexed from, address indexed to, uint256 amount);
    event LimitBuy(address indexed from, address indexed to, uint256 amount);
    event MarketSell(address indexed from, address indexed to, uint256 amount);
    event MarketBuy(address indexed from, address indexed to, uint256 amount);

    constructor(
        EIP20 _payment_token, address _owner, address payable _admin, 
        uint256 _commissionRate, uint256 _royaltiesCommissionRate, string memory name, string memory symbol, bool _anyoneCanMint) 
        ERC721Mochi(_owner, name, symbol, _anyoneCanMint) 
    {
        admin = _admin;
        contract_owner = _owner;
        require(_commissionRate<=100, "ERC721Suika: Commission rate has to be between 0 and 100");
        commissionRate = _commissionRate;
        royaltiesCommissionRate = _royaltiesCommissionRate;
        payment_token = _payment_token;
    }

    function canSell(uint256 tokenId) public view returns (bool) {
        return (ownerOf(tokenId)==msg.sender && !auctions[tokenId].open);
    }

    // Sell option for a fixed price
    function sell(uint256 tokenId, uint256 price, address payable wallet) public {

        // onlyOwner
        require(ownerOf(tokenId)==msg.sender, "ERC721Suika: Only owner can sell this item");

        // cannot set a price if auction is activated
        require(!auctions[tokenId].open, "ERC721Suika: Cannot sell an item which has an active auction");

        // set sell price for index
        sellBidPrice[tokenId] = price;

        // If price is zero, means not for sale
        if (price>0) {

            // approve the Index to the current contract
            approve(address(this), tokenId);
            
            // set wallet payment
            _wallets[tokenId] = wallet;
            
        }

    }

    // simple function to return the price of a tokenId
    // returns: sell price, bid price, sold price, only one can be non zero
    function getPrice(uint256 tokenId) public view returns (uint256, uint256, uint256) {
        if (sellBidPrice[tokenId]>0) return (sellBidPrice[tokenId], 0, 0);
        if (auctions[tokenId].highestBid>0) return (0, auctions[tokenId].highestBid, 0);
        return (0, 0, soldFor[tokenId]);
    }

    function canBuy(uint256 tokenId) public view returns (uint256) {
        if (!auctions[tokenId].open && sellBidPrice[tokenId]>0 && sellBidPrice[tokenId]>0 && getApproved(tokenId) == address(this)) {
            return sellBidPrice[tokenId];
        } else {
            return 0;
        }
    }

    // Buy option
    function buy(uint256 tokenId) public nonReentrant {

        // is on sale
        require(!auctions[tokenId].open && sellBidPrice[tokenId]>0, "ERC721Suika: The collectible is not for sale");

        // transfer ownership
        address owner = ownerOf(tokenId);

        require(msg.sender!=owner, "ERC721Suika: The seller cannot buy his own collectible");

        // we need to call a transferFrom from this contract, which is the one with permission to sell the NFT
        callOptionalReturn(this, abi.encodeWithSelector(this.transferFrom.selector, owner, msg.sender, tokenId));

        // calculate amounts
        uint256 amount4admin = sellBidPrice[tokenId].mul(commissionRate).div(100);
        uint256 amount4creator = sellBidPrice[tokenId].mul(royaltiesCommissionRate).div(100);
        uint256 amount4owner = sellBidPrice[tokenId].sub(amount4admin).sub(amount4creator);

        // to owner
        require(payment_token.transferFrom(msg.sender, _wallets[tokenId], amount4owner), "Transfer failed.");

        // to creator
        if (amount4creator>0) {
            require(payment_token.transferFrom(msg.sender, creators[tokenId], amount4creator), "Transfer failed.");
        }

        // to admin
        if (amount4admin>0) {
            require(payment_token.transferFrom(msg.sender, admin, amount4admin), "Transfer failed.");
        }

        emit Sale(tokenId, owner, msg.sender, sellBidPrice[tokenId]);
        emit Commission(tokenId, owner, sellBidPrice[tokenId], commissionRate, amount4admin);
        emit Royalty(tokenId, owner, sellBidPrice[tokenId], royaltiesCommissionRate, amount4creator);

        soldFor[tokenId] = sellBidPrice[tokenId];

        // close the sell
        sellBidPrice[tokenId] = 0;
        delete _wallets[tokenId];

    }

    function canAuction(uint256 tokenId) public view returns (bool) {
        return (ownerOf(tokenId)==msg.sender && !auctions[tokenId].open && sellBidPrice[tokenId]==0);
    }

    // Instantiate an auction contract for a tokenId
    function createAuction(uint256 tokenId, uint _closingTime, address payable _beneficiary, uint256 _reservePrice) public {

        require(sellBidPrice[tokenId]==0, "ERC721Suika: The selected NFT is open for sale, cannot be auctioned");
        require(!auctions[tokenId].open, "ERC721Suika: The selected NFT already has an auction");
        require(ownerOf(tokenId)==msg.sender, "ERC721Suika: Only owner can auction this item");

        auctions[tokenId].beneficiary = _beneficiary;
        auctions[tokenId].auctionEnd = _closingTime;
        auctions[tokenId].reserve = _reservePrice;
        auctions[tokenId].open = true;

        // approve the Index to the current contract
        approve(address(this), tokenId);

    }

    function canBid(uint256 tokenId) public view returns (bool) {
        if (!msg.sender.isContract() &&
            auctions[tokenId].open &&
            block.timestamp <= auctions[tokenId].auctionEnd &&
            msg.sender != ownerOf(tokenId) &&
            getApproved(tokenId) == address(this)
        ) {
            return true;
        } else {
            return false;
        }
    }

    /// Overrides minting function to keep track of item creators
    function _mint(address to, uint256 tokenId) override internal {
        creators[tokenId] = msg.sender;
        super._mint(to, tokenId);
    }

    /// Bid on the auction with the value sent
    /// together with this transaction.
    /// The value will only be refunded if the
    /// auction is not won.
    function bid(uint256 tokenId, uint256 bid_value) public nonReentrant {

        // Contracts cannot bid, because they can block the auction with a reentrant attack
        require(!msg.sender.isContract(), "No script kiddies");

        // auction has to be opened
        require(auctions[tokenId].open, "No opened auction found");

        // approve was lost
        require(getApproved(tokenId) == address(this), "Cannot complete the auction");

        // Revert the call if the bidding
        // period is over.
        require(
            block.timestamp <= auctions[tokenId].auctionEnd,
            "Auction already ended."
        );

        // If the bid is not higher, send the
        // money back.
        require(
            bid_value > auctions[tokenId].highestBid,
            "There already is a higher bid."
        );

        address owner = ownerOf(tokenId);
        require(msg.sender!=owner, "ERC721Suika: The owner cannot bid his own collectible");

        // return the funds to the previous bidder, if there is one
        if (auctions[tokenId].highestBid>0) {
            require(payment_token.transfer(auctions[tokenId].highestBidder, auctions[tokenId].highestBid), "Transfer failed.");
            emit Refund(auctions[tokenId].highestBidder, auctions[tokenId].highestBid);
        }

        // now store the bid data
        auctions[tokenId].highestBidder = payable(msg.sender);

        // transfer tokens to contract
        require(payment_token.transferFrom(msg.sender, address(this), bid_value), "Transfer failed.");

        // register the highest bid value
        auctions[tokenId].highestBid = bid_value;

        emit HighestBidIncreased(msg.sender, bid_value, tokenId);

    }

    // anyone can execute withdraw if auction is opened and 
    // the bid time expired and the reserve was not met
    // or
    // the auction is openen but the contract is unable to transfer
    function canWithdraw(uint256 tokenId) public view returns (bool) {
        if (auctions[tokenId].open && 
            (
                (
                    block.timestamp >= auctions[tokenId].auctionEnd &&
                    auctions[tokenId].highestBid > 0 &&
                    auctions[tokenId].highestBid<auctions[tokenId].reserve
                ) || 
                getApproved(tokenId) != address(this)
            )
        ) {
            return true;
        } else {
            return false;
        }
    }

    /// Withdraw a bid when the auction is not finalized
    function withdraw(uint256 tokenId) public nonReentrant {

        require(canWithdraw(tokenId), "Conditions to withdraw are not met");

        // transfer funds to highest bidder always
        if (auctions[tokenId].highestBid > 0) {
            require(payment_token.transfer(auctions[tokenId].highestBidder, auctions[tokenId].highestBid), "Transfer failed.");
        }

        // finalize the auction
        delete auctions[tokenId];

    }

    function canFinalize(uint256 tokenId) public view returns (bool) {
        if (auctions[tokenId].open && 
            block.timestamp >= auctions[tokenId].auctionEnd &&
            (
                auctions[tokenId].highestBid>=auctions[tokenId].reserve || 
                auctions[tokenId].highestBid==0
            )
        ) {
            return true;
        } else {
            return false;
        }
    }

    // implement the auctionFinalize including the NFT transfer logic
    function auctionFinalize(uint256 tokenId) public nonReentrant {

        require(canFinalize(tokenId), "Cannot finalize");

        if (auctions[tokenId].highestBid>0) {

            // transfer the ownership of token to the highest bidder
            address payable _highestBidder = auctions[tokenId].highestBidder;

            // calculate payment amounts
            uint256 amount4admin = auctions[tokenId].highestBid.mul(commissionRate).div(100);
            uint256 amount4creator = auctions[tokenId].highestBid.mul(royaltiesCommissionRate).div(100);
            uint256 amount4owner = auctions[tokenId].highestBid.sub(amount4admin).sub(amount4creator);

            // to owner
            require(payment_token.transfer(auctions[tokenId].beneficiary, amount4owner), "Transfer failed.");

            // to creator
            if (amount4creator>0) {
                require(payment_token.transfer(creators[tokenId], amount4creator), "Transfer failed.");
            }

            // to admin
            if (amount4admin>0) {
                require(payment_token.transfer(admin, amount4admin), "Transfer failed.");
            }

            emit Sale(tokenId, auctions[tokenId].beneficiary, _highestBidder, auctions[tokenId].highestBid);
            emit Royalty(tokenId, auctions[tokenId].beneficiary, auctions[tokenId].highestBid, royaltiesCommissionRate, amount4creator);
            emit Commission(tokenId, auctions[tokenId].beneficiary, auctions[tokenId].highestBid, commissionRate, amount4admin);

            // transfer ownership
            address owner = ownerOf(tokenId);

            // we need to call a transferFrom from this contract, which is the one with permission to sell the NFT
            // transfer the NFT to the auction's highest bidder
            callOptionalReturn(this, abi.encodeWithSelector(this.transferFrom.selector, owner, _highestBidder, tokenId));

            soldFor[tokenId] = auctions[tokenId].highestBid;

        }

        emit AuctionEnded(auctions[tokenId].highestBidder, auctions[tokenId].highestBid);

        // finalize the auction
        delete auctions[tokenId];

    }

    // Bid query functions
    function highestBidder(uint256 tokenId) public view returns (address payable) {
        return auctions[tokenId].highestBidder;
    }

    function highestBid(uint256 tokenId) public view returns (uint256) {
        return auctions[tokenId].highestBid;
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function callOptionalReturn(IERC721 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves.

        // A Solidity high level call has three parts:
        //  1. The target address is checked to verify it contains contract code
        //  2. The call itself is made, and success asserted
        //  3. The return value is decoded, which in turn checks the size of the returned data.
        // solhint-disable-next-line max-line-length
        require(address(token).isContract(), "SafeERC721: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC721: low-level call failed");

        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC721: ERC20 operation did not succeed");
        }
    }

    // update contract fields
    function updateAdmin(address payable _admin, uint256 _commissionRate, uint256 _royaltiesCommissionRate, bool _anyoneCanMint, EIP20 _payment_token) public {
        require(msg.sender==contract_owner, "Only contract owner can do this");
        admin = _admin;
        commissionRate = _commissionRate;
        royaltiesCommissionRate = _royaltiesCommissionRate;
        anyoneCanMint = _anyoneCanMint;
        payment_token = _payment_token;
    }

}