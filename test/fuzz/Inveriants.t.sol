// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant

// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngin} from "../../src/DSCEngin.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC _deploy;
    DSCEngin _dscEngin;
    DecentralizedStableCoin _dsc;
    HelperConfig _config;
    address _weth;
    address _wbtc;
    Handler _handler;

    function setUp() external {
        _deploy = new DeployDSC();
        (_dsc, _dscEngin, _config) = _deploy.run();
        (,, _weth, _wbtc,) = _config.activeNetworkConfig();

        _handler = new Handler(_dscEngin, _dsc);
        targetContract(address(_handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
        uint256 totalSupply = _dsc.totalSupply();
        uint256 totalWethDeposited = ERC20Mock(_weth).balanceOf(address(_dscEngin));
        uint256 totalWbtcDeposited = ERC20Mock(_wbtc).balanceOf(address(_dscEngin));

        uint256 wethValue = _dscEngin.getUsdValue(_weth, totalWethDeposited);
        uint256 wbtcValue = _dscEngin.getUsdValue(_wbtc, totalWbtcDeposited);

        uint256 totalValue = wethValue + wbtcValue;

        console.log("weth value: ", wethValue);
        console.log("wbtc value: ", wbtcValue);
        console.log("total value: ", totalValue);
        console.log("Times mint called: ", _handler.timesMintIsCalled());

        require(totalValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        _dscEngin.getAccountCollateralValue(msg.sender);
        _dscEngin.getAccountInformation(msg.sender);
        _dscEngin.getAdditionalFeedPrecision();
        _dscEngin.getCollateralBalanceOfUser(msg.sender, _weth);
        _dscEngin.getCollateralTokenPriceFeed(msg.sender);
        _dscEngin.getCollateralTokens();
        _dscEngin.getDsc();
        _dscEngin.getHealthFactor(msg.sender);
        _dscEngin.getLiquidationBonus();
        _dscEngin.getLiquidationThreshold();
        _dscEngin.getMinHealthFactor();
        _dscEngin.getPrecision();
        _dscEngin.getTokenAmountFromUsd(_weth, 10);
        _dscEngin.getUsdValue(_weth, 10);
    }
}
