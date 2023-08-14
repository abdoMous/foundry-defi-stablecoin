// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngin} from "../../src/DSCEngin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";

contract DSCEnginTest is Test {
    DeployDSC _deployDsc;
    DecentralizedStableCoin _dsc;
    DSCEngin _dscEngin;
    HelperConfig _config;
    address _ethUsdPriceFeed;
    address _btcUsdPriceFeed;
    address _weth;
    address _wbtc;

    address public userAddress = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    /////////////
    // Events //
    ///////////
    event CollateralRedeemd(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    function setUp() public {
        _deployDsc = new DeployDSC();
        (_dsc, _dscEngin, _config) = _deployDsc.run();
        (_ethUsdPriceFeed, _btcUsdPriceFeed, _weth, _wbtc,) = _config.activeNetworkConfig();

        ERC20Mock(_weth).mint(userAddress, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constractor Tests //
    ///////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLenthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(_weth);
        priceFeedAddresses.push(_ethUsdPriceFeed);
        priceFeedAddresses.push(_btcUsdPriceFeed);

        vm.expectRevert(DSCEngin.DSCEngin__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngin(tokenAddresses, priceFeedAddresses, address(_dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e8;
        uint256 expectedUsd = 30000e8;
        uint256 actualUsd = _dscEngin.getUsdValue(_weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = _dscEngin.getTokenAmountFromUsd(_weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    ////////////////////////////
    // depositCollateral Test //
    ////////////////////////////

    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [_ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngin mockDsce = new DSCEngin(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(userAddress, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(userAddress);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSCEngin.DSCEngin__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngin.DSCEngin__NeedsMoreThenZero.selector);
        _dscEngin.depositCollateral(_weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", userAddress, AMOUNT_COLLATERAL);
        vm.startPrank(userAddress);
        vm.expectRevert(DSCEngin.DSCEngin__TokenNotSupported.selector);
        _dscEngin.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        _dscEngin.depositCollateral(_weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        _dscEngin.depositCollateralAndMintDSC(_weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = _dsc.balanceOf(userAddress);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAcountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _dscEngin.getAccountInformation(userAddress);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = _dscEngin.getTokenAmountFromUsd(_weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    ///////////////////
    // mintDsc Tests //
    ///////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [_weth];
        priceFeedAddresses = [_ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngin mockDsce = new DSCEngin(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngin.DSCEngin__MintFailed.selector);
        mockDsce.depositCollateralAndMintDSC(_weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        _dscEngin.depositCollateralAndMintDSC(_weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngin.DSCEngin__NeedsMoreThenZero.selector);
        _dscEngin.mintDSC(0);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(userAddress);
        _dscEngin.mintDSC(AMOUNT_TO_MINT);

        uint256 userBalance = _dsc.balanceOf(userAddress);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    ///////////////////
    // burnDsc Tests //
    ///////////////////
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        _dscEngin.depositCollateralAndMintDSC(_weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngin.DSCEngin__NeedsMoreThenZero.selector);
        _dscEngin.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.startPrank(userAddress);
        vm.expectRevert();
        _dscEngin.burnDsc(1);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(userAddress);
        _dsc.approve(address(_dscEngin), AMOUNT_TO_MINT);
        _dscEngin.burnDsc(AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = _dsc.balanceOf(userAddress);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(_ethUsdPriceFeed).latestRoundData();
        uint256 amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * _dscEngin.getAdditionalFeedPrecision())) / _dscEngin.getPrecision();
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            _dscEngin.calculateHealthFactor(amountToMint, _dscEngin.getUsdValue(_weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngin.DSCEngin__BreaksHealthFactor.selector, expectedHealthFactor));
        _dscEngin.depositCollateralAndMintDSC(_weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = _dsc.balanceOf(userAddress);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    ///////////////////////////
    // redeemCollateral Test //
    ///////////////////////////
    // this test needs it's own setup
    // function testRevertsIfTransferFails() public {
    //     // Arrange - Setup
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     MockFailedTransfer mockDsc = new MockFailedTransfer();
    //     tokenAddresses = [address(mockDsc)];
    //     priceFeedAddresses = [_ethUsdPriceFeed];
    //     vm.prank(owner);
    //     DSCEngin mockDsce = new DSCEngin(
    //         tokenAddresses,
    //         priceFeedAddresses,
    //         address(mockDsc)
    //     );
    //     mockDsc.mint(userAddress, AMOUNT_COLLATERAL);

    //     vm.prank(owner);
    //     mockDsc.transferOwnership(address(mockDsce));
    //     // Arrange - User
    //     vm.startPrank(userAddress);
    //     ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
    //     // Act / Assert
    //     mockDsce.redeemCollatoral(address(mockDsc), AMOUNT_COLLATERAL);
    //     vm.expectRevert(DSCEngin.DSCEngin__TransferFailed.selector);
    //     mockDsce.redeemCollatoral(address(mockDsc), AMOUNT_COLLATERAL);
    //     vm.stopPrank();
    // }

    function testRevertsIfCollateralZeroToRedeemCollateral() public {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngin.DSCEngin__NeedsMoreThenZero.selector);
        _dscEngin.redeemCollatoral(_weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(userAddress);
        _dscEngin.redeemCollatoral(_weth, AMOUNT_COLLATERAL);
        uint256 userBallance = ERC20Mock(_weth).balanceOf(userAddress);
        assertEq(userBallance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.startPrank(userAddress);
        vm.expectEmit(true, true, true, true, address(_dscEngin));
        emit CollateralRedeemd(userAddress, userAddress, _weth, AMOUNT_COLLATERAL);
        _dscEngin.redeemCollatoral(_weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //////////////////////////////////
    // redeemCollateralForDsc Tests //
    /////////////////////////////////
    // function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
    //     vm.startPrank(userAddress);
    //     _dsc.approve(address(_dscEngin), AMOUNT_TO_MINT);
    //     vm.expectRevert(DSCEngin.DSCEngin__NeedsMoreThenZero.selector);
    //     _dscEngin.redeemCollateralForDSC(_weth, 0, AMOUNT_TO_MINT);
    //     vm.stopPrank();
    // }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        _dscEngin.depositCollateralAndMintDSC(_weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        _dsc.approve(address(_dscEngin), AMOUNT_TO_MINT);
        _dscEngin.redeemCollateralForDSC(_weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = _dsc.balanceOf(userAddress);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////
    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;

        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        uint256 actualHealthFactor = _dscEngin.getHealthFactor(userAddress);
        assertEq(actualHealthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $150 at all times if we have $100 of debt

        MockV3Aggregator(_ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = _dscEngin.getHealthFactor(userAddress);
        // $180 collateral / 200 debt = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////
    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(_ethUsdPriceFeed);
        tokenAddresses = [_weth];
        priceFeedAddresses = [_ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngin mockDsce = new DSCEngin(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDSC(_weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(_weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(_weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDSC(_weth, collateralToCover, AMOUNT_TO_MINT);
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(_ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngin.DSCEngin__HealthFactorNotImproved.selector);
        mockDsce.liquidate(_weth, userAddress, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(_weth).mint(liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(_weth).approve(address(_dscEngin), collateralToCover);
        _dscEngin.depositCollateralAndMintDSC(_weth, collateralToCover, AMOUNT_TO_MINT);
        _dsc.approve(address(_dscEngin), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngin.DSCEngin__HealthFactorOk.selector);
        _dscEngin.liquidate(_weth, userAddress, collateralToCover);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        _dscEngin.depositCollateralAndMintDSC(_weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(_ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        ERC20Mock(_weth).mint(liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(_weth).approve(address(_dscEngin), collateralToCover);
        _dscEngin.depositCollateralAndMintDSC(_weth, collateralToCover, AMOUNT_TO_MINT);
        _dsc.approve(address(_dscEngin), AMOUNT_TO_MINT);
        _dscEngin.liquidate(_weth, userAddress, collateralToCover);
        vm.stopPrank();

        _;
    }

    // function testLiquidationPayoutIsCorrect() public liquidated {
    //     uint256 liquidatorWethBalance = ERC20Mock(_weth).balanceOf(liquidator);
    //     uint256 expectedWeth = _dscEngin.getTokenAmountFromUsd(_weth, AMOUNT_TO_MINT)
    //         + (_dscEngin.getTokenAmountFromUsd(_weth, AMOUNT_TO_MINT) / _dscEngin.getLiquidationBonus());
    //     uint256 hardCodedExpected = 6111111111111111110;
    //     assertEq(liquidatorWethBalance, hardCodedExpected);
    //     assertEq(liquidatorWethBalance, expectedWeth);
    // }

    // function testUserStillHasSomeEthAfterLiquidation() public liquidated {
    //     uint256 amoutLiquidated = _dscEngin.getTokenAmountFromUsd(_weth, AMOUNT_TO_MINT)
    //         + (_dscEngin.getTokenAmountFromUsd(_weth, AMOUNT_TO_MINT) / _dscEngin.getLiquidationBonus());

    //     uint256 usdAmountLiquidated = _dscEngin.getUsdValue(_weth, amoutLiquidated);
    //     uint256 expectedUserCollateralValueInUsd = _dscEngin.getUsdValue(_weth, AMOUNT_COLLATERAL) - usdAmountLiquidated;
    //     (, uint256 userCollateralValueInUsd) = _dscEngin.getAccountInformation(userAddress);
    //     uint256 hardCodedExpectedValue = 70000000000000000020;
    //     assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
    //     assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    // }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = _dscEngin.getAccountInformation(liquidator);
        uint256 expectedDsc = AMOUNT_TO_MINT;
        assertEq(liquidatorDscMinted, expectedDsc);
    }

    // function testUserHasNoMoreDept() public liquidated {
    //     (uint256 userDscMinted,) = _dscEngin.getAccountInformation(userAddress);
    //     assertEq(userDscMinted, 0);
    // }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address expectedPriceFeed = _ethUsdPriceFeed;
        address actualPriceFeed = _dscEngin.getCollateralTokenPriceFeed(_weth);
        assertEq(actualPriceFeed, expectedPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = _dscEngin.getCollateralTokens();
        assertEq(collateralTokens[0], _weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = _dscEngin.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = _dscEngin.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = _dscEngin.getAccountInformation(userAddress);
        uint256 expectedCollateralValue = _dscEngin.getUsdValue(_weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        _dscEngin.depositCollateral(_weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 collateralBalance = _dscEngin.getCollateralBalanceOfUser(userAddress, _weth);

        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(userAddress);
        ERC20Mock(_weth).approve(address(_dscEngin), AMOUNT_COLLATERAL);
        _dscEngin.depositCollateral(_weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 collateralValue = _dscEngin.getAccountCollateralValue(userAddress);
        uint256 expectedCollateralValue = _dscEngin.getUsdValue(_weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = _dscEngin.getDsc();
        assertEq(dscAddress, address(_dsc));
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedDsc {
    //     MockV3Aggregator(_ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = _dsc.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(_weth).balanceOf(address(_dscEngin));
    //     uint256 wbtcDeposited = ERC20Mock(_wbtc).balanceOf(address(_dscEngin));

    //     uint256 wethValue = _dscEngin.getUsdValue(_weth, wethDeposted);
    //     uint256 wbtcValue = _dscEngin.getUsdValue(_wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
