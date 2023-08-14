// Handler is going to narrow down the scope of the fuzzing to a function
// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngin} from "../../src/DSCEngin.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngin _dscEngin;
    DecentralizedStableCoin _dsc;
    ERC20Mock _weth;
    ERC20Mock _wbtc;

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max; // 2^96 - 1

    constructor(DSCEngin dscEngin, DecentralizedStableCoin dsc) {
        _dscEngin = dscEngin;
        _dsc = dsc;
        address[] memory collateralTokens = _dscEngin.getCollateralTokens();
        _weth = ERC20Mock(collateralTokens[0]);
        _wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(_dscEngin.getCollateralTokenPriceFeed(address(_weth)));
    }

    // intructor solution
    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _dscEngin.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint == 0) {
            return;
        }

        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        _dscEngin.mintDSC(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    // my solution

    // function mintDsc(uint256 amount, uint256 collateralSeed, uint256 amountCollateral) public {
    //     depositCollateral(collateralSeed, amountCollateral);
    //     (uint256 totalDscMinted, uint256 collateralValueInUsd) = _dscEngin.getAccountInformation(msg.sender);

    //     int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
    //     if (maxDscToMint == 0) {
    //         return;
    //     }

    //     amount = bound(amount, 0, uint256(maxDscToMint));
    //     if (amount == 0) {
    //         return;
    //     }

    //     vm.startPrank(msg.sender);
    //     _dscEngin.mintDSC(amount);
    //     vm.stopPrank();
    //     timesMintIsCalled++;
    // }

    // redeem collateral
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(_dscEngin), amountCollateral);
        _dscEngin.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = _dscEngin.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        _dscEngin.redeemCollatoral(address(collateral), amountCollateral);
    }

    // This breaks our invariant test suite!!!
    // function updateCollateralPrice(uint256 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return _weth;
        }
        return _wbtc;
    }
}
