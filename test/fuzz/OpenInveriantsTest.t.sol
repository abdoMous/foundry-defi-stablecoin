// // 1. The total supply of DSC should be less than the total value of collateral
// // 2. Getter view functions should never revert <- evergreen invariant

// // SPDX-License-Identifier: SEE LICENSE IN LICENSE
// pragma solidity ^0.8.18;

// import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngin} from "../../src/DSCEngin.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deploy;
//     DSCEngin dscEngin;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deploy = new DeployDSC();
//         (dsc, dscEngin, config) = deploy.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();

//         targetContract(address(dscEngin));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsc));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsc));

//         uint256 wethValue = dscEngin.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscEngin.getUsdValue(wbtc, totalWbtcDeposited);

//         uint256 totalValue = wethValue + wbtcValue;

//         assert(totalValue >= totalSupply);
//     }
// }
