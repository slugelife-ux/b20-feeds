// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {B20FeedRegistry} from "../src/B20FeedRegistry.sol";
import {B20FeedProxy} from "../src/B20FeedProxy.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";

/// @dev Mock of the ERC-8056 multiplier surface for stock forge (no B20
///      precompiles). Only under base-forge does the suite run against the
///      real precompile; the mock keeps the same semantics (WAD-scaled,
///      scheduled update, lazy flip at effectiveAt on read).
contract MockB20Token {
    uint256 internal constant WAD = 1e18;
    uint256 public current = WAD;
    uint256 public pendingM;
    uint256 public effectiveAt;

    function uiMultiplier() external view returns (uint256) {
        if (effectiveAt != 0 && block.timestamp >= effectiveAt) return pendingM;
        return current;
    }

    function updateUIMultiplier(uint256 newM, uint256 at) external {
        pendingM = newM;
        effectiveAt = at;
    }
}

contract B20FeedRegistryTest is Test {
    B20FeedRegistry internal registry;
    address internal pusher;
    address internal token; // real B20 (base-forge) or MockB20Token (stock forge)
    address internal tokenNoCode; // an EOA: multiplier read must fail
    bool internal precompilesLive;

    uint256 internal constant PRICE = 100_00000000; // $100.00, 8 decimals
    uint64 internal constant HB = 300; // 5 min

    function setUp() public {
        pusher = makeAddr("pusher");
        registry = new B20FeedRegistry(pusher);
        tokenNoCode = makeAddr("not-a-contract");

        // Prefer the real B20 factory precompile (base-forge); fall back to the
        // mock when precompiles are absent (stock forge). Low-level call: a
        // missing precompile must not revert setUp, it must select the mock.
        bytes memory params = B20FactoryLib.encodeAssetCreateParams("Test Equity", "TSTc", address(this), 8);
        bytes[] memory initCalls = B20FactoryLib.buildRoleGrants(
            B20FactoryLib.B20AssetRoleHolders({
                minter: address(this),
                burner: address(this),
                burnBlocker: address(0),
                pauser: address(this),
                unpauser: address(this),
                metadataAdmin: address(0),
                operator: address(this)
            })
        );
        (bool ok, bytes memory ret) = StdPrecompiles.B20_FACTORY_ADDRESS.call(
            abi.encodeWithSignature("createB20(uint8,bytes32,bytes,bytes[])", 0, bytes32("b20-feeds-test-1"), params, initCalls)
        );
        if (ok && ret.length == 32) {
            token = abi.decode(ret, (address));
            precompilesLive = true;
        } else {
            MockB20Token mock = new MockB20Token();
            token = address(mock);
            precompilesLive = false;
        }

        vm.startPrank(pusher);
        registry.register(1, token, "Coinbase TSTc / USD");
        registry.register(2, tokenNoCode, "Coinbase BROKEN / USD");
        registry.register(3, token, "Coinbase TST2 / USD");
        vm.stopPrank();
    }

    function test_PushComputesAnswerWithLiveMultiplier() public {
        vm.prank(pusher);
        registry.batchPush(_ids(1), _prices(int256(PRICE)), _hbs(HB));

        (uint80 roundId, int256 answer, , , , , ) = registry.getFeed(1);
        assertEq(roundId, 1);
        // multiplier 1.0 -> answer == underlying price exactly
        assertEq(answer, int256(PRICE));
        assertEq(registry.multiplierOf(1), 1e18);
    }

    function test_ScheduledMultiplierChangeFlipsIntoNextPush() public {
        vm.prank(pusher);
        registry.batchPush(_ids(1), _prices(int256(PRICE)), _hbs(HB));

        // Schedule a 2.0 multiplier (10:1-style corporate action) and pass it.
        if (precompilesLive) {
            // address(this) holds OPERATOR_ROLE from creation initCalls.
            // Prefer the scheduled ERC-8056 path; older local precompile
            // builds expose only the instant (deprecated) failsafe.
            (bool ok, ) = token.call(
                abi.encodeWithSignature("updateUIMultiplier(uint256,uint256)", 2e18, block.timestamp + 100)
            );
            if (!ok) {
                (ok, ) = token.call(abi.encodeWithSignature("updateMultiplier(uint256)", 2e18));
                assertTrue(ok, "operator multiplier update failed (both paths)");
            }
        } else {
            MockB20Token(token).updateUIMultiplier(2e18, block.timestamp + 100);
        }
        vm.warp(block.timestamp + 101);

        vm.prank(pusher);
        registry.batchPush(_ids(1), _prices(int256(PRICE)), _hbs(HB));

        // answer = 100 * 2.0 — the contract read the flipped multiplier itself.
        (, int256 answer, , , , , uint256 m) = registry.getFeed(1);
        assertEq(answer, int256(2 * PRICE));
        assertEq(m, 2e18);
    }

    function test_FailedMultiplierReadSkipsFeedButBatchLands() public {
        vm.prank(pusher);
        registry.batchPush(_ids3(1, 2, 3), _prices3(int256(PRICE), int256(PRICE), int256(PRICE)), _hbs3(HB, HB, HB));

        // feed 2's token has no code: skipped, not reverted.
        assertEq(registry.roundIdOf(2), 0);
        // feeds 1 and 3 still landed.
        assertEq(registry.roundIdOf(1), 1);
        assertEq(registry.roundIdOf(3), 1);
    }

    function test_HistoryAndRoundReads() public {
        vm.startPrank(pusher);
        registry.batchPush(_ids(1), _prices(int256(PRICE)), _hbs(HB));
        vm.warp(block.timestamp + 60);
        registry.batchPush(_ids(1), _prices(int256(PRICE + 1_00000000)), _hbs(HB));
        vm.stopPrank();

        (uint80 roundId, int256 answer, , , , , ) = registry.getFeed(1);
        assertEq(roundId, 2);
        assertEq(answer, int256(PRICE + 1_00000000));

        (int256 a0,, ) = registry.getRound(1, 1);
        assertEq(a0, int256(PRICE));

        vm.expectRevert(abi.encodeWithSelector(B20FeedRegistry.RoundOutOfRange.selector, 1, 3));
        registry.getRound(1, 3);
    }

    function test_ProxyAggregatorV3Surface() public {
        vm.prank(pusher);
        registry.batchPush(_ids(1), _prices(int256(PRICE)), _hbs(HB));

        address proxy = registry.proxyOf(1);
        B20FeedProxy p = B20FeedProxy(proxy);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answered) =
            p.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, int256(PRICE));
        assertEq(answered, roundId);
        assertGt(updatedAt, 0);
        assertEq(startedAt, updatedAt);

        (uint80 rid, int256 a, uint256 s2, uint256 u2, uint80 r2) = p.getRoundData(1);
        assertEq(a, int256(PRICE));
        assertEq(s2, startedAt);
        assertEq(u2, updatedAt);
        assertEq(rid, 1);
        assertEq(r2, 1);

        assertEq(p.decimals(), 8);
        assertEq(p.latestAnswer(), int256(PRICE));
        assertEq(p.token(), token);
        assertEq(p.description(), "Coinbase TSTc / USD");
    }

    function test_OnlyPusherCanRegisterAndPush() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(abi.encodeWithSelector(B20FeedRegistry.NotPusher.selector, makeAddr("rando")));
        registry.register(9, token, "x");

        vm.prank(makeAddr("rando"));
        vm.expectRevert(abi.encodeWithSelector(B20FeedRegistry.NotPusher.selector, makeAddr("rando")));
        registry.batchPush(_ids(1), _prices(int256(PRICE)), _hbs(HB));
    }

    function test_ZeroPriceRevertsWholeBatch() public {
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(B20FeedRegistry.InvalidPrice.selector, 0));
        registry.batchPush(_ids(1), _prices(0), _hbs(HB));
    }

    function test_RegisterTwiceReverts() public {
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(B20FeedRegistry.FeedAlreadyRegistered.selector, 1));
        registry.register(1, token, "again");
    }

    function test_StaleRoundEmittedWhenHeartbeatExceeded() public {
        vm.prank(pusher);
        registry.batchPush(_ids(1), _prices(int256(PRICE)), _hbs(HB));
        vm.warp(block.timestamp + 400); // past the 300s heartbeat

        vm.expectEmit(true, true, false, true);
        emit B20FeedRegistry.StaleRound(1, 1, uint64(block.timestamp - 400), HB);
        vm.prank(pusher);
        registry.batchPush(_ids(1), _prices(int256(PRICE)), _hbs(HB));
    }

    function test_UnregisteredFeedReverts() public {
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(B20FeedRegistry.FeedNotRegistered.selector, 77));
        registry.batchPush(_ids(77), _prices(int256(PRICE)), _hbs(HB));
    }

    function test_ManyRoundsStayConsistent() public {
        vm.startPrank(pusher);
        for (uint256 i = 1; i <= 25; ++i) {
            registry.batchPush(_ids(1), _prices(int256(PRICE + i * 1e8)), _hbs(HB));
        }
        vm.stopPrank();

        assertEq(registry.roundIdOf(1), 25);
        assertEq(registry.answerOf(1), int256(PRICE + 25 * 1e8));
        for (uint80 r = 1; r <= 25; ++r) {
            (int256 a,, ) = registry.getRound(1, r);
            assertEq(a, int256(PRICE + uint256(r) * 1e8));
        }
    }

    // ---- helpers ----
    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }
    function _ids3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }
    function _prices(int256 a) internal pure returns (int256[] memory r) {
        r = new int256[](1);
        r[0] = a;
    }
    function _prices3(int256 a, int256 b, int256 c) internal pure returns (int256[] memory r) {
        r = new int256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }
    function _hbs(uint64 a) internal pure returns (uint64[] memory r) {
        r = new uint64[](1);
        r[0] = a;
    }
    function _hbs3(uint64 a, uint64 b, uint64 c) internal pure returns (uint64[] memory r) {
        r = new uint64[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }
}
