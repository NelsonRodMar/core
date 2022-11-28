// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import {ICollectModule} from '../../../interfaces/ICollectModule.sol';
import {ILensHub} from '../../../interfaces/ILensHub.sol';
import {Errors} from '../../../libraries/Errors.sol';
import {FeeModuleBase} from '../FeeModuleBase.sol';
import {ModuleBase} from '../ModuleBase.sol';
import {IModuleGlobals} from '../../../interfaces/IModuleGlobals.sol';
import {FollowValidationModuleBase} from '../FollowValidationModuleBase.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

/**
 * @notice A struct containing the necessary data to execute collect actions on a publication.
 *
 * @param amount The collecting cost associated with this publication.
 * @param currency The currency associated with this publication.
 * @param recipient The recipient address associated with this publication.
 * @param referralFee The referral fee associated with this publication.
 * @param followerOnly Whether only followers should be able to collect.
 * @param lockDuration The lock duration of the delegation.
 */
    struct ProfilePublicationData {
        uint256 amount;
        address currency;
        address recipient;
        uint16 referralFee;
        bool followerOnly;
        uint256 lockDuration;
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
        address delegator,
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
 * @title PoolTogetherCollectModule
 * @author NelsonRodMar.lens
 *
 * @notice This is a simple PoolTogether implementation in a Lens CollectModule, inheriting from the ICollectModule interface.
 *
*/
contract PoolTogetherCollectModule is FeeModuleBase, FollowValidationModuleBase, ICollectModule {
    uint256 public constant MAX_LOCK = 180 days;
    using SafeERC20 for IERC20;

    IPrizePool prizePool;
    ITWABDelegator twabDelegator;
    uint256 slotOfDelegation;

    mapping(uint256 => mapping(uint256 => ProfilePublicationData))
    internal _dataByPublicationByProfile;

    // profileId => publication id => user => timestamp to undelegate
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public timestampEligibleForUndelegate;
    // profileId => publication id => user =>  amount of delegation
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public stakeAmount;
    // profileId => publication id => user =>  slot of delegation PoolTogether
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public slotByAddress;
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
     * @notice This collect module levies a fee on collects and supports referrals. Thus, we need to decode data.
     *
     * @param profileId The token ID of the profile of the publisher, passed by the hub.
     * @param pubId The publication ID of the newly created publication, passed by the hub.
     * @param data The arbitrary data parameter, decoded into:
     *      uint256 amount: The currency total amount to levy.
     *      address currency: The currency address, must be internally whitelisted.
     *      address recipient: The custom recipient address to direct earnings to.
     *      uint16 referralFee: The referral fee to set.
     *      bool followerOnly: Whether only followers should be able to collect.
     *      uint256 lockDuration: The lock duration of the delegation.
     *
     * @return bytes An abi encoded bytes parameter, which is the same as the passed data parameter.
     */
    function initializePublicationCollectModule(
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) external override onlyHub returns (bytes memory) {
        (
        uint256 amount,
        address currency,
        address recipient,
        uint16 referralFee,
        bool followerOnly,
        uint256 lockDuration
        ) = abi.decode(data, (uint256, address, address, uint16, bool, uint256));
        if (
            !_currencyWhitelisted(currency) ||
        recipient == address(0) ||
        referralFee > BPS_MAX ||
        amount == 0 ||
        lockDuration == 0 ||
        lockDuration >= MAX_LOCK ||
        prizePoolByCurrency[currency] == address(0) ||
        ticketByCurrency[currency] == address(0)
        ) revert Errors.InitParamsInvalid();

        _dataByPublicationByProfile[profileId][pubId].amount = amount;
        _dataByPublicationByProfile[profileId][pubId].currency = currency;
        _dataByPublicationByProfile[profileId][pubId].recipient = recipient;
        _dataByPublicationByProfile[profileId][pubId].referralFee = referralFee;
        _dataByPublicationByProfile[profileId][pubId].followerOnly = followerOnly;
        _dataByPublicationByProfile[profileId][pubId].lockDuration = lockDuration;

        return data;
    }

    /**
     * @dev Processes a collect by:
     *  1. Ensuring the collector is a follower
     *  2. Charging a fee
     *  3. Creating a position in PoolTogether
     *  4. Creating a delegation with TWABDelegator
     */
    function processCollect(
        uint256 referrerProfileId,
        address collector,
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) external virtual override onlyHub {
        if (_dataByPublicationByProfile[profileId][pubId].followerOnly)
            _checkFollowValidity(profileId, collector);
        if (referrerProfileId == profileId) {
            _processCollect(collector, profileId, pubId, data);
        } else {
            _processCollectWithReferral(referrerProfileId, collector, profileId, pubId, data);
        }
    }

    /**
     * @notice Returns the publication data for a given publication, or an empty struct if that publication was not
     * initialized with this module.
     *
     * @param profileId The token ID of the profile mapped to the publication to query.
     * @param pubId The publication ID of the publication to query.
     *
     * @return ProfilePublicationData The ProfilePublicationData struct mapped to that publication.
     */
    function getPublicationData(uint256 profileId, uint256 pubId)
    external
    view
    returns (ProfilePublicationData memory)
    {
        return _dataByPublicationByProfile[profileId][pubId];
    }

    function _processCollect(
        address collector,
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) internal {
        uint256 amount = _dataByPublicationByProfile[profileId][pubId].amount;
        address currency = _dataByPublicationByProfile[profileId][pubId].currency;
        _validateDataIsExpectedPrizePool(data, currency, amount);

        address treasury;
        uint256 treasuryAmount;

        // Avoids stack too deep
        {
            uint16 treasuryFee;
            (treasury, treasuryFee) = _treasuryData();
            treasuryAmount = (amount * treasuryFee) / BPS_MAX;
        }
        uint256 adjustedAmount = amount - treasuryAmount;
        slotByAddress[profileId][pubId][collector] = slotOfDelegation;

        // Avoids stack too deep
        {
            uint256 lockDuration = _dataByPublicationByProfile[profileId][pubId].lockDuration;
            timestampEligibleForUndelegate[profileId][pubId][collector] = block.timestamp + lockDuration;
            stakeAmount[profileId][pubId][collector] = sendToPoolTogether(
                IPrizePool(prizePoolByCurrency[currency]),
                IERC20(ticketByCurrency[currency]),
                _dataByPublicationByProfile[profileId][pubId].recipient,
                adjustedAmount,
                collector,
                lockDuration
            );
        }

        if (treasuryAmount > 0)
            IERC20(currency).safeTransferFrom(collector, treasury, treasuryAmount);
    }

    function _processCollectWithReferral(
        uint256 referrerProfileId,
        address collector,
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) internal {
        uint256 amount = _dataByPublicationByProfile[profileId][pubId].amount;
        address currency = _dataByPublicationByProfile[profileId][pubId].currency;
        _validateDataIsExpectedPrizePool(data, currency, amount);

        address treasury;
        uint256 treasuryAmount;

        // Avoids stack too deep
        {
            uint16 treasuryFee;
            (treasury, treasuryFee) = _treasuryData();
            treasuryAmount = (amount * treasuryFee) / BPS_MAX;
        }

        uint256 adjustedAmount = amount - treasuryAmount;

        if (_dataByPublicationByProfile[profileId][pubId].referralFee != 0) {
            // The reason we levy the referral fee on the adjusted amount is so that referral fees
            // don't bypass the treasury fee, in essence referrals pay their fair share to the treasury.
            uint256 referralAmount = (adjustedAmount * _dataByPublicationByProfile[profileId][pubId].referralFee) / BPS_MAX;
            adjustedAmount = adjustedAmount - referralAmount;

            address referralRecipient = IERC721(HUB).ownerOf(referrerProfileId);

            IERC20(currency).safeTransferFrom(collector, referralRecipient, referralAmount);
        }

        // Avoids stack to deep
        {
            uint256 lockDuration = _dataByPublicationByProfile[profileId][pubId].lockDuration;
            timestampEligibleForUndelegate[profileId][pubId][collector] = block.timestamp + lockDuration;
            stakeAmount[profileId][pubId][collector] = sendToPoolTogether(
                IPrizePool(prizePoolByCurrency[currency]),
                IERC20(ticketByCurrency[currency]),
                _dataByPublicationByProfile[profileId][pubId].recipient,
                adjustedAmount,
                collector,
                lockDuration
            );
        }

        if (treasuryAmount > 0)
            IERC20(currency).safeTransferFrom(collector, treasury, treasuryAmount);
    }


    /**
    * @notice Send & Delegate the token in PoolTogether
    *
    * @param prizePool PrizePool address
    * @param recipient Recipient address
    * @param adjustedAmount Amount of token to send
    * @param collector Collector address
    * @param lockDuration Lock duration
    */
    function sendToPoolTogether(
        IPrizePool prizePool,
        IERC20 ticket,
        address recipient,
        uint256 adjustedAmount,
        address collector,
        uint256 lockDuration) internal returns (uint256) {
        uint256 amountOfTicketBefore = ticket.balanceOf(address(this));

        // Deposit amount in PoolTogether
        prizePool.depositTo(recipient, adjustedAmount);
        // Create delegation of the amount of ticket
        uint256 amountOfTicketToDelegate = ticket.balanceOf(address(this)) - amountOfTicketBefore;
        twabDelegator.createDelegation(recipient, slotOfDelegation, collector, lockDuration);
        // Fund delegation
        twabDelegator.fundDelegation(recipient, slotOfDelegation, amountOfTicketToDelegate);
        slotOfDelegation++;

        return amountOfTicketToDelegate;
    }

    /**
    * @notice Withdraw tickets from a delegation
    *
    * @param profileId The profile ID.
    * @param pubId The publication ID.
    * @param collectors An array of all the collector to undelegate from PoolTogether
    */
    function undelegateMyToken(uint256 profileId, uint256 pubId, address[] memory collectors) external {
        if (msg.sender != _dataByPublicationByProfile[profileId][pubId].recipient) revert NotTheRecipient();
        for (uint i = 0; i < collectors.length; i++) {
            if (timestampEligibleForUndelegate[profileId][pubId][collectors[i]] > block.timestamp) revert UndelegateTimeNotReached();
            twabDelegator.withdrawDelegationToStake(msg.sender, slotByAddress[profileId][pubId][collectors[i]], stakeAmount[profileId][pubId][collectors[i]]);
        }
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
