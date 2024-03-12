// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// import {console} from "forge-std/Test.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title FlamelingToken token
/// @author Nadina Oates
/// @notice Contract implementing ERC20 token that pays out dividend rewards from transaction fee

contract DividendShares is Ownable {
    /**
     * Types
     */
    struct DividendAccounts {
        address[] accounts;
        mapping(address => uint256) dividendsPerTokenCredited;
        mapping(address => uint256) shares;
        mapping(address => uint256) dividends;
        mapping(address => uint256) indexOf;
        mapping(address => bool) inserted;
    }

    /**
     * State Variables
     */
    uint256 constant PRECISION = 2 ** 64;

    IERC20 internal s_dividendToken;

    DividendAccounts internal s_dividendAccounts;
    uint256 internal s_totalDividends;
    uint256 internal s_dividendsPerToken;
    uint256 internal s_totalShares;
    uint256 internal s_dividendRemainder;
    uint256 internal s_minSharesRequired = 100_000 * 10 ** 18;
    address[] internal s_accountsExcludedFromDividends;
    mapping(address => bool) private s_isExcludedFromDividends;
    mapping(address => uint256) private s_lastClaimTime;

    uint256 private s_claimInterval = 0;
    uint256 private s_nextIndexToProcess = 0;
    uint256 private s_gasForProcessing = 300_000;

    /** Events */
    event DividendTokenUpdated(address indexed sender, address dividendToken);
    event DividendsDistributed(uint256 indexed amount);
    event DividendsWithdrawn(address indexed recipient, uint256 amount);
    event GasForProcessingUpdated(address indexed sender, uint256 gas);
    event ExcludedFromDividends(address indexed account, bool isExcluded);

    /** Errors */
    error DividendShares__InvalidIndex(
        uint256 requestedIndex,
        uint256 numberOfIndices
    );

    error DividendShares__NoDividendsToClaim();
    error DividendShares__NotDividendEligible();

    /// @notice Constructor
    /// @param initialOwner ownerhip is transfered to this address after creation
    /// @param dividendToken token to be distributed in dividends
    /// @dev inherits from Openzeppelin ERC20 and Ownable
    constructor(
        address initialOwner,
        address dividendToken
    ) Ownable(initialOwner) {
        s_dividendToken = IERC20(dividendToken);
    }

    /** Functions */
    function _numberOfDividendAccounts() private view returns (uint256) {
        return s_dividendAccounts.accounts.length;
    }

    /// @notice Gets account (address) at specific index
    /// @param index Index of entry with the account
    function _dividendAccountAtIndex(
        uint256 index
    ) private view returns (address) {
        if (index >= _numberOfDividendAccounts()) {
            revert DividendShares__InvalidIndex(
                index,
                _numberOfDividendAccounts()
            );
        }
        return s_dividendAccounts.accounts[index];
    }

    /// @notice Updates dividend balance
    /// @param account address of account
    function _updateDividends(address account) internal {
        uint256 owed = s_dividendsPerToken -
            s_dividendAccounts.dividendsPerTokenCredited[account];
        s_dividendAccounts.dividends[account] +=
            s_dividendAccounts.shares[account] *
            owed;
        s_dividendAccounts.dividendsPerTokenCredited[
            account
        ] = s_dividendsPerToken;
    }

    /// @notice Removes entry from map
    /// @param account Associated address of entry to be removed
    function _removeDividendAccount(address account) private {
        if (!s_dividendAccounts.inserted[account]) {
            return;
        }

        s_totalShares -= s_dividendAccounts.shares[account];
        delete s_dividendAccounts.inserted[account];
        delete s_dividendAccounts.shares[account];

        uint256 index = s_dividendAccounts.indexOf[account];
        address lastAccount = s_dividendAccounts.accounts[
            _numberOfDividendAccounts() - 1
        ];

        s_dividendAccounts.indexOf[lastAccount] = index;
        delete s_dividendAccounts.indexOf[account];

        s_dividendAccounts.accounts[index] = lastAccount;
        s_dividendAccounts.accounts.pop();
    }

    /// @notice Updates dividend account
    /// @param account Associated address of entry
    /// @param balance Value associated with address
    function _updateDividendAccount(address account, uint256 balance) internal {
        if (
            balance >= s_minSharesRequired &&
            !s_isExcludedFromDividends[account]
        ) {
            if (s_dividendAccounts.inserted[account]) {
                uint256 currentShares = s_dividendAccounts.shares[account];
                s_totalShares = s_totalShares + balance - currentShares;
                s_dividendAccounts.shares[account] = balance;
            } else {
                s_dividendAccounts.inserted[account] = true;
                s_dividendAccounts.shares[account] = balance;
                s_dividendAccounts.indexOf[
                    account
                ] = _numberOfDividendAccounts();
                s_dividendAccounts.accounts.push(account);
                s_totalShares += balance;
            }
        } else {
            if (s_dividendAccounts.inserted[account]) {
                _removeDividendAccount(account);
            } else {
                return;
            }
        }
    }

    /// @notice Distributes dividend fee to shares based on
    /// @param amount Collected dividend fee
    function _distributeDividends(uint256 amount) internal {
        s_totalDividends += amount;
        if (s_totalShares > 0) {
            uint256 available = (amount * PRECISION) + s_dividendRemainder;
            s_dividendsPerToken += available / s_totalShares;
            s_dividendRemainder = available % s_totalShares;
            emit DividendsDistributed(amount);
        }
    }

    function _processDividends() internal returns (bool) {
        uint256 gasAllowed = s_gasForProcessing;
        uint256 nextIndexToProcess = s_nextIndexToProcess;
        if (_numberOfDividendAccounts() == 0) {
            return false;
        }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        while (
            gasUsed < gasAllowed && iterations < _numberOfDividendAccounts()
        ) {
            address account = _dividendAccountAtIndex(nextIndexToProcess);
            if (
                (block.timestamp - s_lastClaimTime[account]) >= s_claimInterval
            ) {
                _withdrawDividends(account);
            }

            iterations++;
            nextIndexToProcess++;

            if (nextIndexToProcess >= _numberOfDividendAccounts()) {
                nextIndexToProcess = 0;
            }

            gasUsed = gasUsed + gasLeft - gasleft();
            gasLeft = gasleft();
        }

        s_nextIndexToProcess = nextIndexToProcess;
        return true;
    }

    /// @notice Claims claimable dividends for specified account
    /// @dev Account gets percentage share: totalDividends * accountBalance / totalBalance - claimedDividends - buffer (buffer to avoid rounding errors)
    /// @param account address
    function _withdrawDividends(address account) private returns (bool) {
        _updateDividends(account);

        // calculate withrdrawable dividend amount
        uint256 dividendAmount = s_dividendAccounts.dividends[account] /
            PRECISION;

        // transfer dividends to account
        if (
            dividendAmount > 0 &&
            dividendAmount <= s_dividendToken.balanceOf(address(this))
        ) {
            try s_dividendToken.transfer(account, dividendAmount) {
                s_dividendAccounts.dividends[account] %= PRECISION;
                emit DividendsWithdrawn(account, dividendAmount);
            } catch {
                revert();
                // return false;
            }
        } else {
            return false;
        }
        return true;
    }

    /// @notice Sets rewards token
    /// @param dividendToken token rewarded to holders
    function updateDividendToken(address dividendToken) external onlyOwner {
        s_dividendToken = IERC20(dividendToken);
        emit DividendTokenUpdated(msg.sender, dividendToken);
    }

    /// @notice Sets gas for processing dividends
    /// @param gas amount
    function updateGasForProcessing(uint256 gas) external onlyOwner {
        s_gasForProcessing = gas;
        emit GasForProcessingUpdated(msg.sender, gas);
    }

    /// @notice Exludes/includes address from dividends
    /// @param account address to be excluded
    function excludeFromDividends(address account) public onlyOwner {
        s_isExcludedFromDividends[account] = true;
        _updateDividends(account);
        _removeDividendAccount(account);
        emit ExcludedFromDividends(account, true);
    }

    /// @notice Exludes/includes address from dividends
    /// @param account address to be included
    /// @param balance current token shares
    function includeInDividends(
        address account,
        uint256 balance
    ) public onlyOwner {
        s_isExcludedFromDividends[account] = false;
        _updateDividends(account);
        _updateDividendAccount(account, balance);
        emit ExcludedFromDividends(account, false);
    }

    /// @notice Claims dividends manually for calling account
    function withdrawDividends() external {
        if (!s_dividendAccounts.inserted[msg.sender]) {
            revert DividendShares__NotDividendEligible();
        }
        bool success = _withdrawDividends(msg.sender);
        if (!success) revert DividendShares__NoDividendsToClaim();
    }

    /** Getter Functions */

    /// @notice Gets reward token address
    function getDividendToken() external view returns (address) {
        return address(s_dividendToken);
    }

    /// @notice Returns minimum shares required for receiving dividends
    function getMinSharesRequired() external view returns (uint256) {
        return s_minSharesRequired;
    }

    /// @notice Returns number of token holders
    function getNumberOfDividendAccounts() external view returns (uint256) {
        return _numberOfDividendAccounts();
    }

    /// @notice Returns total accumulated dividends
    function getTotalDividends() external view returns (uint256) {
        return s_totalDividends;
    }

    /// @notice Returns dividends of account
    /// @param account address
    function getSharesOf(address account) external view returns (uint256) {
        return s_dividendAccounts.shares[account];
    }

    /// @notice Returns dividends of account
    /// @param index index of dividend holder
    function getDividendAccountAtIndex(
        uint256 index
    ) external view returns (address) {
        return _dividendAccountAtIndex(index);
    }

    /// @notice Returns whether address is excluded from dividends
    function getExcludedFromDividends(
        address account
    ) external view returns (bool) {
        return s_isExcludedFromDividends[account];
    }

    /// @notice Returns gas for processing dividends
    function getGasForProcessing() external view returns (uint256) {
        return s_gasForProcessing;
    }

    /// @notice Returns last processed index
    function getNextIndexToProcess() external view returns (uint256) {
        return s_nextIndexToProcess;
    }

    /// @notice Returns total shares
    function getTotalShares() external view returns (uint256) {
        return s_totalShares;
    }

    /// @notice Returns remaining dividends
    function getRemainingDividends() external view returns (uint256) {
        return s_dividendRemainder / PRECISION;
    }
}
