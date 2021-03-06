pragma solidity ^0.4.24;

import "../interfaces/IResolver.sol";
import "../leagues/ILeague001.sol";
import "./BaseResolver.sol";

/**
 * @title Spreads Resolver
 * @dev RSpreads2 is a simple Spreads bet type resolver contract
 */
contract RSpreads2 is IResolver, BaseResolver {

  uint public TOTAL_DECIMALS = 2;

  // NOTE This is a HIGHLY experimental resolver, do NOT use in production

  /**
   * @notice Constructor
   * @param _version Base version Resolver supports
   */
  constructor(string _version) public BaseResolver(_version) { }

  /**
   * @notice Returns the Result of a Totals bet
   * @param _league Address of league
   * @param _fixture Id of fixture
   * @param _bParticipant bet payload encoded, participant id
   * @param _bSpread bet payload encoded, total score
   * @param _rScores Array of scores, matching index as fixture.participants (resolution data)
   * @return Bet outcome compliant with IResolver Specs [1,2,3,4,5]
   */
  function resolve(
    address _league,
    uint _fixture,
    uint _bParticipant,
    int _bSpread,
    uint[] _rScores
  )
    external
    view
    returns (uint)
  {
    var (, _participants,) = ILeague001(_league).getFixture(_fixture);

    uint _i = _participants[0] == _bParticipant ? 0 : 1;
    int _spread = int(_rScores[_i]) - int(_rScores[1 - _i]);
    _spread = _spread * int(10 ** TOTAL_DECIMALS);

    int _x = _bSpread + _spread;

    if (_x == 25) return 4;
    if (_x == -25) return 3;
    if (_x > 25) return 2;
    if (_x < -25) return 1;
    return 5;
  }

  /**
   * @notice Checks if `_participant` is scheduled in fixture and if `_spread` is multiple of 25
   * @param _league League Address to perform validation for
   * @param _fixture Id of fixture
   * @param _participant Id of participant from bet payload, 0 if team totals
   * @param _spread Spread between scores, from bet payload
   * @return `true` if bet payload valid, `false` otherwise
   */
  function validate(address _league, uint _fixture, uint _participant, int _spread)
    external
    view
    returns (bool)
  {
    return ILeague001(_league).isParticipantScheduled(_participant, _fixture) || _spread % 25 == 0;
  }

  /**
   * @notice Gets the signature of the init function
   * @return The init function signature compliant with ABI Specification
   */
  function getInitSignature() external pure returns (string) {
    return "resolve(address,uint256,uint256,int256,uint256[])";
  }

  /**
   * @notice Gets the selector of the init function
   * @dev Probably don't need this function as getInitSignature can be used to compute selector
   * @return Selector for the init function
   */
  function getInitSelector() external pure returns (bytes4) {
    return this.resolve.selector;
  }

  /**
   * @notice Gets the signature of the validator function
   * @return The validator function signature compliant with ABI Specification
   */
  function getValidatorSignature() external pure returns (string) {
    return "validate(address,uint256,uint256,int256)";
  }

  /**
   * @notice Gets the selector of the validator function
   * @dev Probably don't need this function as getValidatorSignature can be used to compute selector
   * @return Selector for the validator function
   */
  function getValidatorSelector() external pure returns (bytes4) {
    return this.validate.selector;
  }

  /**
   * @notice Gets Resolver's description
   * @return Description of the resolver
   */
  function getDescription() external view returns (string) {
    return "Common Spreads Resolver for two player leagues: Betting on the spreads between scores";
  }

  /**
   * @notice Gets the bet type the resolver resolves
   * @return Type of the bet the resolver resolves
   */
  function getType() external view returns (string) {
    return "RSpreads2";
  }

  /**
   * @notice Gets the resolver details
   * @return IPFS hash with resolver details
   */
  function getDetails() external view returns (bytes) {
    return new bytes(0);
  }

}
