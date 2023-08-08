// SPDX-License-Identifier: SEE LICENSE IN LICENSE

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngin is ReentrancyGuard {
    ////////////
    // Errors //
    ////////////
    error DSCEngin__NeedsMoreThenZero();
    error DSCEngin__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngin__TokenNotSupported();
    error DSCEngin__TransferFailed();
    error DSCEngin__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngin__MintFailed();
    error DSCEngin__HealthFactorOk();
    error DSCEngin__HealthFactorNotImproved(uint256 healthFactor);
    ///////////////////
    // State Variables //
    /////////////////////

    uint256 private constant ADDITIOMAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus

    mapping(address token => address priceFeed) public s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256)) public s_collateralBalances;
    mapping(address use => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////
    // Events //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemd(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngin__NeedsMoreThenZero();
        }
        _;
    }

    modifier isSupportedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngin__TokenNotSupported();
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////

    /////////////////////////
    // External Functions //
    ////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngin__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /// @param tokenCollateralAddress The address of the token to deposit as collateral
    /// @param amountCollateral The amount of collateral to deposit
    /// @param amountDscToMint The amount of DSC to mint
    /// @notice this function is used to deposit collateral and mint DSC in one transaction
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /// @notice follows CEI
    /// @param tokenCollateralAddress The address of the token to deposit as collateral
    /// @param amountCollateral The amount of collateral to deposit
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isSupportedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralBalances[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngin__TransferFailed();
        }
    }

    // @param tokenCollateralAddress The address of the token to redeem
    // @param amountCollateral The amount of collateral to redeem
    // @param amoutDscToBurn The amount of DSC to burn
    // This function burns DSC and redeems underlying collateral in one transaction
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amoutDscToBurn)
        external
    {
        redeemCollatoral(tokenCollateralAddress, amountCollateral);
        burnDsc(amoutDscToBurn);
    }

    /// @notice follows CEI
    function redeemCollatoral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorisBroken(msg.sender);
    }

    // @notice follows CEI
    // @param amountDscToMint The amount of DSC to mint
    // @notic must have more collateral value thant the minimum threshold
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorisBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngin__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorisBroken(msg.sender); // I don't think this would ever hit
    }

    /// @param collateral The address of the collateral to liquidate
    /// @param user The address of the user to liquidate
    /// @param deptToCover The amount of DSC you want to burn to imporove the users health factor
    /// @notice this function is used to liquidate a user
    function liquidate(address collateral, address user, uint256 deptToCover)
        external
        moreThanZero(deptToCover)
        nonReentrant
    {
        // check health factor for user
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor > MIN_HEALTH_FACTOR) {
            revert DSCEngin__HealthFactorOk();
        }

        // burn DSC "debt" and take collateral
        uint256 tokenAmountFromDebtCoverd = getTokenAmountFromUsd(collateral, deptToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCoverd * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateral = tokenAmountFromDebtCoverd + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateral);

        // burn DSC
        _burnDsc(deptToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) {
            revert DSCEngin__HealthFactorNotImproved(endingHealthFactor);
        }
        _revertIfHealthFactorisBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    //////////////////////////////////
    // Private & Internal veiw Functions //
    //////////////////////////////////////

    /// @dev Low-level internal function, do not call unless the function calling it is
    /// checking for health factors being broken
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngin__MintFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralBalances[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemd(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngin__TransferFailed();
        }
    }

    // @returns how close to liquidation a user is
    // if a user goes below 1, then can get liquidated
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collatearlValueInUsd) = getAccountInformation(user);
        uint256 collateralAdjestedForThreshold = collatearlValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
        return collateralAdjestedForThreshold * PRECISION / totalDscMinted;
    }

    function _revertIfHealthFactorisBroken(address user) private view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngin__BreaksHealthFactor(healthFactor);
        }
    }

    //////////////////////////////////////
    // Public & External View Functions //
    /////////////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 collateralBalance = s_collateralBalances[user][token];
            totalCollateralValueInUsd += getUsdValue(token, collateralBalance);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIOMAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIOMAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);

        return (totalDscMinted, collateralValueInUsd);
    }
}
