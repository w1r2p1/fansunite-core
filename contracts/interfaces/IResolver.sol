pragma solidity ^0.4.24;


/**
 * @title Interface for all FansUnite Resolver contracts
 * @dev Resolvers MUST adhere to the following requirements:
 *     1. The resolver MUST implement init function (the init function is responsible for
 *        resolving the bet, given the league, fixture, bet payload and resolution payload)
 *     2. The getInitSignature function MUST return the init function's signature and it MUST
 *        comply with ABI Specification
 *     3. The getInitSelector function MUST return the init function's selector
 *     4. The init function MUST first consume two arguments of types address and uint, in that
 *        order, the BetManager contract would send the league and fixture. The init function must
 *        then consume all bet payload encoded function parameters followed by resolution encoded
 *        function parameters.
 *     5. The return value of init function MUST be of type uint and one of the following:
 *        + 1 if backer loses bet
 *        + 2 if backer wins bet
 *        + 3 if backer half loses bet
 *        + 4 if backer half wins bet
 *        + 5 if results in a push
 *
 *     6. The resolver MUST implement validator function (the function is responsible for
 *        validating bet payload on bet submission)
 *     7. The getValidatorSignature function MUST return the validator function's signature and it
 *        MUST comply with ABI Specification
 *     8. The getValidatorSelector MUST return the validator function's selector
 *     9. If the init function consumes n bet payload encoded arguments, the validator MUST
 *        consume n + 2 arguments. First, of type address and second of type uint256. The
 *        BetManager would send the league address and event id for bet payload validation.
 *        Following the two parameters, the validator function MUST consume the n bet payload
 *        encoded arguments in the exact same order as that in init.
 *    10. The resolver function MUST return a boolean, true if valid bet payload, false otherwise
 */
contract IResolver {

  /**
   * @notice Checks whether resolver supports a specific league
   * @param _league Address of league contract
   * @return `true` if resolver supports league `_league`, `false` otherwise
   */
  function doesSupportLeague(address _league) external view returns (bool);

  /**
   * @notice Gets the signature of the init function
   * @return The init function signature compliant with ABI Specification
   */
  function getInitSignature() external pure returns (string);

  /**
   * @notice Gets the selector of the init function
   * @dev Probably don't need this function as getInitSignature can be used to compute selector
   * @return Selector for the init function
   */
  function getInitSelector() external pure returns (bytes4);

  /**
   * @notice Gets the signature of the validator function
   * @return The validator function signature compliant with ABI Specification
   */
  function getValidatorSignature() external pure returns (string);

  /**
   * @notice Gets the selector of the validator function
   * @dev Probably don't need this function as getValidatorSignature can be used to compute selector
   * @return Selector for the validator function
   */
  function getValidatorSelector() external pure returns (bytes4);

  /**
   * @notice Gets Resolver's description
   * @return Description of the resolver
   */
  function getDescription() external view returns (string);

  /**
   * @notice Gets the bet type the resolver resolves
   * @return Type of the bet the resolver resolves
   */
  function getType() external view returns (string);

  /**
   * @notice Gets the resolver details
   * @return IPFS hash with resolver details
   */
  function getDetails() external view returns (bytes);

}
