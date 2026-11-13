// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {B20FeedProxy} from "./B20FeedProxy.sol";



/// @title B20FeedRegistry
/// @notice Onchain price feeds for Coinbase tokenized stocks (B20) on Base
///         that have no Chainlink feed. AggregatorV3-compatible read surface
///         per token (B20FeedProxy), so a Chainlink consumer swaps one
///         address and changes nothing else.
/// @dev The B20-native design difference from the Robinhood Chain oracle:
///      the multiplier is read ONCHAIN from the token inside the push itself.
///      The pusher supplies only the underlying equity price (8 decimals,
///      price of ONE share); the registry computes
///          answer = underlyingPrice * uiMultiplier / 1e18
///      which is the issuer's own documented formula for the token NAV
///      (Total Return Value). A stale multiplier in the pusher is therefore
///      impossible — the contract uses whatever the token reports at push
///      time, and records it in `multiplierOf` for audit.
///      Admin power, stated plainly: exactly one pusher address may register
///      feeds and publish rounds. Set at construction, immutable, no owner
///      functions, no upgrade path. At mainnet the pusher key moves to a
///      timelock or multisig in a new deployment, by the owner, in the open.
///      History is append-only; a later revision may ring-buffer the tail.
contract B20FeedRegistry {
    uint8 public constant DECIMALS = 8;
    uint256 public constant WAD = 1e18;
    /// @dev Multipliers come from issuer-operated tokens; sane range guard
    ///      before multiplying. Real values are ~1e18 (1.0) to ~10e18 (10:1 split).
    uint256 public constant MAX_MULTIPLIER = 1e30;
    /// @dev ERC-8056 alias view (selector 0xa60bf13d), what Coinbase tokenized
    ///      stocks answer on Base mainnet (verified 2026-11-13 against AAPLc).
    bytes4 private constant UI_MULTIPLIER_SELECTOR = 0xa60bf13d;
    /// @dev Canonical B20 name for the same view (selector 0x1b3ed722); some
    ///      Base builds (base-anvil v1.1.x) answer only this one. Both return
    ///      the WAD-scaled (1e18) redemption ratio.
    bytes4 private constant MULTIPLIER_SELECTOR = 0x1b3ed722;

    address public immutable pusher;

    // Flat per-feed storage; feedId is a stable small integer chosen offchain.
    mapping(uint256 => string) public descriptionOf;
    mapping(uint256 => address) public tokenOf;
    mapping(uint256 => uint80) public roundIdOf;
    mapping(uint256 => int256) public answerOf;
    mapping(uint256 => uint64) public startedAtOf;
    mapping(uint256 => uint64) public updatedAtOf;
    mapping(uint256 => address) public proxyOf;
    /// @notice Last multiplier the registry read from the token at push time.
    mapping(uint256 => uint256) public multiplierOf;

    // Append-only round history. historyOf[feedId][roundId] exists for every
    // round from 1 to roundIdOf[feedId]. Round 0 is never written.
    struct Round {
        int192 answer;
        uint32 startedAt;
        uint32 updatedAt;
    }
    mapping(uint256 => mapping(uint80 => Round)) public historyOf;

    event FeedRegistered(uint256 indexed feedId, address indexed token, address indexed proxy, string description);
    event RoundPushed(
        uint256 indexed feedId,
        uint80 roundId,
        int256 answer,
        int256 underlyingPrice,
        uint256 multiplier,
        uint64 updatedAt,
        uint64 heartbeat
    );
    event StaleRound(uint256 indexed feedId, uint80 indexed roundId, uint64 updatedAt, uint64 heartbeat);
    /// @notice A feed was skipped in a batch: its token's multiplier could not
    ///         be read or was out of range. The rest of the batch still landed.
    event FeedPushFailed(uint256 indexed feedId, string reason);

    error NotPusher(address caller);
    error LengthMismatch();
    error InvalidPrice(int256 price);
    error ZeroToken();
    error FeedNotRegistered(uint256 feedId);
    error FeedAlreadyRegistered(uint256 feedId);
    error RoundOutOfRange(uint256 feedId, uint80 roundId);

    constructor(address pusher_) {
        pusher = pusher_;
    }

    /// @notice Register a feed for a B20 token and deploy its proxy.
    ///         Pusher only, one-time per feedId.
    function register(uint256 feedId, address token, string calldata description) external returns (address proxy) {
        if (msg.sender != pusher) revert NotPusher(msg.sender);
        if (token == address(0)) revert ZeroToken();
        if (proxyOf[feedId] != address(0)) revert FeedAlreadyRegistered(feedId);

        proxy = address(new B20FeedProxy(this, feedId));
        proxyOf[feedId] = proxy;
        tokenOf[feedId] = token;
        descriptionOf[feedId] = description;

        emit FeedRegistered(feedId, token, proxy, description);
    }

    /// @notice Publish one round for many feeds in a single transaction.
    ///         Pusher supplies the UNDERLYING equity price (8 decimals, one
    ///         share); the answer is computed onchain with the token's live
    ///         uiMultiplier. Readers run their own staleness check on
    ///         updatedAt, exactly as Base's docs instruct for Chainlink feeds.
    ///         A feed whose multiplier cannot be read is skipped (event
    ///         FeedPushFailed) so one bad token can never freeze the batch.
    function batchPush(
        uint256[] calldata feedIds,
        int256[] calldata underlyingPrices,
        uint64[] calldata heartbeats
    ) external {
        if (msg.sender != pusher) revert NotPusher(msg.sender);
        uint256 n = feedIds.length;
        if (n != underlyingPrices.length || n != heartbeats.length) revert LengthMismatch();

        uint64 now_ = uint64(block.timestamp);
        for (uint256 i = 0; i < n; ++i) {
            uint256 feedId = feedIds[i];
            int256 price = underlyingPrices[i];
            // A non-positive price is a pusher bug: fail the whole batch loudly.
            if (price <= 0) revert InvalidPrice(price);
            if (proxyOf[feedId] == address(0)) revert FeedNotRegistered(feedId);

            // Low-level staticcall: never reverts for a bad target (an
            // unresolvable address or a reverting view), so one broken token
            // can never abort the batch. Try the ERC-8056 alias first, then
            // the canonical B20 name.
            uint256 m;
            bool ok;
            bytes memory ret;
            (ok, ret) = tokenOf[feedId].staticcall(abi.encodeWithSelector(UI_MULTIPLIER_SELECTOR));
            if (ok && ret.length == 32) {
                m = abi.decode(ret, (uint256));
            } else {
                (ok, ret) = tokenOf[feedId].staticcall(abi.encodeWithSelector(MULTIPLIER_SELECTOR));
                if (ok && ret.length == 32) {
                    m = abi.decode(ret, (uint256));
                } else {
                    emit FeedPushFailed(feedId, "multiplier read failed");
                    continue;
                }
            }
            if (m == 0 || m > MAX_MULTIPLIER) {
                emit FeedPushFailed(feedId, "multiplier out of range");
                continue;
            }

            uint256 ans = (uint256(price) * m) / WAD;
            if (ans > uint256(uint192(type(int192).max))) {
                emit FeedPushFailed(feedId, "answer overflow");
                continue;
            }

            uint80 prevId = roundIdOf[feedId];
            if (prevId != 0) {
                uint64 prevUpdatedAt = updatedAtOf[feedId];
                uint64 hb = heartbeats[i];
                if (now_ > prevUpdatedAt + hb) {
                    emit StaleRound(feedId, prevId, prevUpdatedAt, hb);
                }
            }

            uint80 roundId = prevId + 1;
            roundIdOf[feedId] = roundId;
            answerOf[feedId] = int256(ans);
            startedAtOf[feedId] = now_;
            updatedAtOf[feedId] = now_;
            multiplierOf[feedId] = m;
            historyOf[feedId][roundId] = Round(int192(int256(ans)), uint32(now_), uint32(now_));

            emit RoundPushed(feedId, roundId, int256(ans), price, m, now_, heartbeats[i]);
        }
    }

    /// @notice Whole-feed read for consumers that prefer one call.
    function getFeed(uint256 feedId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint64 startedAt,
            uint64 updatedAt,
            address proxy,
            address token,
            uint256 multiplier
        )
    {
        if (proxyOf[feedId] == address(0)) revert FeedNotRegistered(feedId);
        return (
            roundIdOf[feedId],
            answerOf[feedId],
            startedAtOf[feedId],
            updatedAtOf[feedId],
            proxyOf[feedId],
            tokenOf[feedId],
            multiplierOf[feedId]
        );
    }

    /// @notice Historical round read. Round 0 does not exist.
    function getRound(uint256 feedId, uint80 roundId)
        external
        view
        returns (int256 answer, uint64 startedAt, uint64 updatedAt)
    {
        if (roundId == 0 || roundId > roundIdOf[feedId]) revert RoundOutOfRange(feedId, roundId);
        Round storage r = historyOf[feedId][roundId];
        return (int256(r.answer), uint64(r.startedAt), uint64(r.updatedAt));
    }
}
