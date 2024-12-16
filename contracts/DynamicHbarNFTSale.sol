// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

// Import OpenZeppelin Ownable contracts and ERC721 / ERC20 interfaces
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Import Chainlink Aggregator Interface
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Import Hedera Precompile Contracts
import "./IHederaTokenService.sol";
import "./KeyHelper.sol"; // this imports HederaTokenService.sol so no need to import directly


contract DynamicHbarNFTSale is Ownable, HederaTokenService, KeyHelper {
    // Static NFT metadata
    bytes[] metadata;
    // NFT Address
    IERC721 public nft;
    // Price in USDC (considering USDC has 6 decimals)
    uint256 public priceInUSDC;
    // Chainlink Aggregator for HBAR/USD
    AggregatorV3Interface internal priceFeed;
    // USDC token contract
    IERC20 public usdcToken;

    error FailedNFTCreate();
    error FailedNFTMint();

    event NFTCreate(address nftAddress);
    event NFTMint(address nftAddress, int64 serial);

    /**
     * @dev Constructor initializes the ERC721 token, sets the seller, price, USDC address, and Chainlink price feed.
     * @param _priceInUSDC Price of the NFT in USDC (with 6 decimals).
     * @param _usdcAddress Address of the USDC token contract.
     */
    constructor(
        uint256 _priceInUSDC,
        address _usdcAddress,
        string memory _metadataString
    ) Ownable(msg.sender) {
        priceInUSDC = _priceInUSDC;
        usdcToken = IERC20(_usdcAddress);
        priceFeed = AggregatorV3Interface(0x59bC155EB6c6C415fE43255aF66EcF0523c92B4a);
        // Initialize metadata array with the provided string
        metadata.push(bytes(_metadataString));
    }

    /**
     * @dev Fetches the latest HBAR/USD price from Chainlink.
     * @return price The latest HBAR price in USD with 8 decimals.
     */
    function getLatestHBARPrice() public view returns (int256 price) {
        (
            /* uint80 roundID */,
            int256 answer,
            /* uint256 startedAt */,
            /* uint256 updatedAt */,
            /* uint80 answeredInRound */
        ) = priceFeed.latestRoundData();
        return answer;
    }

    /**
     * @dev Converts the USDC price to its equivalent in HBAR based on the latest price feed.
     * @return hbarAmount The equivalent amount in HBAR (with 18 decimals).
     */
    function convertUSDCToHBAR() public view returns (uint256 hbarAmount) {
        int256 price = getLatestHBARPrice(); // USD price with 8 decimals
        require(price > 0, "Invalid HBAR price");
        hbarAmount = (priceInUSDC * 1e10) / uint256(price); // this only works if USDC has 6 decimals!
        return hbarAmount;
    }

    /**
     * @dev Allows a user to purchase the NFT by transferring USDC to the seller.
     * The buyer must approve this contract to spend USDC beforehand.
     */
    function purchaseWithUSDC() external {
        // Transfer USDC from buyer to seller
        bool success = usdcToken.transferFrom(msg.sender, address(this), priceInUSDC);
        require(success, "USDC transfer failed");

        // mint NFT and return serial
        int64 serial = mintNFT();
        // Transfer NFT to buyer
        nft.transferFrom(address(this), msg.sender, uint256(uint64(serial)));
    }

    /**
     * @dev Allows a user to purchase the NFT by sending HBAR to the seller.
     * The contract converts USDC price to HBAR based on the latest price feed.
     * Note: HBAR transfers are handled natively; ensure the contract can receive HBAR.
     */
    function purchaseWithHBAR() external payable {
        uint256 hbarAmount = convertUSDCToHBAR();
        require(msg.value >= hbarAmount, "Insufficient HBAR sent");

        // Refund excess HBAR if any
        if (msg.value > hbarAmount) {
            (bool refund, ) = payable(msg.sender).call{value: msg.value - hbarAmount}("");
            require(refund, "Refund failed");
        }

        // mint NFT and return serial
        int64 serial = mintNFT();

        // Transfer NFT to buyer
        nft.transferFrom(address(this), msg.sender, uint256(uint64(serial)));
    }

    /**
     * @dev Creates a new non-fungible token using Hedera Token Service.
     * Only the owner can call this function.
     * @param _name Name of the token.
     * @param _symbol Symbol of the token.
     * @param _memo Memo for the token.
     */
    function createNFT(
        string memory _name,
        string memory _symbol,
        string memory _memo
    ) external payable onlyOwner {
        // instantiate the list of keys we'll use for token create
        // we will only use supply key
        IHederaTokenService.TokenKey[]
            memory _keys = new IHederaTokenService.TokenKey[](1);
        _keys[0] = getSingleKey(
            KeyType.SUPPLY,
            KeyValueType.CONTRACT_ID,
            address(this)
        );

        IHederaTokenService.HederaToken memory token;
        token.name = _name;
        token.symbol = _symbol;
        token.treasury = address(this);
        token.memo = _memo;
        token.tokenKeys = _keys;

        // Interact with HTS precompile
        (int responseCode, address tokenAddress) = createNonFungibleToken(token);
        if (responseCode != HederaResponseCodes.SUCCESS) {
            revert FailedNFTMint();
        }
        nft = IERC721(tokenAddress);
        emit NFTCreate(tokenAddress);
    }

    function mintNFT() private returns (int64 serial) {
        address nftAddress = address(nft);
        (int256 responseCode, , int64[] memory serialNumbers) = mintToken(
            nftAddress,
            0,
            metadata
        );

        if (responseCode != HederaResponseCodes.SUCCESS) {
            revert FailedNFTCreate();
        }

        serial = serialNumbers[0];
        emit NFTMint(nftAddress, serial);
    }

    /**
     * @dev Fallback function to receive HBAR.
     */
    receive() external payable {}
}
