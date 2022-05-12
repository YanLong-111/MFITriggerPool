// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "./events/MfiEvents.sol";
import "./storages/MfiStorages.sol";
import "./utils/MfiAccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract MetaFinanceTriggerPool is MfiEvents, MfiStorages, MfiAccessControl, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20Metadata;

    // ==================== PRIVATE ====================
    mapping(address => uint256) private _rOwned;
    mapping(address => uint256) private _tOwned;
    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isExcluded;
    uint256 private  _tTotal = 1 * 10 ** 50;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private  _taxFee = 100;
    uint256 private  _previousTaxFee = 100;



    constructor ()  {

        //        MAX = ~uint256(0);
        //        _tTotal = 10 * 10 ** 30;
        //        _rTotal = (MAX - (MAX % _tTotal));
        //        _taxFee = 100;
        //        _previousTaxFee = 100;

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _rOwned[address(this)] = _rTotal;
        _isExcludedFromFee[address(this)] = true;
        _isExcluded[address(this)] = true;

        _tOwned[address(this)] = tokenFromReflection(_rOwned[address(this)]);
    }

    /**
    * @dev User pledge cake
    * @param amount_ User pledge amount
    */
    function userDeposit(uint256 amount_) external beforeStaking nonReentrant {
        require(amount_ > 10000, "MFTP:E1");


        // 用户质押数量 += 质押数量
        userPledgeAmount[_msgSender()] += amount_;
        // 总质押量 += 质押数量
        totalPledgeAmount += amount_;
        //updateMiningPool();
        // 当前合约为用户进行正常转账
        takenTransfer(address(this), _msgSender(), amount_);
        //收取用户cake
        cakeTokenAddress.safeTransferFrom(_msgSender(), address(this), amount_);
        //totalPledgeValue = cakeTokenAddress.balanceOf(address(this));

        //reinvest();

        emit UserPledgeCake(_msgSender(), amount_, block.timestamp);
    }


    /**
    * @dev User releases cake
    * @param amount_ User withdraw amount
    */
    function userWithdraw(uint256 amount_) external beforeStaking nonReentrant {
        // 检查用户获取数量 与 用户质押数量
        require(amount_ > 10000 && amount_ <= userPledgeAmount[_msgSender()], "MFTP:E2");

        //updateMiningPool();

        // 用户奖励数量 = 奖励金额 - 用户质押金额
        uint256 numberOfAwards = rewardBalanceOf(_msgSender()).sub(userPledgeAmount[_msgSender()]);
        if (numberOfAwards > 0) {
            cakeTokenAddress.safeTransfer(_msgSender(), numberOfAwards);
        }
        userPledgeAmount[_msgSender()] -= amount_;
        totalPledgeAmount -= amount_;
        // 用户退出
        takenTransfer(_msgSender(), address(this), numberOfAwards.add(amount_));
        cakeTokenAddress.safeTransfer(_msgSender(), amount_);

        //totalPledgeValue = cakeTokenAddress.balanceOf(address(this));

        //reinvest();

        emit UserWithdrawCake(_msgSender(), amount_, block.timestamp);
    }

    /**
    * @dev 用户获取奖励cake
    */
    function userGetReward() external beforeStaking nonReentrant {
        // 用户奖励数量 = 奖励金额 - 用户质押金额
        uint256 numberOfAwards = rewardBalanceOf(_msgSender()).sub(userPledgeAmount[_msgSender()]);
        require(numberOfAwards > 0, "MFTP:E3");

        // updateMiningPool();

        takenTransfer(_msgSender(), address(this), numberOfAwards);
        cakeTokenAddress.safeTransfer(_msgSender(), numberOfAwards);

        //totalPledgeValue = cakeTokenAddress.balanceOf(address(this));

        //reinvest();

        emit UserReceiveCake(_msgSender(), numberOfAwards, block.timestamp);
    }

    /**
    * @dev Withdraw staked tokens without caring about rewards rewards
    * @dev Needs to be for emergency.
    */
    function projectPartyEmergencyWithdraw() public {
        if (totalPledgeAmount != 0) {
            for (uint256 i; i < smartChefArray.length; i++) {
                smartChefArray[i].emergencyWithdraw();
            }
        }
    }

    /**
    * @dev Upload mining pool ratio
    */
    function uploadMiningPool(uint256[] calldata storageProportion_, ISmartChefInitializable[] calldata smartChefArray_) public beforeStaking{
        require(storageProportion_.length == smartChefArray_.length, "MFTP:E2");
        smartChefArray = smartChefArray_;
        for (uint256 i; i < smartChefArray_.length; i++) {
            storageProportion[smartChefArray_[i]] = storageProportion_[i];
        }
    }

    function renewPool() public beforeStaking {

    }

    /**
    * @dev Update mining pool
    * @notice Batch withdraw,
    *         and will experience token swap to cake token,
    *         and increase the rewards for all users
    */
    function updateMiningPool() public {
        if (totalPledgeAmount != 0) {
            for (uint256 i; i < smartChefArray.length; i++) {
                smartChefArray[i].withdraw(storageQuantity[smartChefArray[i]]);
                address[] memory path = new address[](2);
                path[0] = smartChefArray[i].rewardToken();
                path[1] = address(cakeTokenAddress);
                // 将奖励兑换成cake
                swapTokensForCake(IERC20Metadata(path[0]), path);
            }
            // 当前cake总数 - 上次记录的cake总数 = 得到奖励数量
            // 并进行自我转账实现销毁分发
            takenTransfer(address(this), address(this), (cakeTokenAddress.balanceOf(address(this))).sub(totalPledgeValue));
        }
    }

    /**
    * @dev Bulk pledge
    */
    function reinvest() public {
        //if (totalPledgeAmount != 0) {
        // 计算当前cake数量
        totalPledgeValue = cakeTokenAddress.balanceOf(address(this));
        if (totalPledgeValue != 0) {
            uint256 _frontProportionAmount = 0;
            uint256 _arrayUpperLimit = smartChefArray.length - 1;
            //if (smartChefArray.length > 1) {
            for (uint256 i; i < (_arrayUpperLimit + 1); i++) {
                if (i != _arrayUpperLimit) {
                    // 计算cake在每个矿池的质押数量
                    storageQuantity[smartChefArray[i]] = (totalPledgeValue.mul(storageProportion[smartChefArray[i]])).div(proportion);
                    _frontProportionAmount += storageQuantity[smartChefArray[i]];
                }
                if (i == _arrayUpperLimit)
                    storageQuantity[smartChefArray[i]] = totalPledgeValue.sub(_frontProportionAmount);
            }
        for (uint256 i; i < (_arrayUpperLimit + 1); i++) {
            cakeTokenAddress.safeApprove(address(smartChefArray[i]), 0);
            cakeTokenAddress.safeApprove(address(smartChefArray[i]), storageQuantity[smartChefArray[i]]);
            //[10,30,60]
            // 在矿池中质押计算好的质押数量
            smartChefArray[i].deposit(storageQuantity[smartChefArray[i]]);
            //["0x5B38Da6a701c568545dCfcB03FcB875f56beddC4","0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2","0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db"]
        }
        }
    }

    /**
    * @dev Swap token
    * @param tokenAddress Reward token address
    * @param path Token Path
    */
    function swapTokensForCake(
        IERC20Metadata tokenAddress,
        address[] memory path
    ) private {
        uint256 tokenAmount = tokenAddress.balanceOf(address(this));

        tokenAddress.safeApprove(address(pancakeRouterAddress), 0);
        tokenAddress.safeApprove(address(pancakeRouterAddress), tokenAmount);

        // address(this) Reward token -> address(uniswapV2Pair)
        // address(uniswapV2Pair) cake -> address(this)
        pancakeRouterAddress.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of cake
            path,
            address(this),
            block.timestamp + 10
        );
    }

    modifier beforeStaking(){
        updateMiningPool();
        _;
        //reinvest();
    }

    // ==================== INTERNAL ====================
    /**
    * @dev 内部资金转账
    * @param from 转账人地址
    * @param to 收款人地址
    * @param amount 转账数量
    */
    function takenTransfer(address from, address to, uint256 amount) public {

        if (from == address(this) && from == to) {
            _isExcludedFromFee[from] = false;
        } else {
            _isExcludedFromFee[from] = true;
        }

        bool takeFee = (_isExcludedFromFee[from] || _isExcludedFromFee[to]) ? false : true;

        _tokenTransfer(from, to, amount, takeFee);
    }

    /**
    * @dev 查询用户当前本金数量
    * @param account 账户地址
    */
    function rewardBalanceOf(address account) public view returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function tokenFromReflection(uint256 rAmount) private view returns (uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate = _getRate();
        return rAmount.div(currentRate);
    }

    function _getTValues(uint256 tAmount) private view returns (uint256, uint256/*, uint256*/) {
        uint256 tFee = tAmount.mul(_taxFee).div(10 ** 2);
        uint256 tTransferAmount = tAmount.sub(tFee);
        return (tTransferAmount, tFee);
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, _getRate());
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee);
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        if (_rOwned[address(this)] > rSupply || _tOwned[address(this)] > tSupply) return (_rTotal, _tTotal);
        rSupply = rSupply.sub(_rOwned[address(this)]);
        tSupply = tSupply.sub(_tOwned[address(this)]);
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    function removeAllFee() private {
        if (_taxFee == 0) return;
        _previousTaxFee = _taxFee;
        _taxFee = 0;
    }

    function _tokenTransfer(address sender, address recipient, uint256 amount, bool takeFee) private {
        if (!takeFee)
            removeAllFee();
        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        }
        if (!takeFee)
            _taxFee = _previousTaxFee;
    }

    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee,,) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _rTotal = _rTotal.sub(rFee);
    }

    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount,) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _rTotal = _rTotal.sub(rFee);
    }

    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount,) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _rTotal = _rTotal.sub(rFee);
    }

    /**
    * @dev claim Tokens
    * @param token Token address(address(0) == ETH)
    * @param amount Claim amount
    */
    function claimTokens(
        address token,
        address to,
        uint256 amount
    ) public onlyRole(MONEY_ADMINISTRATOR) {
        if (amount > 0) {
            if (token == address(0)) {
                payable(to).transfer(amount);
            } else {
                IERC20Metadata(token).safeTransfer(to, amount);
            }
        }
    }

    receive() external payable {}
}
