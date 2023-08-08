// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngin} from "../../src/DSCEngin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEnginTest is Test {
    DeployDSC _deployDsc;
    DecentralizedStableCoin _dsc;
    DSCEngin _dscEngin;
    HelperConfig _config;
    address _ethUsdPriceFeed;
    address _btcUsdPriceFeed;
    address _weth;

    address public userAddress = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        _deployDsc = new DeployDSC();
        (_dsc, _dscEngin, _config) = _deployDsc.run();
        (_ethUsdPriceFeed, _btcUsdPriceFeed, _weth,,) = _config.activeNetworkConfig();

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

    function testCanDepositCollateralAndGetAcountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _dscEngin.getAccountInformation(userAddress);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = _dscEngin.getTokenAmountFromUsd(_weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }
}
