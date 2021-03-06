pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";

import "./interfaces/IBetManager.sol";
import "./interfaces/ILeague.sol";
import "./interfaces/ILeagueRegistry.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/IResolver.sol";
import "./interfaces/IVault.sol";

import "./libraries/BetLib.sol";
import "./libraries/SignatureLib.sol";

import "./utils/RegistryAccessible.sol";
import "./utils/ChainSpecifiable.sol";
import "./interfaces/IResolverRegistry.sol";

/**
 * @title Bet Manger Contract
 * @notice BetManager is the core contract responsible for bet validations and bet submissions
 */
contract BetManager is Ownable, IBetManager, RegistryAccessible, ChainSpecifiable {

  using SafeMath for uint;

  // Number of decimal places in BetLib.Odds
  uint public constant ODDS_DECIMALS = 4;

  // Oracle fee dividing factor (1 / 400 = 0.0025)
  uint public constant ORACLE_FEE = 400;

  // Resolves to `true` if hash is used, `false` otherwise
  mapping(bytes32 => bool) internal unclaimed;
  // Resolves to `true` if bet has been claimed, `false` otherwise
  mapping(bytes32 => bool) internal claimed;
  // Mapping of user address to array of bet hashes
  mapping(address => bytes32[]) internal bets;

  // Emit when a Bet has been submitted
  event LogBetSubmitted(
    bytes32 indexed _hash,
    address indexed _backer,
    address indexed _layer,
    address[3] _subjects,
    uint[4] _params,
    uint _nonce,
    bytes _payload
  );
  // Emit when a Bet has been claimed
  event LogBetClaimed(
    bytes32 indexed _hash,
    uint256 indexed _result
  );

  /**
   * @notice Constructor
   * @dev Change chainId in case of a fork, making sure txs cannot be replayed on forked chains
   * @param _chainId ChainId to be set
   */
  constructor(uint _chainId, address _registry)
    public
    ChainSpecifiable(_chainId)
    RegistryAccessible(_registry)
  {

  }

  /**
   * @notice Submits a bet
   * @param _subjects Subjects associated with bet [backer, layer, token, league, resolver]
   * @param _params Parameters associated with bet [backerStake, fixture, odds, expiration]
   * @param _nonce Nonce, to ensure hash uniqueness
   * @param _payload Payload for resolver
   * @param _signature ECDSA signature along with the mode
   *  (0 = Typed, 1 = Geth, 2 = Trezor) {mode}{v}{r}{s}.
   */
  function submitBet(
    address[5] _subjects,
    uint[4] _params,
    uint _nonce,
    bytes _payload,
    bytes _signature
  )
    external
  {
    BetLib.Bet memory _bet = BetLib.generate(_subjects, _params, _payload);
    bytes32 _hash = BetLib.hash(_bet, chainId, _nonce);

    _authenticateBet(_bet, _hash, _signature);
    _authorizeBet(_bet);
    _validateBet(_bet);
    _processBet(_bet, _hash);

    emit LogBetSubmitted(
      _hash,
      _bet.backer,
      _bet.layer,
      [_bet.token, _bet.league, _bet.resolver],
      [_bet.backerStake, _bet.fixture, _bet.odds, _bet.expiration],
      _nonce,
      _payload
    );
  }

  /**
   * @notice Claims a bet, transfers tokens and fees based on fixture resolution
   * @param _subjects Subjects associated with bet
   * @param _params Parameters associated with bet
   * @param _nonce Nonce, to ensure hash uniqueness
   * @param _payload Payload for resolver
   */
  function claimBet(address[5] _subjects, uint[4] _params, uint _nonce, bytes _payload) external {
    BetLib.Bet memory _bet = BetLib.generate(_subjects, _params, _payload);
    bytes32 _hash = BetLib.hash(_bet, chainId, _nonce);

    require(unclaimed[_hash], "Bet with given parameters either claimed or never submitted");

    uint _result = _getResult(_bet.league, _bet.resolver, _bet.fixture, _payload);
    _processClaim(_bet, _hash, _result);

    emit LogBetClaimed(_hash, _result);
  }

  /**
   * @notice Gets the bet result
   * @param _league Address of league
   * @param _resolver Address of resolver
   * @param _fixture Id of fixture
   * @param _payload Payload for resolver
   * @return uint between 1 and 5 (check IResolver for details) or 0 (for unresolved fixtures)
   */
  function getResult(address _league, address _resolver, uint _fixture, bytes _payload)
    external
    view
    returns (uint)
  {
    return _getResult(_league, _resolver, _fixture, _payload);
  }

  /**
   * @notice Gets all the bet identifiers for address `_subject`
   * @param _subject Address of a layer or backer
   * @return Returns list of bet ids for backer / layer `_subject`
   */
  function getBetsBySubject(address _subject) external view returns (bytes32[]) {
    return bets[_subject];
  }

  /**
   * @dev Throws if any of the following checks fail
   *  + `msg.sender` is `_bet.layer`
   *  + `msg.sender` is not `_bet.backer`
   *  + `_bet.backer` has signed `_hash`
   *  + `_hash` is unique (preventing replay attacks)
   * @param _bet Bet struct
   * @param _hash Keccak-256 hash of the bet struct, along with chainId and nonce
   * @param _signature ECDSA signature along with the mode
   */
  function _authenticateBet(BetLib.Bet memory _bet, bytes32 _hash, bytes _signature)
    internal
    view
  {
    require(
      msg.sender == _bet.layer,
      "Bet is not permitted for the msg.sender to take"
    );
    require(
      _bet.backer != address(0) && _bet.backer != msg.sender,
      "Bet is not permitted for the msg.sender to take"
    );
    require(
      !(claimed[_hash] || unclaimed[_hash]),
      "Bet with same hash been submitted before"
    );
    require(
      SignatureLib.isValidSignature(_hash, _bet.backer, _signature),
      "Tx is sent with an invalid signature"
    );
  }

  /**
   * @dev Throws if any of the following checks fail
   *  + `address(this)` is an approved spender by both backer and layer
   *  + `_bet.backer` has appropriate amount staked in vault
   *  + `_bet.layer` has appropriate amount staked in vault
   * @param _bet Bet struct
   */
  function _authorizeBet(BetLib.Bet memory _bet) internal view {
    IVault _vault = IVault(registry.getAddress("FanVault"));

    require(
      _vault.isApproved(_bet.backer, address(this)),
      "Backer has not approved BetManager to move funds in Vault"
    );
    require(
      _vault.isApproved(_bet.layer, address(this)),
      "Layer has not approved BetManager to move funds in Vault"
    );
    require(
      _vault.balanceOf(_bet.token, _bet.backer) >= _bet.backerStake,
      "Backer does not have sufficient tokens"
    );
    require(
      _vault.balanceOf(_bet.token, _bet.layer) >= BetLib.backerReturn(_bet, ODDS_DECIMALS),
      "Layer does not have sufficient tokens"
    );
  }

  /**
   * @dev Throws if any of the following checks fail
   *  + `_bet.league` is a registered league with FansUnite
   *  + `_bet.resolver` is registered with league
   *  + `_bet.fixture` is scheduled with league
   *  + `_bet.resolver` is not resolved for `_bet.fixture`
   *  + `_bet.backerStake` must belong to set ℝ+
   *  + `_bet.odds` must belong to set ℝ+
   *  + `_bet.expiration` is greater than `now`
   *  + `_bet.payload` is valid according to resolver
   * @param _bet Bet struct
   */
  function _validateBet(BetLib.Bet memory _bet) internal view {
    address _leagueRegistry = registry.getAddress("LeagueRegistry");
    address _resolverRegistry = registry.getAddress("ResolverRegistry");
    ILeague _league = ILeague(_bet.league);

    require(
      ILeagueRegistry(_leagueRegistry).isLeagueRegistered(_bet.league),
      "League is not registered with FansUnite"
    );
    require(
      IResolverRegistry(_resolverRegistry).isResolverUsed(_bet.league, _bet.resolver),
      "Resolver is not usable with league"
    );
    require(
      _league.isFixtureScheduled(_bet.fixture),
      "Fixture is not scheduled with League"
    );
    require(
      _league.isFixtureResolved(_bet.fixture, _bet.resolver) != 1,
      "Fixture is already resolved"
    );
    require(
      _bet.backerStake > 0,
      "Stake does not belong to set ℝ+"
    );
    require(
      _bet.odds > 0,
      "Odds does not belong to set ℝ+"
    );
    require(
      _bet.expiration > block.timestamp,
      "Bet has expired"
    );

    __validatePayload(_bet);

  }

  /**
   * @dev Processes the funds and stores the bet
   * @param _bet Bet struct
   * @param _hash Keccak-256 hash of the bet struct, along with chainId and nonce
   */
  function _processBet(BetLib.Bet memory _bet, bytes32 _hash) internal {
    IVault _vault = IVault(registry.getAddress("FanVault"));
    uint _backerStake = _bet.backerStake;
    uint _layerStake = BetLib.backerReturn(_bet, ODDS_DECIMALS);

    unclaimed[_hash] = true;

    bets[_bet.backer].push(_hash);
    bets[msg.sender].push(_hash);

    require(
      _vault.transferFrom(_bet.token, _bet.backer, address(this), _backerStake),
      "Cannot transfer backer's stake to pool"
    );

    require(
      _vault.transferFrom(_bet.token, _bet.layer, address(this), _layerStake),
      "Cannot transfer layer's stake to pool"
    );
  }

  /**
   * @dev Processes the funds based on result
   * @param _bet Bet struct
   * @param _hash Keccak-256 hash of the bet struct, along with chainId and nonce
   * @param _result Result of the bet
   */
  function _processClaim(BetLib.Bet memory _bet, bytes32 _hash, uint _result) internal {
    bool _expired = ILeague(_bet.league).getFixtureStart(_bet.fixture) + 7 days <= block.timestamp;
    require(_result > 0 || _expired, "Bet cannot be resolved yet");

    unclaimed[_hash] = false;
    claimed[_hash] = true;

    if (_result == 0) __processRevert(_bet);
    else if (_result == 1) __processLose(_bet);
    else if (_result == 2) __processWin(_bet);
    else if (_result == 3) __processHalfLose(_bet);
    else if (_result == 4) __processHalfWin(_bet);
    else if (_result == 5) __processPush(_bet);
    else __processFallBack(_bet);
  }


  /**
   * @notice Gets the bet result
   * @param _league Address of league
   * @param _resolver Address of resolver
   * @param _fixture Id of fixture
   * @param _payload Payload for resolver
   * @return uint between 1 and 5 (check IResolver for details) or 0 (for unresolved fixtures)
   */
  function _getResult(address _league, address _resolver, uint _fixture, bytes _payload)
    internal
    view
    returns (uint)
  {
    if (ILeague(_league).isFixtureResolved(_fixture, _resolver) != 1) return 0;

    bytes memory _resolution = ILeague(_league).getResolution(_fixture, _resolver);
    return __getResult(_league, _resolver, _fixture, _payload, _resolution);
  }

  /**
   * @dev Throws if `_payload` is not valid
   * @param _bet Bet struct
   */
  function __validatePayload(BetLib.Bet memory _bet) private view {
    bool _isPayloadValid;
    address _resolver = _bet.resolver;
    address _league = _bet.league;
    uint256 _fixture = _bet.fixture;
    bytes4 _selector = IResolver(_resolver).getValidatorSelector();
    bytes memory _payload = _bet.payload;

    assembly {
      let _plen := mload(_payload)               // _plen = length of _payload
      let _tlen := add(_plen, 0x44)              // _tlen = total length of calldata
      let _p    := add(_payload, 0x20)           // _p    = encoded bytes of _payload

      let _ptr   := mload(0x40)                  // _ptr   = free memory pointer
      let _index := mload(0x40)                  // _index = same as _ptr
      mstore(0x40, add(_ptr, _tlen))             // update free memory pointer

      mstore(_index, _selector)                  // store selector at _index
      _index := add(_index, 0x04)                // _index = _index + 0x04
      _index := add(_index, 0x0C)                // _index = _index + 0x0C
      mstore(_index, _league)                    // store address at _index
      _index := add(_index, 0x14)                // _index = _index + 0x14
      mstore(_index, _fixture)                   // store _fixture at _index
      _index := add(_index, 0x20)                // _index = _index + 0x20

      for
      { let _end := add(_p, _plen) }             // init: _end = _p + _plen
      lt(_p, _end)                               // cond: _p < _end
      { _p := add(_p, 0x20) }                    // incr: _p = _p + 0x20
      {
        mstore(_index, mload(_p))                // store _p to _index
        _index := add(_index, 0x20)              // _index = _index + 0x20
      }

      let result := staticcall(30000, _resolver, _ptr, _tlen, _ptr, 0x20)

      switch result
      case 0 {
        // revert(_ptr, 0x20) dealt with outside of assembly
        _isPayloadValid := mload(_ptr)
      }
      default {
        _isPayloadValid := mload(_ptr)
      }
    }

    require(
      _isPayloadValid,
      "Bet payload is not valid"
    );
  }

  /**
   * @dev Gets the bet result based on arguments
   * @param __league Address of league
   * @param __resolver Address of resolver
   * @param __fixture Id of fixture
   * @param __payload bet payload encoded function parameters
   * @param __resolution resolution encoded function parameters
   * @return uint between 1 and 5 (check IResolver for details) or 0 (for failed call)
   */
  function __getResult(
    address __league,
    address __resolver,
    uint __fixture,
    bytes __payload,
    bytes __resolution
  )
    private
    view
    returns (uint)
  {
    uint _result;
    bytes4 _selector = IResolver(_resolver).getInitSelector();
    address _league = __league;
    address _resolver = __resolver;
    uint _fixture = __fixture;
    bytes memory _payload = __payload;
    bytes memory _resolution = __resolution;

    assembly {
      let _plen := mload(_payload)               // _plen = length of _payload
      let _rlen := mload(_resolution)            // _rlen = length of _resolution
      let _tlen := add(_rlen, add(_plen, 0x44))  // _tlen = total length of calldata
      let _p    := add(_payload, 0x20)           // _p    = encoded bytes of _payload
      let _r    := add(_payload, 0x20)           // _r    = encoded bytes of _resolution

      let _ptr   := mload(0x40)                  // _ptr   = free memory pointer
      let _index := mload(0x40)                  // _index = same as _ptr
      mstore(0x40, add(_ptr, _tlen))             // update free memory pointer

      mstore(_index, _selector)                  // store selector at _index
      _index := add(_index, 0x04)                // _index = _index + 0x04
      _index := add(_index, 0x0C)                // _index = _index + 0x0C
      mstore(_index, _league)                    // store address at _index
      _index := add(_index, 0x14)                // _index = _index + 0x14
      mstore(_index, _fixture)                   // store _fixture at _index
      _index := add(_index, 0x20)                // _index = _index + 0x20

      for
      { let _end := add(_p, _plen) }             // init: _end = _p + _plen
      lt(_p, _end)                               // cond: _p < _end
      { _p := add(_p, 0x20) }                    // incr: _p = _p + 0x20
      {
        mstore(_index, mload(_p))                // store _p to _index
        _index := add(_index, 0x20)              // _index = _index + 0x20
      }

      for
      { let _end := add(_r, _rlen) }                 // init: _end = _r + _rlen
      lt(_r, _end)                               // cond: _r < _end
      { _r := add(_r, 0x20) }                    // incr: _r = _r + 0x20
      {
        mstore(_index, mload(_r))                // store _r to _index
        _index := add(_index, 0x20)              // _index = _index + 0x20
      }

      let result := staticcall(30000, _resolver, _ptr, _tlen, _ptr, 0x20)

      switch result
      case 0 {
        // Nothing here
      }
      default {
        _result := mload(_ptr)
      }
    }

    return _result;
  }

  /**
   * @dev Processes the funds back to owners
   * @param _bet Bet struct
   */
  function __processRevert(BetLib.Bet memory _bet) private {
    IVault _vault = IVault(registry.getAddress("FanVault"));
    uint _backerStake = _bet.backerStake;
    uint _layerStake = BetLib.backerReturn(_bet, ODDS_DECIMALS);

    require(
      _vault.transfer(_bet.token, _bet.backer, _backerStake),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _bet.layer, _layerStake),
      "Cannot transfer stake from pool"
    );
  }

  /**
   * @dev Processes funds when backer loses
   * @param _bet Bet struct
   */
  function __processLose(BetLib.Bet memory _bet) private {
    IVault _vault = IVault(registry.getAddress("FanVault"));
    address _consensusManager = registry.getAddress("ConsensusManager");

    uint _backerStake = _bet.backerStake;
    uint _layerStake = BetLib.backerReturn(_bet, ODDS_DECIMALS);

    uint _totalStakeBeforeFee = _backerStake.add(_layerStake);
    uint _oracleFee = _totalStakeBeforeFee.div(ORACLE_FEE);
    uint _totalStakeAfterFee = _totalStakeBeforeFee.sub(_oracleFee);

    require(
      _vault.transfer(_bet.token, _bet.layer, _totalStakeAfterFee),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _consensusManager, _oracleFee),
      "Cannot transfer stake from pool"
    );
  }

  /**
   * @dev Processes funds when backer wins
   * @param _bet Bet struct
   */
  function __processWin(BetLib.Bet memory _bet) private {
    IVault _vault = IVault(registry.getAddress("FanVault"));
    address _consensusManager = registry.getAddress("ConsensusManager");

    uint _backerStake = _bet.backerStake;
    uint _layerStake = BetLib.backerReturn(_bet, ODDS_DECIMALS);

    uint _totalStakeBeforeFee = _backerStake.add(_layerStake);
    uint _oracleFee = _totalStakeBeforeFee.div(ORACLE_FEE);
    uint _totalStakeAfterFee = _totalStakeBeforeFee.sub(_oracleFee);

    require(
      _vault.transfer(_bet.token, _bet.backer, _totalStakeAfterFee),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _consensusManager, _oracleFee),
      "Cannot transfer stake from pool"
    );
  }

  /**
   * @dev Processes funds when backer half loses bet
   * @param _bet Bet struct
   */
  function __processHalfLose(BetLib.Bet memory _bet) private {
    IVault _vault = IVault(registry.getAddress("FanVault"));
    address _consensusManager = registry.getAddress("ConsensusManager");

    uint _backerStakeBeforeFee = _bet.backerStake;
    uint _layerStakeBeforeFee = BetLib.backerReturn(_bet, ODDS_DECIMALS);

    uint _backerOracleFee = _backerStakeBeforeFee.div(ORACLE_FEE);
    uint _layerOracleFee = _layerStakeBeforeFee.div(ORACLE_FEE);

    uint _backerReturnBeforeFee = _backerStakeBeforeFee.div(2);
    uint _layerReturnBeforeFee = _layerStakeBeforeFee.add(_backerReturnBeforeFee);

    uint _backerReturnAfterFee = _backerReturnBeforeFee.sub(_backerOracleFee);
    uint _layerReturnAfterFee = _layerReturnBeforeFee.sub(_layerOracleFee);

    uint _oracleFee = _backerOracleFee.add(_layerOracleFee);

    require(
      _vault.transfer(_bet.token, _bet.backer, _backerReturnAfterFee),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _bet.layer, _layerReturnAfterFee),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _consensusManager, _oracleFee),
      "Cannot transfer stake from pool"
    );

  }

  /**
   * @dev Processes funds when backer half wins bet
   * @param _bet Bet struct
   */
  function __processHalfWin(BetLib.Bet memory _bet) private {
    IVault _vault = IVault(registry.getAddress("FanVault"));
    address _consensusManager = registry.getAddress("ConsensusManager");

    uint _backerStakeBeforeFee = _bet.backerStake;
    uint _layerStakeBeforeFee = BetLib.backerReturn(_bet, ODDS_DECIMALS);

    uint _backerOracleFee = _backerStakeBeforeFee.div(ORACLE_FEE);
    uint _layerOracleFee = _layerStakeBeforeFee.div(ORACLE_FEE);

    uint _layerReturnBeforeFee = _layerStakeBeforeFee.div(2);
    uint _backerReturnBeforeFee = _backerStakeBeforeFee.add(_layerReturnBeforeFee);

    uint _backerReturnAfterFee = _backerReturnBeforeFee.sub(_backerOracleFee);
    uint _layerReturnAfterFee = _layerReturnBeforeFee.sub(_layerOracleFee);

    uint _oracleFee = _backerOracleFee.add(_layerOracleFee);

    require(
      _vault.transfer(_bet.token, _bet.backer, _backerReturnAfterFee),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _bet.layer, _layerReturnAfterFee),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _consensusManager, _oracleFee),
      "Cannot transfer stake from pool"
    );
  }

  /**
   * @dev Processes funds when bet results in push
   * @param _bet Bet struct
   */
  function __processPush(BetLib.Bet memory _bet) private {
    IVault _vault = IVault(registry.getAddress("FanVault"));
    address _consensusManager = registry.getAddress("ConsensusManager");

    uint _backerStakeBeforeFee = _bet.backerStake;
    uint _layerStakeBeforeFee = BetLib.backerReturn(_bet, ODDS_DECIMALS);

    uint _backerOracleFee = _backerStakeBeforeFee.div(ORACLE_FEE);
    uint _layerOracleFee = _layerStakeBeforeFee.div(ORACLE_FEE);

    uint _backerStakeAfterFee = _backerStakeBeforeFee.sub(_backerOracleFee);
    uint _layerStakeAfterFee = _layerStakeBeforeFee.sub(_layerOracleFee);

    uint _oracleFee = _backerOracleFee.add(_layerOracleFee);

    require(
      _vault.transfer(_bet.token, _bet.backer, _backerStakeAfterFee),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _bet.layer, _layerStakeAfterFee),
      "Cannot transfer stake from pool"
    );

    require(
      _vault.transfer(_bet.token, _consensusManager, _oracleFee),
      "Cannot transfer stake from pool"
    );
  }

  /**
   * @dev Processes funds in case of a fall back
   * @param _bet Bet struct
   */
  function __processFallBack(BetLib.Bet memory _bet) private {
    IVault _vault = IVault(registry.getAddress("FanVault"));
    address _fanOrg = registry.getAddress("FanOrg");

    uint _backerStake = _bet.backerStake;
    uint _layerStake = BetLib.backerReturn(_bet, ODDS_DECIMALS);
    uint _totalStake = _backerStake.add(_layerStake);

    require(
      _vault.transfer(_bet.token, _fanOrg, _totalStake),
      "Cannot transfer stake from pool"
    );
  }

}
