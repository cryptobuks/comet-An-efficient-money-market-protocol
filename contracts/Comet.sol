// SPDX-License-Identifier: XXX ADD VALID LICENSE
pragma solidity ^0.8.11;

import "./CometBase.sol";
import "./ERC20.sol";

import "./vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title Compound's Comet Contract
 * @notice An efficient monolithic money market protocol
 * @author Compound
 */
contract Comet is CometBase {
    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice The number of decimals for wrapped base token
    uint8 public immutable decimals;

    /// @notice The admin of the protocol
    address public immutable governor;

    /// @notice The account which may trigger pauses
    address public immutable pauseGuardian;

    /// @notice The address of the base token contract
    address public immutable baseToken;

    /// @notice The address of the price feed for the base token
    address public immutable baseTokenPriceFeed;

    /// @notice The address of the extension contract delegate
    address public immutable extensionDelegate;

    /// @notice The point in the supply and borrow rates separating the low interest rate slope and the high interest rate slope (factor)
    /// @dev uint64
    uint public immutable kink;

    /// @notice Per second interest rate slope applied when utilization is below kink (factor)
    /// @dev uint64
    uint public immutable perSecondInterestRateSlopeLow;

    /// @notice Per second interest rate slope applied when utilization is above kink (factor)
    /// @dev uint64
    uint public immutable perSecondInterestRateSlopeHigh;

    /// @notice Per second base interest rate (factor)
    /// @dev uint64
    uint public immutable perSecondInterestRateBase;

    /// @notice The rate of total interest paid that goes into reserves (factor)
    /// @dev uint64
    uint public immutable reserveRate;

    /// @notice The scale for base token (must be less than 18 decimals)
    /// @dev uint64
    uint public immutable baseScale;

    /// @notice The scale for reward tracking
    uint64 public immutable trackingIndexScale;

    /// @notice The speed at which supply rewards are tracked (in trackingIndexScale)
    uint64 public immutable baseTrackingSupplySpeed;

    /// @notice The speed at which borrow rewards are tracked (in trackingIndexScale)
    uint64 public immutable baseTrackingBorrowSpeed;

    /// @notice The minimum amount of base wei for rewards to accrue
    /// @dev This must be large enough so as to prevent division by base wei from overflowing the 64 bit indices
    /// @dev uint104
    uint public immutable baseMinForRewards;

    /// @notice The minimum base amount required to initiate a borrow
    /// @dev uint104
    uint public immutable baseBorrowMin;

    /// @notice The minimum base token reserves which must be held before collateral is hodled
    uint104 public immutable targetReserves;

    /// @notice The number of assets this contract actually supports
    /// @dev uint8
    uint public immutable numAssets;

    /**  Collateral asset configuration (packed) **/

    uint256 internal immutable asset00_a;
    uint256 internal immutable asset00_b;
    uint256 internal immutable asset01_a;
    uint256 internal immutable asset01_b;
    uint256 internal immutable asset02_a;
    uint256 internal immutable asset02_b;
    uint256 internal immutable asset03_a;
    uint256 internal immutable asset03_b;
    uint256 internal immutable asset04_a;
    uint256 internal immutable asset04_b;
    uint256 internal immutable asset05_a;
    uint256 internal immutable asset05_b;
    uint256 internal immutable asset06_a;
    uint256 internal immutable asset06_b;
    uint256 internal immutable asset07_a;
    uint256 internal immutable asset07_b;
    uint256 internal immutable asset08_a;
    uint256 internal immutable asset08_b;
    uint256 internal immutable asset09_a;
    uint256 internal immutable asset09_b;
    uint256 internal immutable asset10_a;
    uint256 internal immutable asset10_b;
    uint256 internal immutable asset11_a;
    uint256 internal immutable asset11_b;
    uint256 internal immutable asset12_a;
    uint256 internal immutable asset12_b;
    uint256 internal immutable asset13_a;
    uint256 internal immutable asset13_b;
    uint256 internal immutable asset14_a;
    uint256 internal immutable asset14_b;

    /**
     * @notice Construct a new protocol instance
     * @param config The mapping of initial/constant parameters
     **/
    constructor(Configuration memory config) {
        // Sanity checks
        uint8 decimals_ = ERC20(config.baseToken).decimals();
        require(decimals_ <= MAX_BASE_DECIMALS, "too many decimals");
        require(config.assetConfigs.length <= MAX_ASSETS, "too many assets");
        require(config.baseMinForRewards > 0, "bad rewards min");
        require(AggregatorV3Interface(config.baseTokenPriceFeed).decimals() == PRICE_FEED_DECIMALS, "bad decimals");
        // XXX other sanity checks? for rewards?

        // Copy configuration
        decimals = decimals_;
        governor = config.governor;
        pauseGuardian = config.pauseGuardian;
        baseToken = config.baseToken;
        baseTokenPriceFeed = config.baseTokenPriceFeed;
        extensionDelegate = config.extensionDelegate;

        baseScale = uint64(10 ** decimals_);
        trackingIndexScale = config.trackingIndexScale;

        baseMinForRewards = config.baseMinForRewards;
        baseTrackingSupplySpeed = config.baseTrackingSupplySpeed;
        baseTrackingBorrowSpeed = config.baseTrackingBorrowSpeed;

        baseBorrowMin = config.baseBorrowMin;
        targetReserves = config.targetReserves;

        // Set interest rate model configs
        kink = config.kink;
        perSecondInterestRateSlopeLow = config.perYearInterestRateSlopeLow / SECONDS_PER_YEAR;
        perSecondInterestRateSlopeHigh = config.perYearInterestRateSlopeHigh / SECONDS_PER_YEAR;
        perSecondInterestRateBase = config.perYearInterestRateBase / SECONDS_PER_YEAR;
        reserveRate = config.reserveRate;

        // Set asset info
        numAssets = uint8(config.assetConfigs.length);

        (asset00_a, asset00_b) = _getPackedAsset(config.assetConfigs, 0);
        (asset01_a, asset01_b) = _getPackedAsset(config.assetConfigs, 1);
        (asset02_a, asset02_b) = _getPackedAsset(config.assetConfigs, 2);
        (asset03_a, asset03_b) = _getPackedAsset(config.assetConfigs, 3);
        (asset04_a, asset04_b) = _getPackedAsset(config.assetConfigs, 4);
        (asset05_a, asset05_b) = _getPackedAsset(config.assetConfigs, 5);
        (asset06_a, asset06_b) = _getPackedAsset(config.assetConfigs, 6);
        (asset07_a, asset07_b) = _getPackedAsset(config.assetConfigs, 7);
        (asset08_a, asset08_b) = _getPackedAsset(config.assetConfigs, 8);
        (asset09_a, asset09_b) = _getPackedAsset(config.assetConfigs, 9);
        (asset10_a, asset10_b) = _getPackedAsset(config.assetConfigs, 10);
        (asset11_a, asset11_b) = _getPackedAsset(config.assetConfigs, 11);
        (asset12_a, asset12_b) = _getPackedAsset(config.assetConfigs, 12);
        (asset13_a, asset13_b) = _getPackedAsset(config.assetConfigs, 13);
        (asset14_a, asset14_b) = _getPackedAsset(config.assetConfigs, 14);

        // Initialize storage
        initialize_storage();
    }

    /**
     * @notice Initialize storage for the contract
     * @dev Can be used from constructor or proxy
     */
    function initialize_storage() public {
        require(lastAccrualTime == 0, "re-init");

        // Initialize aggregates
        lastAccrualTime = getNow();
        baseSupplyIndex = BASE_INDEX_SCALE;
        baseBorrowIndex = BASE_INDEX_SCALE;
        trackingSupplyIndex = 0;
        trackingBorrowIndex = 0;
    }

    /**
     * @dev Gets the info for an asset or empty, for initialization
     */
    function _getAssetConfig(AssetConfig[] memory assetConfigs, uint i) internal pure returns (AssetConfig memory c) {
        if (i < assetConfigs.length) {
            assembly {
                c := mload(add(add(assetConfigs, 0x20), mul(i, 0x20)))
            }
        } else {
            c = AssetConfig({
                word_a: uint256(0),
                word_b: uint256(0)
            });
        }
    }

    /**
     * @dev Checks and gets the packed asset info for storage
     */
    function _getPackedAsset(AssetConfig[] memory assetConfigs, uint i) internal pure returns (uint256, uint256) {
        AssetConfig memory assetConfig = _getAssetConfig(assetConfigs, i);
        return (assetConfig.word_a, assetConfig.word_b);
    }

    /**
     * @notice Get the i-th asset info, according to the order they were passed in originally
     * @param i The index of the asset info to get
     * @return The asset info object
     */
    function getAssetInfo(uint8 i) public view returns (AssetInfo memory) {
        require(i < numAssets, "bad asset");

        uint256 word_a;
        uint256 word_b;

        if (i == 0) {
            word_a = asset00_a;
            word_b = asset00_b;
        } else if (i == 1) {
            word_a = asset01_a;
            word_b = asset01_b;
        } else if (i == 2) {
            word_a = asset02_a;
            word_b = asset02_b;
        } else if (i == 3) {
            word_a = asset03_a;
            word_b = asset03_b;
        } else if (i == 4) {
            word_a = asset04_a;
            word_b = asset04_b;
        } else if (i == 5) {
            word_a = asset05_a;
            word_b = asset05_b;
        } else if (i == 6) {
            word_a = asset06_a;
            word_b = asset06_b;
        } else if (i == 7) {
            word_a = asset07_a;
            word_b = asset07_b;
        } else if (i == 8) {
            word_a = asset08_a;
            word_b = asset08_b;
        } else if (i == 9) {
            word_a = asset09_a;
            word_b = asset09_b;
        } else if (i == 10) {
            word_a = asset10_a;
            word_b = asset10_b;
        } else if (i == 11) {
            word_a = asset11_a;
            word_b = asset11_b;
        } else if (i == 12) {
            word_a = asset12_a;
            word_b = asset12_b;
        } else if (i == 13) {
            word_a = asset13_a;
            word_b = asset13_b;
        } else if (i == 14) {
            word_a = asset14_a;
            word_b = asset14_b;
        } else {
            revert("absurd");
        }

        address asset = address(uint160(word_a & type(uint160).max));
        uint rescale = FACTOR_SCALE / 1e4;
        uint64 borrowCollateralFactor = uint64(((word_a >> 160) & type(uint16).max) * rescale);
        uint64 liquidateCollateralFactor = uint64(((word_a >> 176) & type(uint16).max) * rescale);
        uint64 liquidationFactor = uint64(((word_a >> 192) & type(uint16).max) * rescale);

        address priceFeed = address(uint160(word_b & type(uint160).max));
        uint8 decimals_ = uint8(((word_b >> 160) & type(uint8).max));
        uint64 scale = uint64(10 ** decimals_);
        uint128 supplyCap = uint128(((word_b >> 168) & type(uint64).max) * scale);

        return AssetInfo({
            offset: i,
            asset: asset,
            priceFeed: priceFeed,
            scale: scale,
            borrowCollateralFactor: borrowCollateralFactor,
            liquidateCollateralFactor: liquidateCollateralFactor,
            liquidationFactor: liquidationFactor,
            supplyCap: supplyCap
         });
    }

    /**
     * @dev Determine index of asset that matches given address
     */
    function getAssetInfoByAddress(address asset) internal view returns (AssetInfo memory) {
        for (uint8 i = 0; i < numAssets; i++) {
            AssetInfo memory assetInfo = getAssetInfo(i);
            if (assetInfo.asset == asset) {
                return assetInfo;
            }
        }
        revert("bad asset");
    }

    /**
     * @return The current timestamp
     **/
    function getNow() virtual internal view returns (uint40) {
        require(block.timestamp < 2**40, "timestamp too big");
        return uint40(block.timestamp);
    }

    /**
     * @dev Divide a number by an amount of base
     */
    function divBaseWei(uint n, uint baseWei) internal view returns (uint) {
        return n * baseScale / baseWei;
    }

    /**
     * @notice Accrue interest (and rewards) in base token supply and borrows
     **/
    function accrueInternal() internal {
        uint40 now_ = getNow();
        uint timeElapsed = now_ - lastAccrualTime;
        if (timeElapsed > 0) {
            uint supplyRate = getSupplyRateInternal(baseSupplyIndex, baseBorrowIndex, totalSupplyBase, totalBorrowBase);
            uint borrowRate = getBorrowRateInternal(baseSupplyIndex, baseBorrowIndex, totalSupplyBase, totalBorrowBase);
            baseSupplyIndex += safe64(mulFactor(baseSupplyIndex, supplyRate * timeElapsed));
            baseBorrowIndex += safe64(mulFactor(baseBorrowIndex, borrowRate * timeElapsed));
            if (totalSupplyBase >= baseMinForRewards) {
                uint supplySpeed = baseTrackingSupplySpeed;
                trackingSupplyIndex += safe64(divBaseWei(supplySpeed * timeElapsed, totalSupplyBase));
            }
            if (totalBorrowBase >= baseMinForRewards) {
                uint borrowSpeed = baseTrackingBorrowSpeed;
                trackingBorrowIndex += safe64(divBaseWei(borrowSpeed * timeElapsed, totalBorrowBase));
            }
        }
        lastAccrualTime = now_;
    }

    /**
     * @dev Calculate current per second supply rate given totals
     */
    function getSupplyRateInternal(uint64 baseSupplyIndex_, uint64 baseBorrowIndex_, uint104 totalSupplyBase_, uint104 totalBorrowBase_) internal view returns (uint64) {
        uint utilization = getUtilizationInternal(baseSupplyIndex_, baseBorrowIndex_, totalSupplyBase_, totalBorrowBase_);
        uint reserveScalingFactor = utilization * (FACTOR_SCALE - reserveRate) / FACTOR_SCALE;
        if (utilization <= kink) {
            // (interestRateBase + interestRateSlopeLow * utilization) * utilization * (1 - reserveRate)
            return safe64(mulFactor(reserveScalingFactor, (perSecondInterestRateBase + mulFactor(perSecondInterestRateSlopeLow, utilization))));
        } else {
            // (interestRateBase + interestRateSlopeLow * kink + interestRateSlopeHigh * (utilization - kink)) * utilization * (1 - reserveRate)
            return safe64(mulFactor(reserveScalingFactor, (perSecondInterestRateBase + mulFactor(perSecondInterestRateSlopeLow, kink) + mulFactor(perSecondInterestRateSlopeHigh, (utilization - kink)))));
        }
    }

    /**
     * @dev Calculate current per second borrow rate given totals
     */
    function getBorrowRateInternal(uint64 baseSupplyIndex_, uint64 baseBorrowIndex_, uint104 totalSupplyBase_, uint104 totalBorrowBase_) internal view returns (uint64) {
        uint utilization = getUtilizationInternal(baseSupplyIndex_, baseBorrowIndex_, totalSupplyBase_, totalBorrowBase_);
        if (utilization <= kink) {
            // interestRateBase + interestRateSlopeLow * utilization
            return safe64(perSecondInterestRateBase + mulFactor(perSecondInterestRateSlopeLow, utilization));
        } else {
            // interestRateBase + interestRateSlopeLow * kink + interestRateSlopeHigh * (utilization - kink)
            return safe64(perSecondInterestRateBase + mulFactor(perSecondInterestRateSlopeLow, kink) + mulFactor(perSecondInterestRateSlopeHigh, (utilization - kink)));
        }
    }

    /**
     * @dev Calculate utilization rate of the base asset given totals
     */
    function getUtilizationInternal(uint64 baseSupplyIndex, uint64 baseBorrowIndex, uint104 totalSupplyBase, uint104 totalBorrowBase) internal pure returns (uint) {
        uint totalSupply = presentValueSupply(baseSupplyIndex, totalSupplyBase);
        uint totalBorrow = presentValueBorrow(baseBorrowIndex, totalBorrowBase);
        if (totalSupply == 0) {
            return 0;
        } else {
            return totalBorrow * FACTOR_SCALE / totalSupply;
        }
    }

    /**
     * @notice Gets the total amount of protocol reserves, denominated in the number of base tokens
     */
    function getReserves() public view returns (int) {
        uint balance = ERC20(baseToken).balanceOf(address(this));
        uint104 totalSupply = presentValueSupply(baseSupplyIndex, totalSupplyBase);
        uint104 totalBorrow = presentValueBorrow(baseBorrowIndex, totalBorrowBase);
        return signed256(balance) - signed104(totalSupply) + signed104(totalBorrow);
    }

    /**
     * @notice Check whether an account has enough collateral to borrow
     * @param account The address to check
     * @return Whether the account is minimally collateralized enough to borrow
     */
    function isBorrowCollateralized(address account) public view returns (bool) {
        // XXX take in UserBasic and UserCollateral as arguments to reduce SLOADs
        uint16 assetsIn = userBasic[account].assetsIn;

        int liquidity = signedMulPrice(
            presentValue(userBasic[account].principal),
            getPrice(baseTokenPriceFeed),
            baseScale
        );

        for (uint8 i = 0; i < numAssets; i++) {
            if (isInAsset(assetsIn, i)) {
                if (liquidity >= 0) {
                    return true;
                }

                AssetInfo memory asset = getAssetInfo(i);
                uint newAmount = mulPrice(
                    userCollateral[account][asset.asset].balance,
                    getPrice(asset.priceFeed),
                    asset.scale
                );
                liquidity += signed256(mulFactor(
                    newAmount,
                    asset.borrowCollateralFactor
                ));
            }
        }

        return liquidity >= 0;
    }

    /**
     * @notice Check whether an account has enough collateral to not be liquidated
     * @param account The address to check
     * @return Whether the account is minimally collateralized enough to not be liquidated
     */
    function isLiquidatable(address account) public view returns (bool) {
        uint16 assetsIn = userBasic[account].assetsIn;

        int liquidity = signedMulPrice(
            presentValue(userBasic[account].principal),
            getPrice(baseTokenPriceFeed),
            baseScale
        );

        for (uint8 i = 0; i < numAssets; i++) {
            if (isInAsset(assetsIn, i)) {
                if (liquidity >= 0) {
                    return false;
                }

                AssetInfo memory asset = getAssetInfo(i);
                uint newAmount = mulPrice(
                    userCollateral[account][asset.asset].balance,
                    getPrice(asset.priceFeed),
                    asset.scale
                );
                liquidity += signed256(mulFactor(
                    newAmount,
                    asset.liquidateCollateralFactor
                ));
            }
        }

        return liquidity < 0;
    }

    /**
     * @return Whether or not supply actions are paused
     */
    function isSupplyPausedInternal() internal view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_SUPPLY_OFFSET));
    }

    /**
     * @return Whether or not transfer actions are paused
     */
    function isTransferPausedInternal() internal view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_TRANSFER_OFFSET));
    }

    /**
     * @return Whether or not withdraw actions are paused
     */
    function isWithdrawPausedInternal() internal view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_WITHDRAW_OFFSET));
    }

    /**
     * @return Whether or not absorb actions are paused
     */
    function isAbsorbPausedInternal() internal view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_ABSORB_OFFSET));
    }

    /**
     * @return Whether or not buy actions are paused
     */
    function isBuyPausedInternal() internal view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_BUY_OFFSET));
    }

    /**
     * @dev Whether user has a non-zero balance of an asset, given assetsIn flags
     */
    function isInAsset(uint16 assetsIn, uint8 assetOffset) internal pure returns (bool) {
        return (assetsIn & (uint16(1) << assetOffset) != 0);
    }

    /**
     * @dev The amounts broken into repay and supply amounts, given negative balance
     */
    function repayAndSupplyAmount(int104 balance, uint104 amount) internal pure returns (uint104, uint104) {
        uint104 repayAmount = balance < 0 ? min(unsigned104(-balance), amount) : 0;
        uint104 supplyAmount = amount - repayAmount;
        return (repayAmount, supplyAmount);
    }

    /**
     * @dev The amounts broken into withdraw and borrow amounts, given positive balance
     */
    function withdrawAndBorrowAmount(int104 balance, uint104 amount) internal pure returns (uint104, uint104) {
        uint104 withdrawAmount = balance > 0 ? min(unsigned104(balance), amount) : 0;
        uint104 borrowAmount = amount - withdrawAmount;
        return (withdrawAmount, borrowAmount);
    }

    /**
     * @notice Pauses different actions within Comet
     * @param supplyPaused Boolean for pausing supply actions
     * @param transferPaused Boolean for pausing transfer actions
     * @param withdrawPaused Boolean for pausing withdraw actions
     * @param absorbPaused Boolean for pausing absorb actions
     * @param buyPaused Boolean for pausing buy actions
     */
    function pause(
        bool supplyPaused,
        bool transferPaused,
        bool withdrawPaused,
        bool absorbPaused,
        bool buyPaused
    ) external {
        require(msg.sender == governor || msg.sender == pauseGuardian, "bad auth");

        pauseFlags =
            uint8(0) |
            (toUInt8(supplyPaused) << PAUSE_SUPPLY_OFFSET) |
            (toUInt8(transferPaused) << PAUSE_TRANSFER_OFFSET) |
            (toUInt8(withdrawPaused) << PAUSE_WITHDRAW_OFFSET) |
            (toUInt8(absorbPaused) << PAUSE_ABSORB_OFFSET) |
            (toUInt8(buyPaused) << PAUSE_BUY_OFFSET);
    }

    /**
     * @dev Update assetsIn bit vector if user has entered or exited an asset
     */
    function updateAssetsIn(
        address account,
        address asset,
        uint128 initialUserBalance,
        uint128 finalUserBalance
    ) internal {
        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        if (initialUserBalance == 0 && finalUserBalance != 0) {
            // set bit for asset
            userBasic[account].assetsIn |= (uint16(1) << assetInfo.offset);
        } else if (initialUserBalance != 0 && finalUserBalance == 0) {
            // clear bit for asset
            userBasic[account].assetsIn &= ~(uint16(1) << assetInfo.offset);
        }
    }

    /**
     * @dev Write updated balance to store and tracking participation
     */
    function updateBaseBalance(address account, UserBasic memory basic, int104 principalNew) internal {
        int104 principal = basic.principal;
        basic.principal = principalNew;

        if (principal >= 0) {
            uint indexDelta = trackingSupplyIndex - basic.baseTrackingIndex;
            basic.baseTrackingAccrued += safe64(uint104(principal) * indexDelta / BASE_INDEX_SCALE); // XXX decimals
        } else {
            uint indexDelta = trackingBorrowIndex - basic.baseTrackingIndex;
            basic.baseTrackingAccrued += safe64(uint104(-principal) * indexDelta / BASE_INDEX_SCALE); // XXX decimals
        }

        if (principalNew >= 0) {
            basic.baseTrackingIndex = trackingSupplyIndex;
        } else {
            basic.baseTrackingIndex = trackingBorrowIndex;
        }

        userBasic[account] = basic;
    }

    /**
     * @dev Safe ERC20 transfer in, assumes no fee is charged and amount is transferred
     */
    function doTransferIn(address asset, address from, uint amount) internal {
        bool success = ERC20(asset).transferFrom(from, address(this), amount);
        require(success, "bad transfer in");
    }

    /**
     * @dev Safe ERC20 transfer out
     */
    function doTransferOut(address asset, address to, uint amount) internal {
        bool success = ERC20(asset).transfer(to, amount);
        require(success, "bad transfer out");
    }

    /**
     * @notice Supply an amount of asset to the protocol
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supply(address asset, uint amount) external {
        return supplyInternal(msg.sender, msg.sender, msg.sender, asset, amount);
    }

    /**
     * @notice Supply an amount of asset to dst
     * @param dst The address which will hold the balance
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supplyTo(address dst, address asset, uint amount) external {
        return supplyInternal(msg.sender, msg.sender, dst, asset, amount);
    }

    /**
     * @notice Supply an amount of asset from `from` to dst, if allowed
     * @param from The supplier address
     * @param dst The address which will hold the balance
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supplyFrom(address from, address dst, address asset, uint amount) external {
        return supplyInternal(msg.sender, from, dst, asset, amount);
    }

    /**
     * @dev Supply either collateral or base asset, depending on the asset, if operator is allowed
     */
    function supplyInternal(address operator, address from, address dst, address asset, uint amount) internal {
        require(!isSupplyPausedInternal(), "paused");
        require(hasPermission(from, operator), "bad auth");

        if (asset == baseToken) {
            return supplyBase(from, dst, safe104(amount));
        } else {
            return supplyCollateral(from, dst, asset, safe128(amount));
        }
    }

    /**
     * @dev Supply an amount of base asset from `from` to dst
     */
    function supplyBase(address from, address dst, uint104 amount) internal {
        doTransferIn(baseToken, from, amount);

        accrueInternal();

        uint104 totalSupplyBalance = presentValueSupply(baseSupplyIndex, totalSupplyBase);
        uint104 totalBorrowBalance = presentValueBorrow(baseBorrowIndex, totalBorrowBase);

        UserBasic memory dstUser = userBasic[dst];
        int104 dstBalance = presentValue(dstUser.principal);

        (uint104 repayAmount, uint104 supplyAmount) = repayAndSupplyAmount(dstBalance, amount);

        totalSupplyBalance += supplyAmount;
        totalBorrowBalance -= repayAmount;

        dstBalance += signed104(amount);

        totalSupplyBase = principalValueSupply(baseSupplyIndex, totalSupplyBalance);
        totalBorrowBase = principalValueBorrow(baseBorrowIndex, totalBorrowBalance);

        updateBaseBalance(dst, dstUser, principalValue(dstBalance));
    }

    /**
     * @dev Supply an amount of collateral asset from `from` to dst
     */
    function supplyCollateral(address from, address dst, address asset, uint128 amount) internal {
        doTransferIn(asset, from, amount);

        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        TotalsCollateral memory totals = totalsCollateral[asset];
        totals.totalSupplyAsset += amount;
        require(totals.totalSupplyAsset <= assetInfo.supplyCap, "supply too big");

        uint128 dstCollateral = userCollateral[dst][asset].balance;
        uint128 dstCollateralNew = dstCollateral + amount;

        totalsCollateral[asset] = totals;
        userCollateral[dst][asset].balance = dstCollateralNew;

        updateAssetsIn(dst, asset, dstCollateral, dstCollateralNew);
    }

    /**
     * @notice ERC20 transfer an amount of base token to dst
     * @param dst The recipient address
     * @param amount The quantity to transfer
     * @return true
     */
    function transfer(address dst, uint amount) external returns (bool) {
        transferInternal(msg.sender, msg.sender, dst, baseToken, amount);
        return true;
    }

    /**
     * @notice ERC20 transfer an amount of base token from src to dst, if allowed
     * @param src The sender address
     * @param dst The recipient address
     * @param amount The quantity to transfer
     * @return true
     */
    function transferFrom(address src, address dst, uint amount) external returns (bool) {
        transferInternal(msg.sender, src, dst, baseToken, amount);
        return true;
    }

    /**
     * @notice Transfer an amount of asset to dst
     * @param dst The recipient address
     * @param asset The asset to transfer
     * @param amount The quantity to transfer
     */
    function transferAsset(address dst, address asset, uint amount) external {
        return transferInternal(msg.sender, msg.sender, dst, asset, amount);
    }

    /**
     * @notice Transfer an amount of asset from src to dst, if allowed
     * @param src The sender address
     * @param dst The recipient address
     * @param asset The asset to transfer
     * @param amount The quantity to transfer
     */
    function transferAssetFrom(address src, address dst, address asset, uint amount) external {
        return transferInternal(msg.sender, src, dst, asset, amount);
    }

    /**
     * @dev Transfer either collateral or base asset, depending on the asset, if operator is allowed
     */
    function transferInternal(address operator, address src, address dst, address asset, uint amount) internal {
        require(!isTransferPausedInternal(), "paused");
        require(hasPermission(src, operator), "bad auth");
        require(src != dst, "no self-transfer");

        if (asset == baseToken) {
            return transferBase(src, dst, safe104(amount));
        } else {
            return transferCollateral(src, dst, asset, safe128(amount));
        }
    }

    /**
     * @dev Transfer an amount of base asset from src to dst, borrowing if possible/necessary
     */
    function transferBase(address src, address dst, uint104 amount) internal {
        accrueInternal();

        uint104 totalSupplyBalance = presentValueSupply(baseSupplyIndex, totalSupplyBase);
        uint104 totalBorrowBalance = presentValueBorrow(baseBorrowIndex, totalBorrowBase);

        UserBasic memory srcUser = userBasic[src];
        UserBasic memory dstUser = userBasic[dst];
        int104 srcBalance = presentValue(srcUser.principal);
        int104 dstBalance = presentValue(dstUser.principal);

        (uint104 withdrawAmount, uint104 borrowAmount) = withdrawAndBorrowAmount(srcBalance, amount);
        (uint104 repayAmount, uint104 supplyAmount) = repayAndSupplyAmount(dstBalance, amount);

        totalSupplyBalance += supplyAmount - withdrawAmount;
        totalBorrowBalance += borrowAmount - repayAmount;

        srcBalance -= signed104(amount);
        dstBalance += signed104(amount);

        totalSupplyBase = principalValueSupply(baseSupplyIndex, totalSupplyBalance);
        totalBorrowBase = principalValueBorrow(baseBorrowIndex, totalBorrowBalance);

        updateBaseBalance(src, srcUser, principalValue(srcBalance));
        updateBaseBalance(dst, dstUser, principalValue(dstBalance));

        if (srcBalance < 0) {
            require(uint104(-srcBalance) >= baseBorrowMin, "borrow too small");
            require(isBorrowCollateralized(src), "bad borrow");
        }

        emit Transfer(src, dst, amount);
    }

    /**
     * @dev Transfer an amount of collateral asset from src to dst
     */
    function transferCollateral(address src, address dst, address asset, uint128 amount) internal {
        uint128 srcCollateral = userCollateral[src][asset].balance;
        uint128 dstCollateral = userCollateral[dst][asset].balance;
        uint128 srcCollateralNew = srcCollateral - amount;
        uint128 dstCollateralNew = dstCollateral + amount;

        userCollateral[src][asset].balance = srcCollateralNew;
        userCollateral[dst][asset].balance = dstCollateralNew;

        updateAssetsIn(src, asset, srcCollateral, srcCollateralNew);
        updateAssetsIn(dst, asset, dstCollateral, dstCollateralNew);

        // Note: no accrue interest, BorrowCF < LiquidationCF covers small changes
        require(isBorrowCollateralized(src), "bad borrow");
    }

    /**
     * @notice Withdraw an amount of asset from the protocol
     * @param asset The asset to withdraw
     * @param amount The quantity to withdraw
     */
    function withdraw(address asset, uint amount) external {
        return withdrawInternal(msg.sender, msg.sender, msg.sender, asset, amount);
    }

    /**
     * @notice Withdraw an amount of asset to `to`
     * @param to The recipient address
     * @param asset The asset to withdraw
     * @param amount The quantity to withdraw
     */
    function withdrawTo(address to, address asset, uint amount) external {
        return withdrawInternal(msg.sender, msg.sender, to, asset, amount);
    }

    /**
     * @notice Withdraw an amount of asset from src to `to`, if allowed
     * @param src The sender address
     * @param to The recipient address
     * @param asset The asset to withdraw
     * @param amount The quantity to withdraw
     */
    function withdrawFrom(address src, address to, address asset, uint amount) external {
        return withdrawInternal(msg.sender, src, to, asset, amount);
    }

    /**
     * @dev Withdraw either collateral or base asset, depending on the asset, if operator is allowed
     */
    function withdrawInternal(address operator, address src, address to, address asset, uint amount) internal {
        require(!isWithdrawPausedInternal(), "paused");
        require(hasPermission(src, operator), "bad auth");

        if (asset == baseToken) {
            return withdrawBase(src, to, safe104(amount));
        } else {
            return withdrawCollateral(src, to, asset, safe128(amount));
        }
    }

    /**
     * @dev Withdraw an amount of base asset from src to `to`, borrowing if possible/necessary
     */
    function withdrawBase(address src, address to, uint104 amount) internal {
        accrueInternal();

        uint104 totalSupplyBalance = presentValueSupply(baseSupplyIndex, totalSupplyBase);
        uint104 totalBorrowBalance = presentValueBorrow(baseBorrowIndex, totalBorrowBase);

        UserBasic memory srcUser = userBasic[src];
        int104 srcBalance = presentValue(srcUser.principal);

        (uint104 withdrawAmount, uint104 borrowAmount) = withdrawAndBorrowAmount(srcBalance, amount);

        totalSupplyBalance -= withdrawAmount;
        totalBorrowBalance += borrowAmount;

        srcBalance -= signed104(amount);

        totalSupplyBase = principalValueSupply(baseSupplyIndex, totalSupplyBalance);
        totalBorrowBase = principalValueBorrow(baseBorrowIndex, totalBorrowBalance);

        updateBaseBalance(src, srcUser, principalValue(srcBalance));

        if (srcBalance < 0) {
            require(uint104(-srcBalance) >= baseBorrowMin, "borrow too small");
            require(isBorrowCollateralized(src), "bad borrow");
        }

        doTransferOut(baseToken, to, amount);
    }

    /**
     * @dev Withdraw an amount of collateral asset from src to `to`
     */
    function withdrawCollateral(address src, address to, address asset, uint128 amount) internal {
        TotalsCollateral memory totals = totalsCollateral[asset];
        totals.totalSupplyAsset -= amount;

        uint128 srcCollateral = userCollateral[src][asset].balance;
        uint128 srcCollateralNew = srcCollateral - amount;

        totalsCollateral[asset] = totals;
        userCollateral[src][asset].balance = srcCollateralNew;

        updateAssetsIn(src, asset, srcCollateral, srcCollateralNew);

        // Note: no accrue interest, BorrowCF < LiquidationCF covers small changes
        require(isBorrowCollateralized(src), "bad borrow");

        doTransferOut(asset, to, amount);
    }

    /**
     * @notice Absorb a list of underwater accounts onto the protocol balance sheet
     * @param absorber The recipient of the incentive paid to the caller of absorb
     * @param accounts The list of underwater accounts to absorb
     */
    function absorb(address absorber, address[] calldata accounts) external {
        require(!isAbsorbPausedInternal(), "paused");

        uint startGas = gasleft();
        for (uint i = 0; i < accounts.length; i++) {
            absorbInternal(accounts[i]);
        }
        uint gasUsed = startGas - gasleft();

        LiquidatorPoints memory points = liquidatorPoints[absorber];
        points.numAbsorbs++;
        points.numAbsorbed += safe64(accounts.length);
        points.approxSpend += safe128(gasUsed * block.basefee);
        liquidatorPoints[absorber] = points;
    }

    /**
     * @dev Transfer user's collateral and debt to the protocol itself
     */
    function absorbInternal(address account) internal {
        accrueInternal();

        require(isLiquidatable(account), "not underwater");

        UserBasic memory accountUser = userBasic[account];
        int104 oldBalance = presentValue(accountUser.principal);
        uint16 assetsIn = accountUser.assetsIn;

        uint128 basePrice = getPrice(baseTokenPriceFeed);
        uint deltaValue = 0;

        for (uint8 i = 0; i < numAssets; i++) {
            if (isInAsset(assetsIn, i)) {
                AssetInfo memory assetInfo = getAssetInfo(i);
                address asset = assetInfo.asset;
                uint128 seizeAmount = userCollateral[account][asset].balance;
                if (seizeAmount > 0) {
                    userCollateral[account][asset].balance = 0;
                    userCollateral[address(this)][asset].balance += seizeAmount;

                    uint value = mulPrice(seizeAmount, getPrice(assetInfo.priceFeed), assetInfo.scale);
                    deltaValue += mulFactor(value, assetInfo.liquidationFactor);
                }
            }
        }

        uint104 deltaBalance = safe104(divPrice(deltaValue, basePrice, baseScale));
        int104 newBalance = oldBalance + signed104(deltaBalance);
        // New balance will not be negative, all excess debt absorbed by reserves
        newBalance = newBalance < 0 ? int104(0) : newBalance;
        updateBaseBalance(account, accountUser, principalValue(newBalance));

        // Reserves are decreased by increasing total supply and decreasing borrows
        //  the amount of debt repaid by reserves is `newBalance - oldBalance`
        // Note: new balance must be non-negative due to the above thresholding
        totalSupplyBase += principalValueSupply(baseSupplyIndex, unsigned104(newBalance));
        // Note: old balance must be negative since the account is liquidatable
        totalBorrowBase -= principalValueBorrow(baseBorrowIndex, unsigned104(-oldBalance));
    }

    /**
     * @notice Buy collateral from the protocol using base tokens, increasing protocol reserves
       A minimum collateral amount should be specified to indicate the maximum slippage acceptable for the buyer.
     * @param asset The asset to buy
     * @param minAmount The minimum amount of collateral tokens that should be received by the buyer
     * @param baseAmount The amount of base tokens used to buy the collateral
     * @param recipient The recipient address
     */
    function buyCollateral(address asset, uint minAmount, uint baseAmount, address recipient) external {
        require(!isBuyPausedInternal(), "paused");

        int reserves = getReserves();
        require(reserves < 0 || uint(reserves) < targetReserves, "not for sale");

        // XXX check re-entrancy
        doTransferIn(baseToken, msg.sender, baseAmount);

        uint collateralAmount = quoteCollateral(asset, baseAmount);
        require(collateralAmount >= minAmount, "too much slippage");

        withdrawCollateral(address(this), recipient, asset, safe128(collateralAmount));
    }

    /**
     * @notice Gets the quote for a collateral asset in exchange for an amount of base asset
     * @param asset The collateral asset to get the quote for
     * @param baseAmount The amount of the base asset to get the quote for
     * @return The quote in terms of the collateral asset
     */
    function quoteCollateral(address asset, uint baseAmount) public view returns (uint) {
        // XXX: Add StoreFrontDiscount.
        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        uint128 assetPrice = getPrice(assetInfo.priceFeed);
        uint128 basePrice = getPrice(baseTokenPriceFeed);
        uint assetWeiPerUnitBase = assetInfo.scale * basePrice / assetPrice;
        return assetWeiPerUnitBase * baseAmount / baseScale;
    }

    /**
     * @notice Withdraws base token reserves if called by the governor
     * @param to An address of the receiver of withdrawn reserves
     * @param amount The amount of reserves to be withdrawn from the protocol
     */
    function withdrawReserves(address to, uint amount) external {
        require(msg.sender == governor, "bad auth");
        require(amount <= unsigned256(getReserves()), "bad amount");
        doTransferOut(baseToken, to, amount);
    }

    /**
     * @notice Fallback to calling the extension delegate for everything else
     */
    fallback() external payable {
        address delegate = extensionDelegate;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), delegate, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
