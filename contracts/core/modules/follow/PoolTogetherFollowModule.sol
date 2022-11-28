// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import {IFollowModule} from '../../../interfaces/IFollowModule.sol';
import {ILensHub} from '../../../interfaces/ILensHub.sol';
import {Errors} from '../../../libraries/Errors.sol';
import {FeeModuleBase} from '../FeeModuleBase.sol';
import {ModuleBase} from '../ModuleBase.sol';
import {IModuleGlobals} from '../../../interfaces/IModuleGlobals.sol';
import {FollowValidatorFollowModuleBase} from './FollowValidatorFollowModuleBase.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

/**
 * @notice A struct containing the necessary data to execute follow actions on a given profile.
 *
 * @param amount The following cost associated with this profile.
 * @param lockDuration The lock duration of the delegation.
 * @param currency The currency associated with this profile.
 * @param recipient The recipient address associated with this profile.
 */
struct ProfileData {
    uint256 amount;
    uint256 lockDuration;
    address currency;
    address recipient;
}

// Interfaces Delegation PoolTogether
interface ITWABDelegator {
    // @notice Creates a new delegation.
    // @param delegator Address of the delegator that will be able to handle the delegation
    // @param slot Slot of the delegation
    // @param delegatee Address of the delegatee
    // @param lockDuration Duration of time for which the delegation is locked. Must be less than the max duration.
    // @return Returns the address of the Delegation contract that will hold the tickets
    function createDelegation(
        address delegatorAddress,
        uint256 slot,
        address delegatee,
        uint256 lockDuration) external returns (address);

    // @notice Fund a delegation by transferring tickets from the caller to the delegation
    // @param delegator Address of the delegator
    // @param slot Slot of the delegation
    // @param amount Amount of tickets to fund
    function fundDelegation(
        address,
        uint256,
        uint256
    ) external returns (address);

    // @notice Withdraw tickets from a delegation.
    // @param delegatorAddress Address of the delegator
    // @param slot Slot of the delegation
    // @param amount Amount of tickets to withdraw
    // @return contract The address of the Delegation
    function withdrawDelegationToStake(
        address delegatorAddress,
        uint256 slot,
        uint256 amount
    ) external returns (address);
}

// Intergace Prize Pool PoolTogether
interface IPrizePool {
    // @notice Deposit assets into the Prize Pool in exchange for tokens
    // @param to The address receiving the newly minted tokens
    // @param amount The amount of assets to deposit
    function depositTo(address to, uint256 amount) external;
}

// New Error
    error NoPrizePool();
    error UndelegateTimeNotReached();
    error NotTheRecipient();

/**
 * @title PoolTogetherFollowModule
 * @author NelsonRodMar.lens
 *
 * @notice This is a simple PoolTogether implementation in a FollowModule, inheriting from the IFollowModule interface.
 *
 */
contract PoolTogetherFollowModule is FeeModuleBase, ModuleBase, FollowValidatorFollowModuleBase {
    uint256 public constant MAX_LOCK = 180 days;

    using SafeERC20 for IERC20;

    IPrizePool prizePool;
    ITWABDelegator twabDelegator;
    uint256 slotOfDelegation;


    mapping(uint256 => ProfileData) internal _dataByProfile;

    // profileId => user => timestamp to undelegate
    mapping(uint256 => mapping(address => uint256)) public timestampEligibleForUndelegate;
    // profileId => user => amount of delegation
    mapping(uint256 => mapping(address => uint256)) public stakeAmount;
    // profileId => user => slot of delegation PoolTogether
    mapping(uint256 => mapping(address => uint256)) public slotByAddress;
    // currency => PrizePool
    mapping(address => address) public prizePoolByCurrency;
    // currency => ticket
    mapping(address => address) public ticketByCurrency;

    /**
     * @dev This modifier reverts if the caller is not the configured governance address.
     */
    modifier onlyGov() {
        _validateCallerIsGovernance();
        _;
    }

    constructor(address hub, address moduleGlobals, address twabDelegatorAddress) FeeModuleBase(moduleGlobals) ModuleBase(hub) {
        twabDelegator = ITWABDelegator(twabDelegatorAddress);
    }

    /**
     * @notice This follow module levies a fee on follows and put this in PoolTogether.
     *
     * @param profileId The profile ID of the profile to initialize this module for.
     * @param data The arbitrary data parameter, decoded into:
     *      uint256 amount: The currency total amount to levy.
     *      uint256 lockDuration: The lock duration of the delegation.
     *      address currency The currency associated with this profile.
     *      address recipient: The custom recipient address to direct earnings to.
     *
     * @return bytes An abi encoded bytes parameter, which is the same as the passed data parameter.
     */
    function initializeFollowModule(
        uint256 profileId,
        bytes calldata data
    ) external override onlyHub returns (bytes memory) {
        (
        uint256 amount,
        uint256 lockDuration,
        address currency,
        address recipient
        ) = abi.decode(data, (uint256, uint256, address, address));
        if (!_currencyWhitelisted(currency) || recipient == address(0) || amount == 0 || lockDuration == 0 || lockDuration >= MAX_LOCK || prizePoolByCurrency[currency] == address(0) || ticketByCurrency[currency] == address(0))
            revert Errors.InitParamsInvalid();

        _dataByProfile[profileId].amount = amount;
        _dataByProfile[profileId].lockDuration = lockDuration;
        _dataByProfile[profileId].currency = currency;
        _dataByProfile[profileId].recipient = recipient;

        return data;
    }

    /**
     * @notice This follow module levies a fee on follows and put this in PoolTogether.
     *  1. Charging a fee
     *  2. Creating a position in PoolTogether
     *  3. Creating a delegation with TWABDelegator
     *
     * @param follower The address of the follower
     * @param profileId The profile ID of the profile to follow.
     * @param data The arbitrary data parameter, decoded into: Currency & Amount
     */
    function processFollow(
        address follower,
        uint256 profileId,
        bytes calldata data
    ) external override onlyHub {
        address currency = _dataByProfile[profileId].currency;
        uint256 amount = _dataByProfile[profileId].amount;
        _validateDataIsExpectedPrizePool(data, currency, amount);

        (address treasury, uint16 treasuryFee) = _treasuryData();
        uint256 treasuryAmount = (amount * treasuryFee) / BPS_MAX;
        uint256 adjustedAmount = amount - treasuryAmount;

        // Avoids stack too deep
        {
            uint256 lockDuration = _dataByProfile[profileId].lockDuration;
            timestampEligibleForUndelegate[profileId][follower] = block.timestamp + lockDuration;
            stakeAmount[profileId][follower] = sendToPoolTogether(
                IPrizePool(prizePoolByCurrency[currency]),
                IERC20(ticketByCurrency[currency]),
                _dataByProfile[profileId].recipient,
                adjustedAmount,
                follower,
                lockDuration
            );
        }


        if (treasuryAmount > 0)
            IERC20(currency).safeTransferFrom(follower, treasury, treasuryAmount);
    }


    /**
    * @notice Send & Delegate the token in PoolTogether
    *
    * @param prizePool PrizePool address
    * @param recipient Recipient address
    * @param adjustedAmount Amount of token to send
    * @param follower Follower address
    * @param lockDuration Lock duration
    */
    function sendToPoolTogether(
        IPrizePool prizePool,
        IERC20 ticket,
        address recipient,
        uint256 adjustedAmount,
        address follower,
        uint256 lockDuration) internal returns (uint256) {
        uint256 amountOfTicketBefore = ticket.balanceOf(address(this));

        // Deposit amount in PoolTogether
        prizePool.depositTo(recipient, adjustedAmount);
        // Create delegation of the amount of ticket
        uint256 amountOfTicketToDelegate = ticket.balanceOf(address(this)) - amountOfTicketBefore;
        twabDelegator.createDelegation(recipient, slotOfDelegation, follower, lockDuration);
        // Fund delegation
        twabDelegator.fundDelegation(recipient, slotOfDelegation, amountOfTicketToDelegate);
        slotOfDelegation++;

        return amountOfTicketToDelegate;
    }

    /**
    * @notice Withdraw tickets from a delegation
    *
    * @param profileId The profile ID of the creator.
    * @param followers An array of all the follower to undelegate from PoolTogether
    */
    function undelegateMyToken(uint256 profileId, address[] memory followers) external {
        if (msg.sender != _dataByProfile[profileId].recipient) revert NotTheRecipient();
        for (uint i = 0; i < followers.length; i++) {
            if (timestampEligibleForUndelegate[profileId][followers[i]] > block.timestamp) revert UndelegateTimeNotReached();
            twabDelegator.withdrawDelegationToStake(msg.sender, slotByAddress[profileId][followers[i]], stakeAmount[profileId][followers[i]]);
        }
    }

    /**
     * @dev We don't need to execute any additional logic on transfers in this follow module.
     */
    function followModuleTransferHook(
        uint256 profileId,
        address from,
        address to,
        uint256 followNFTTokenId
    ) external override {}

    /**
     * @notice Returns the profile data for a given profile, or an empty struct if that profile was not initialized
     * with this module.
     *
     * @param profileId The token ID of the profile to query.
     *
     * @return ProfileData The ProfileData struct mapped to that profile.
     */
    function getProfileData(uint256 profileId) external view returns (ProfileData memory) {
        return _dataByProfile[profileId];
    }

    /**
    * @notice Set a PrizePool for a currency
    *
    * @param currency The currency of the PrizePool
    * @param prizePoolAddress The address of the PrizePool
    */
    function setPrizePool(address currency, address prizePoolAddress) external onlyGov {
        if (!_currencyWhitelisted(currency)) revert Errors.NotWhitelisted();
        prizePoolByCurrency[currency] = prizePoolAddress;
    }

    /**
    * @notice Set a Ticket Address for a currency
    *
    * @param currency The currency of the Ticket
    * @param ticketAddress The address of the Ticket
    */
    function setTicket(address currency, address ticketAddress) external onlyGov {
        if (!_currencyWhitelisted(currency)) revert Errors.NotWhitelisted();
        ticketByCurrency[currency] = ticketAddress;
    }


    function _validateDataIsExpectedPrizePool(
        bytes calldata data,
        address currency,
        uint256 amount) internal view {
        (address decodedCurrency, uint256 decodedAmount) = abi.decode(data, (address, uint256));
        if (decodedCurrency != currency) revert Errors.NotWhitelisted();
        if (prizePoolByCurrency[currency] == address(0)) revert NoPrizePool();
        super._validateDataIsExpected(
            data,
            currency,
            amount);
    }

    function _validateCallerIsGovernance() internal view {
        if (msg.sender != IModuleGlobals(FeeModuleBase.MODULE_GLOBALS).getGovernance()) revert Errors.NotGovernance();
    }

}
