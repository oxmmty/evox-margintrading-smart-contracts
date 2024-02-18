// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IDataHub.sol";
import "./interfaces/IDepositVault.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IUtilityContract.sol";
import "./libraries/REX_LIBRARY.sol";
import "./interfaces/IinterestData.sol";
import "hardhat/console.sol";

contract REX_EXCHANGE is Ownable {
    /** Address's  */

    IDataHub public Datahub;

    IOracle public Oracle;

    IDepositVault public DepositVault;

    IInterestData public interestContract;

    IUtilityContract public Utilities;

    address public FeeWallet =
        address(0x1167E56ABcf9d2dF6354e03610E301B8a2934955);

    address public liquidator;

    /** Constructor  */
    constructor(
        address initialOwner,
        address _DataHub,
        address _deposit_vault,
        address oracle,
        address _utility,
        address _interest
    ) Ownable(initialOwner) {
        Datahub = IDataHub(_DataHub);
        DepositVault = IDepositVault(_deposit_vault);
        Oracle = IOracle(oracle);
        Utilities = IUtilityContract(_utility);
        interestContract = IInterestData(_interest);

        // liquidator = _liquidator;
    }

    modifier checkRoleAuthority() {
        require(
            msg.sender == address(Oracle) || msg.sender == liquidator,
            "Unauthorized"
        );
        _;
    }

    function SubmitOrder(
        address[2] memory pair,
        address[][2] memory participants,
        uint256[][2] memory trade_amounts
    ) public {
        uint256[] memory TakerliabilityAmounts = new uint256[](
            participants[0].length
        );
        uint256[] memory MakerliabilityAmounts = new uint256[](
            participants[1].length
        );

        // this checks if the asset they are trying to trade isn't pass max borrow
        for (uint256 i = 0; i < pair.length; i++) {
            uint256 newLiabilitiesIssued = REX_LIBRARY.calculateTotal(
                trade_amounts[i]
            ) > Utilities.returnBulkAssets(participants[i], pair[i])
                ? REX_LIBRARY.calculateTotal(trade_amounts[i]) -
                    Utilities.returnBulkAssets(participants[i], pair[i])
                : 0;

            if (newLiabilitiesIssued > 0) {
                require(
                    REX_LIBRARY.calculateBorrowProportionAfterTrades(
                        Datahub.returnAssetLogs(pair[i]),
                        newLiabilitiesIssued
                    ),
                    "asset is not tradeable because it would be over max borrow proportion of"
                );
            }
        }

        for (uint256 i = 0; i < participants[0].length; i++) {
            (uint256 assets, , , , ) = Datahub.ReadUserData(
                participants[0][i],
                pair[0]
            );

            if (trade_amounts[0][i] > assets) {
                require(
                    Utilities.calculateMarginRequirement(
                        participants[0][i],
                        pair[0],
                        trade_amounts[0][i],
                        assets
                    ),
                    "you failed the margin requirements"
                );
                // now here right we know for a fucking fact this will be a margin trade should i mark it as such?

                if (
                    Utilities.validateMarginStatus(
                        participants[0][i],
                        pair[0]
                    ) == false
                ) {
                    Datahub.SetMarginStatus(participants[0][i], true);
                }
                uint256 TakeramountToAddToLiabilities = Utilities
                    .calculateAmountToAddToLiabilities(
                        participants[0][i],
                        pair[0],
                        trade_amounts[0][i]
                    );

                TakerliabilityAmounts[i] = TakeramountToAddToLiabilities;
                AlterPendingBalances(participants[0][i], pair[0], assets);
            } else {
                TakerliabilityAmounts[i] = 0;
                AlterPendingBalances(
                    participants[0][i],
                    pair[0],
                    trade_amounts[0][i]
                );
            }
        }

        for (uint256 i = 0; i < participants[1].length; i++) {
            (uint256 assets, , , , ) = Datahub.ReadUserData(
                participants[1][i],
                pair[1]
            );
            if (trade_amounts[1][i] > assets) {
                require(
                    Utilities.calculateMarginRequirement(
                        participants[1][i],
                        pair[1],
                        trade_amounts[1][i],
                        assets
                    )
                );
                if (
                    Utilities.validateMarginStatus(
                        participants[1][i],
                        pair[1]
                    ) == false
                ) {
                    Datahub.SetMarginStatus(participants[1][i], true);
                }

                /// becauswe we know that the trade amount is larger than that users assets
                // we calcualte how much to add to their liabilities right
                uint256 amountToAddToLiabilities = Utilities
                    .calculateAmountToAddToLiabilities(
                        participants[1][i],
                        pair[1],
                        trade_amounts[1][i]
                    );

                MakerliabilityAmounts[i] = amountToAddToLiabilities;

                AlterPendingBalances(participants[1][i], pair[1], assets);
            } else {
                MakerliabilityAmounts[i] = 0;
                AlterPendingBalances(
                    participants[1][i],
                    pair[1],
                    trade_amounts[1][i]
                );
            }
        }
        Oracle.ProcessTrade(
            pair,
            participants,
            trade_amounts,
            TakerliabilityAmounts,
            MakerliabilityAmounts
        );
    }

    function TransferBalances(
        address[2] memory pair,
        address[] memory takers,
        address[] memory makers,
        uint256[] memory taker_amounts,
        uint256[] memory maker_amounts,
        uint256[] memory TakerliabilityAmounts,
        uint256[] memory MakerliabilityAmounts
    ) external checkRoleAuthority {
        Datahub.checkIfAssetIsPresent(takers, pair[1]);
        Datahub.checkIfAssetIsPresent(makers, pair[0]);
        // checks if the asset is in the users portfolio already or not and adds it if it isnt
        executeTrade(
            makers,
            taker_amounts,
            maker_amounts,
            MakerliabilityAmounts,
            pair[1],
            pair[0]
        );
        executeTrade(
            takers,
            maker_amounts,
            taker_amounts,
            TakerliabilityAmounts,
            pair[0],
            pair[1]
        );
    }

    function executeTrade(
        address[] memory users,
        uint256[] memory amounts_in_token,
        uint256[] memory amounts_out_token,
        uint256[] memory liabilityAmounts,
        address out_token,
        address in_token
    ) private {
        for (uint256 i = 0; i < users.length; i++) {
            uint256 amountToAddToLiabilities = liabilityAmounts[i];

            if (amountToAddToLiabilities != 0) {
                chargeinterest(
                    users[i],
                    out_token,
                    amountToAddToLiabilities,
                    false
                ); // this sets total borrowed amount, adds to liabilities

                Datahub.addMaintenanceMarginRequirement(
                    users[i],
                    out_token,
                    in_token,
                    REX_LIBRARY.calculateMaintenanceRequirementForTrade(
                        returnAssetLogs(in_token),
                        amountToAddToLiabilities
                    )
                );
            }
            if (
                amounts_in_token[i] <=
                Utilities.returnliabilities(users[i], in_token)
            ) {
                chargeinterest(users[i], in_token, amounts_in_token[i], true);

                Modifymmr(users[i], in_token, out_token, amounts_in_token[i]);
            } else {
                uint256 subtractedFromLiabilites = Utilities.returnliabilities(
                    users[i],
                    in_token
                ); // we know its greater than or equal to its safe to 0

                uint256 input_amount = amounts_in_token[i];

                if (subtractedFromLiabilites > 0) {
                    input_amount =
                        amounts_in_token[i] -
                        Utilities.returnliabilities(users[i], in_token);

                    chargeinterest(
                        users[i],
                        in_token,
                        subtractedFromLiabilites,
                        true
                    );

                    Modifymmr(
                        users[i],
                        in_token,
                        out_token,
                        amounts_in_token[i]
                    );
                }

                amounts_out_token[i] >
                    Utilities.returnPending(users[i], out_token)
                    ? Datahub.removePendingBalances(
                        users[i],
                        out_token,
                        Utilities.returnPending(users[i], out_token)
                    )
                    : Datahub.removePendingBalances(
                        users[i],
                        out_token,
                        amounts_out_token[i]
                    );

                Datahub.addAssets(users[i], in_token, input_amount);

                // Conditions met assets changed, set flag to true
            }
        }
    }


    function chargeinterest(
        address user,
        address token,
        uint256 liabilitiesAccrued,
        bool minus
    ) private {
        if (minus ==false) {
            /// Utilities.chargeInterest(token, liabilities, amount_to_be_added, rateIndex); == interest charged
            // something is wrong in the below function

            Datahub.addLiabilities(
                user,
                token,
                liabilitiesAccrued +
                    Utilities.chargeInterest(
                        token,
                        Utilities.returnliabilities(user, token), // this is 0 at this point because its the first time we are chargin liabilities
                        liabilitiesAccrued,
                        Datahub.viewUsersInterestRateIndex(user, token)
                    )
            );

            Datahub.setTotalBorrowedAmount(
                token,
                (liabilitiesAccrued +
                    Utilities.chargeInterest(
                        token,
                        Utilities.returnliabilities(user, token),
                        liabilitiesAccrued,
                        Datahub.viewUsersInterestRateIndex(user, token)
                    )),
                true
            );
        } else {
            Datahub.removeLiabilities(user, token, liabilitiesAccrued);
            Datahub.setTotalBorrowedAmount(token, liabilitiesAccrued, true);
        }

        Datahub.alterUsersInterestRateIndex(user, token);

        if (
            interestContract
                .fetchRateInfo(
                    token,
                    interestContract.fetchCurrentRateIndex(token)
                )
                .lastUpdatedTime +
                1 hours <
            block.timestamp
        ) {
            Datahub.setTotalBorrowedAmount(
                token,
                interestContract.chargeLiabilityDelta(
                    token,
                    interestContract.fetchCurrentRateIndex(token)
                ),
                true
            );

            interestContract.toggleInterestRate(
                token,
                interestContract.fetchCurrentRateIndex(token),
                REX_LIBRARY.calculateInterestRate(
                    liabilitiesAccrued,
                    returnAssetLogs(token),
                    interestContract.fetchRateInfo(
                        token,
                        interestContract.fetchCurrentRateIndex(token)
                    )
                )
            );
        }
    }

    function Modifymmr(
        address user,
        address in_token,
        address out_token,
        uint256 amount
    ) private {
        IDataHub.AssetData memory assetLogsOutToken = returnAssetLogs(
            out_token
        );
        IDataHub.AssetData memory assetLogsInToken = returnAssetLogs(in_token);
        if (amount <= Utilities.returnliabilities(user, in_token)) {
            uint256 StartingDollarMMR = (amount *
                assetLogsOutToken.MaintenanceMarginRequirement) / 10 ** 18; // check to make sure this is right
            if (
                StartingDollarMMR >
                Datahub.returnPairMMROfUser(user, in_token, out_token)
            ) {
                uint256 overage = (StartingDollarMMR -
                    Datahub.returnPairMMROfUser(user, in_token, out_token)) /
                    assetLogsInToken.MaintenanceMarginRequirement;

                Datahub.removeMaintenanceMarginRequirement(
                    user,
                    in_token,
                    out_token,
                    Datahub.returnPairMMROfUser(user, in_token, out_token)
                );

                uint256 liabilityMultiplier = REX_LIBRARY
                    .calculatedepositLiabilityRatio(
                        Utilities.returnliabilities(user, in_token),
                        overage
                    );

                address[] memory tokens = Datahub.returnUsersAssetTokens(user);

                for (uint256 i = 0; i < tokens.length; i++) {
                    Datahub.alterMMR(
                        user,
                        in_token,
                        tokens[i],
                        liabilityMultiplier
                    );
                }
            } else {
                Datahub.removeMaintenanceMarginRequirement(
                    user,
                    in_token,
                    out_token,
                    StartingDollarMMR
                );
            }
        } else {
            for (
                uint256 i = 0;
                i < Datahub.returnUsersAssetTokens(user).length;
                i++
            ) {
                address[] memory tokens = Datahub.returnUsersAssetTokens(user);
                Datahub.removeMaintenanceMarginRequirement(
                    user,
                    in_token,
                    tokens[i],
                    Datahub.returnPairMMROfUser(user, in_token, tokens[i])
                );
            }
        }
    }

    function AlterPendingBalances(
        address participant,
        address asset,
        uint256 trade_amount
    ) private {
        Datahub.removeAssets(participant, asset, trade_amount);
        Datahub.addPendingBalances(participant, asset, trade_amount);
    }

    function returnAssetLogsExternal(
        address token
    ) external view returns (IDataHub.AssetData memory assetLogs) {
        return Datahub.returnAssetLogs(token);
    }

    function returnAssetLogs(
        address token
    ) internal view returns (IDataHub.AssetData memory assetLogs) {
        return Datahub.returnAssetLogs(token);
    }

    function alterAdminRoles(
        address _datahub,
        address _depositVault,
        address _oracle,
        address _utility,
        address _int
    ) public onlyOwner {
        Datahub = IDataHub(_datahub);
        DepositVault = IDepositVault(_depositVault);
        Oracle = IOracle(_oracle);
        Utilities = IUtilityContract(_utility);
        interestContract = IInterestData(_int);
    }

    receive() external payable {}
}

// charge the user interest and add interest to their liabilities balance
/// and we always add that amount of new liabilties they took and the interest charged to total borrowed amount
// change users mmr

// IF we havent updated the current interest index then charge and update it
// charge mass interest to total borrowed amount
// once we do the above step this will effectively change the interest rate  BUT the contract doesnt know this yet
// we then write to actually change this rate THIS will create a new index with the new rate

// just make sure that their is a read function exposed to give ALL the above data in relation to the users mmr because
// the top data will not reflect the changes made in the data in the below paragraph in the state we must read it

/*
    function executeTradeOld(
        address[] memory users,
        uint256[] memory amounts_in_token,
        uint256[] memory amounts_out_token,
        uint256[] memory liabilityAmounts,
        address out_token,
        address in_token
    ) private {
        for (uint256 i = 0; i < users.length; i++) {
            uint256 amountToAddToLiabilities = liabilityAmounts[i];

            if (amountToAddToLiabilities != 0) {
                /*
                
                if the amount to add to liabilities is above 0 

                if this trade is not happening right on the hour
                   // charge the user interest on his past trades and for the next hour 
                   // add that to amount to add to liabilities

                if the trade is happening right on the hour
                  // get the mass charge amount and add that to the total borrowed amount 

                add to users liabilities 

                alter the users interest rate index 

                set the total borrowed amount up by the size of the trade and interest charged

                toggle the interest rate because we just changed the borrow proportion thus affecting interest rates

                add to users mmr 


                */

/*
                if (block.timestamp % 3600 != 0) {
                    amountToAddToLiabilities += Utilities.handleHourlyFee(
                        out_token,
                        amountToAddToLiabilities
                    );
                }

                             Datahub.addAssets(
                    FeeWallet,
                    out_token,
                    REX_LIBRARY.calculateinitialMarginFeeAmount(
                        returnAssetLogs(out_token),
                        amountToAddToLiabilities
                    )
                );

                

                if (block.timestamp % 3600 != 0) {
                    uint256 interestCharge = Utilities.chargeInterest(
                        out_token,
                        Utilities.returnliabilities(users[i], out_token),
                        amountToAddToLiabilities,
                        Datahub.viewUsersInterestRateIndex(users[i])
                    );

                    amountToAddToLiabilities += interestCharge;
                } else {
                    // if its on the hour
                    // charge mass
                    // if it hasnt already happend on the hour charge the mass
                }

                Datahub.addLiabilities(
                    users[i],
                    out_token,
                    amountToAddToLiabilities
                );

                Datahub.alterUsersInterestRateIndex(users[i]);

                // include bulk uncharged interest into this
                // need to do a similar thing to TPV and AMMR for the individual user

                Datahub.setTotalBorrowedAmount(
                    out_token,
                    amountToAddToLiabilities,
                    true
                );
                // add rate change information cause the rates will change
                Datahub.toggleInterestRate(
                    out_token,
                    REX_LIBRARY.calculateInterestRate(
                        amountToAddToLiabilities,
                        returnAssetLogs(out_token),
                        Datahub.fetchRates(
                            out_token,
                            Datahub.fetchCurrentRateIndex(out_token)
                        )
                    )
                );

                Datahub.addMaintenanceMarginRequirement(
                    users[i],
                    out_token,
                    in_token,
                    REX_LIBRARY.calculateMaintenanceRequirementForTrade(
                        returnAssetLogs(in_token),
                        amountToAddToLiabilities
                    )
                );
            }
            if (
                amounts_in_token[i] <=
                Utilities.returnliabilities(users[i], in_token)
            ) {
                Modifymmr(users[i], in_token, out_token, amounts_in_token[i]);
                
                uint256 interestCharge = Utilities.chargeInterest(
                    in_token,
                    Utilities.returnliabilities(users[i], in_token),
                    Datahub.viewUsersInterestRateIndex(users[i])
                );

                // under flow possiblities

                Datahub.removeLiabilities(
                    users[i],
                    in_token,
                    (amounts_in_token[i])
                );

                Datahub.alterUsersInterestRateIndex(users[i]);

                // add rate change information cause the rates will change

                Datahub.setTotalBorrowedAmount(
                    out_token,
                    (amounts_in_token[i]),
                    false
                );

                Datahub.toggleInterestRate(
                    in_token,
                    REX_LIBRARY.calculateInterestRate(
                        amountToAddToLiabilities,
                        returnAssetLogs(in_token),
                        Datahub.fetchRates(
                            in_token,
                            Datahub.fetchCurrentRateIndex(in_token)
                        )
                    )
                );
            } else {
                uint256 subtractedFromLiabilites = Utilities.returnliabilities(
                    users[i],
                    in_token
                ); // we know its greater than or equal to its safe to 0

                uint256 input_amount = amounts_in_token[i];

                if (subtractedFromLiabilites > 0) {
                    input_amount =
                        amounts_in_token[i] -
                        Utilities.returnliabilities(users[i], in_token);

                    Modifymmr(
                        users[i],
                        in_token,
                        out_token,
                        amounts_in_token[i]
                    );
                    // add rate change information cause the rates will change
                    
                    uint256 interestCharge = Utilities.chargeInterest(
                        in_token,
                        Utilities.returnliabilities(users[i], in_token),
                        Datahub.viewUsersInterestRateIndex(users[i])
                    );

                
                    // under flow possiblities
                    Datahub.alterUsersInterestRateIndex(users[i]);

                    Datahub.removeLiabilities(
                        users[i],
                        in_token,
                        (subtractedFromLiabilites)
                    );

                    Datahub.setTotalBorrowedAmount(
                        in_token,
                        subtractedFromLiabilites,
                        false
                    );
                    // calculate interest rate
                    Datahub.toggleInterestRate(
                        in_token,
                        REX_LIBRARY.calculateInterestRate(
                            0,
                            returnAssetLogs(in_token),
                            Datahub.fetchRates(
                                in_token,
                                Datahub.fetchCurrentRateIndex(in_token)
                            )
                        )
                    );
                }

                amounts_out_token[i] >
                    Utilities.returnPending(users[i], out_token)
                    ? Datahub.removePendingBalances(
                        users[i],
                        out_token,
                        Utilities.returnPending(users[i], out_token)
                    )
                    : Datahub.removePendingBalances(
                        users[i],
                        out_token,
                        amounts_out_token[i]
                    );

                Datahub.addAssets(users[i], in_token, input_amount);

                // Conditions met assets changed, set flag to true
            }
        }
    }
*/

/*
    function modifyMMR(address user, address in_token, address out_token, uint256 amount) private {
        uint256 liabilities = Utilities.returnliabilities(user, in_token);

        uint256 mmr = Datahub.returnMMROfUser(user, in_token, out_token);

        // amount <= liabilities && mmr == 0
        // amount > liab && mmr !=0
        /// amount > liab && mmr = 0
        // amount <= liab $$ mmr != 0

        if(amount <= liabilities){
                    // if amount in is less
            uint256 liabilityMultiplier = REX_LIBRARY
                .calculatedepositLiabilityRatio(
                    Utilities.returnliabilities(user, in_token),
                    amount
                );

            for (
                uint256 i = 0;
                i < Datahub.returnUsersAssetTokens(user).length;
                i++
            ) {
                address[] memory tokens = Datahub.returnUsersAssetTokens(user);

                if (Datahub.returnMMROfUser(user, in_token, tokens[i]) > 0) {
                    Datahub.alterMMR(user, in_token, tokens[i], liabilityMultiplier);
                }
            }
        
            // do this
            if(mmr == 0){

            }else{
                // mmr > 0
            }

        }else{
                    for (
                uint256 i = 0;
                i < Datahub.returnUsersAssetTokens(user).length;
                i++
            ) {
                address[] memory tokens = Datahub.returnUsersAssetTokens(user);

                  Datahub.removeMaintenanceMarginRequirement(user,in_token, tokens[i], mmr);
            }
        }

        if (amount <= liabilities && mmr == 0) {
            // if amount in is less
            uint256 liabilityMultiplier = REX_LIBRARY
                .calculatedepositLiabilityRatio(
                    Utilities.returnliabilities(user, in_token),
                    amount
                );

            for (
                uint256 i = 0;
                i < Datahub.returnUsersAssetTokens(user).length;
                i++
            ) {
                address[] memory tokens = Datahub.returnUsersAssetTokens(user);

                if (Datahub.returnMMROfUser(user, in_token, tokens[i]) > 0) {
                    Datahub.alterMMR(user, in_token, tokens[i], liabilityMultiplier);
                }
            }
        }
        // checks to see if the user has liabilities of that asset
        else {
            Datahub.removeMaintenanceMarginRequirement(user,in_token, out_token, mmr); // remove all mmr
        }
    }



 StartingDollarMMR = Amount * BTC.MMR
    
if(StartingDollarMMR>Dollar.BTC.MMR){
        (StartingDollarMMR - Dollar.BTC.MMR)/MMR) spread out throughout the remaining MMRs.
        ZERO OUT StartingDollarMMR
}

else{
        Dollar.BTC.MMR -= StartingDollarMMR
}   
*/
/*
    function modifyMMR(
        address user,
        address in_token,
        address out_token,
        uint256 amount
    ) private {
        uint256 liabilities = Utilities.returnliabilities(user, in_token);

        uint256 mmr = Datahub.returnMMROfUser(user, in_token, out_token);

        if (amount <= liabilities) {
            // if amount in is less
            uint256 liabilityMultiplier = REX_LIBRARY
                .calculatedepositLiabilityRatio(
                    Utilities.returnliabilities(user, in_token),
                    amount
                );

            for (
                uint256 i = 0;
                i < Datahub.returnUsersAssetTokens(user).length;
                i++
            ) {
                address[] memory tokens = Datahub.returnUsersAssetTokens(user);

                // amount in * maintentance of out
                //  if thats bigger than mmr
                // alter instead of subtract
                // uint256 amounts = amount in * maintentance of out
                // amounts -= Datahub.returnMMROfUser(user, in_token, out_token)
                // 0 the mmr  - Datahub.returnMMROfUser(user, in_token, out_token)

                // take amounts value and use that for the rest

                if (Datahub.returnMMROfUser(user, in_token, out_token) == 0) {
                    if (
                        Datahub.returnMMROfUser(user, in_token, tokens[i]) > 0
                    ) {
                        Datahub.alterMMR(
                            user,
                            in_token,
                            tokens[i],
                            liabilityMultiplier
                        );
                    }
                } else {
                    // just modify like above the USDT-BTC pair and end it?
                }
            }
        } else {
            for (
                uint256 i = 0;
                i < Datahub.returnUsersAssetTokens(user).length;
                i++
            ) {
                address[] memory tokens = Datahub.returnUsersAssetTokens(user);

                Datahub.removeMaintenanceMarginRequirement(
                    user,
                    in_token,
                    tokens[i],
                    mmr
                );
            }
        }
    }
*/
