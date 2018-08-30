pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";

library BetLib {

  using SafeMath for uint;

  // Hash for the EIP712 Bet Schema
  bytes32 constant BET_SCHEMA_HASH = keccak256(
    abi.encodePacked(
      "Bet(",
      "address backer,",
      "address layer,",
      "address token,",
      "address feeRecipient,",
      "address league,",
      "address resolver,",
      "uint256 backerStake,",
      "uint256 backerFee,",
      "uint256 layerFee,",
      "uint256 expiration,",
      "uint256 fixture,",
      "uint256 odds,",
      "bytes payload",
      ")"
  ));

  struct Bet {
    address backer;
    address layer;
    address token;
    address feeRecipient;
    address league;
    address resolver;
    uint256 backerStake;
    uint256 backerFee;
    uint256 layerFee;
    uint256 expiration;
    uint256 fixture;
    uint256 odds;
    bytes payload;
  }

  /**
   * @notice Creates a bet struct
   * @param _subjects Associated subjects (check IBetManager for specifics)
   * @param _params Associated parameters (check IBetManager for specifics)
   * @param _payload Payload for resolver
   * @return Returns the bet struct
   */
  function generate(address[6] _subjects, uint[6] _params, bytes _payload)
    internal
    pure
    returns (Bet)
  {
    return Bet({
      backer: _subjects[0],
      layer: _subjects[1],
      token: _subjects[2],
      feeRecipient: _subjects[3],
      league: _subjects[4],
      resolver: _subjects[5],
      backerStake: _params[0],
      backerFee: _params[1],
      layerFee: _params[2],
      expiration: _params[3],
      fixture: _params[4],
      odds: _params[5],
      payload: _payload
    });
  }

  /**
   * @notice Calculates Keccak-256 hash of the bet struct
   * @param _bet The bet struct
   * @param _nonce Arbitrary number to ensure uniqueness of bet hash
   * @return Keccak-256 EIP712 hash of the bet.
   */
  function hash(Bet _bet, uint _nonce) internal pure returns (bytes32) {

    bytes memory _subjects = abi.encodePacked(
      _bet.backer,
      _bet.layer,
      _bet.token,
      _bet.feeRecipient,
      _bet.league,
      _bet.resolver
    );

    bytes memory _params = abi.encodePacked(
      _bet.backerStake,
      _bet.backerFee,
      _bet.layerFee,
      _bet.expiration,
      _bet.fixture,
      _bet.odds
    );

    bytes32 _hash = keccak256(
      abi.encodePacked(
        BET_SCHEMA_HASH,
        _subjects,
        _params,
        keccak256(_bet.payload)
      )
    );

    return keccak256(abi.encodePacked(_nonce, _hash));
  }

  /**
   * @notice Calculates the return of bet for the backer
   * @param _bet Structure of the bet
   * @param _decimals Decimals of the odds
   * @return Returns the amount that backer wins based on the odds
   */
  function backerTokenReturn(Bet _bet, uint _decimals) internal pure returns (uint) {
    return _bet.backerStake.mul(_bet.odds).div(10 ** _decimals);
  }

}
