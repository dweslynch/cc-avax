pragma solidity ^0.8.10;

import "./erc-20/IERC20Metadata.sol";

// Modeled after ERC-20 standard even though negative balances aren't compatible
contract CoveredCall
{
  address payable public origin;                                                // The exchange contract governing the protocal

  IERC20Metadata public underlying;
  uint8 public underlying_decimals;
  address public underlying_address;

  uint256 public price;                                                         // Strike price for the contract
  uint public expiration;                                                       // Expiration date, American style
  uint256 public interest;                                                      // Open interest

  mapping (address => int256) private _balances;                                // Maps addresses to a long or short balance
  mapping (address => uint256) private _coverage;                               // How much of the underlying a short address has deposited
  mapping (address => uint256) private _shorts_index;                           // A given address's place in the shorts array
  address[] private _shorts = [0];                                              // All open shorts for use during assignment

  uint public immutable ASSIGNMENT_FEE = 2;                                     // Assignment fee as a percent

  modifier restricted
  {
    require(msg.sender == origin);
    _;
  }

  constructor(address protocol, asset, strike, uint expiration_date)
  {
    origin = protocol;
    price = strike;                                                             // Strike price denominated in AVAX^-18
    underlying_address = asset;
    underlying = IERC20Metadata(asset);
    underling_decimals = underlying.decimals();
    expiration = expiration_date;
    interest = 0;
  }

  // Execute a sale from short to long, creating or destroying open interest as necessary
  // This function is restricted to being called by the exchange and must have permission to acceess short's underlying
  // The exchange contract will transfer the underlying after this function returns
  // Could alternatively implement so that this contract itself holds the authorization to use the tokens,
  // but would result in increased gas fees for makers and I'm not noticing any immediately-apparent security flaws with this approach.
  // This way also allows for coverage to be held on the exchange prior to contract creation, but doesn't HAVE to
  function mint(address long, address short, uint size) external restricted
  {
    uint threshold = (interest + size) * 10 ** underlying_decimals;
    require(underlying.balanceOf(address(this)) >= threshold);                  // Protocol will send tokens before calling this function
                                                                                // Alternatively, can eliminate this and have protocol send after calling

    // Calculate new open interest
    if (_balances[short] > 0 && _balances[long] < 0)
      interest -= size;
    else if (_balances[short] <= 0 && _balances[long] >= 0)
      interest += size;

    _coverage[short] += size;                                                   // Increment underlying coverage of the new short
    _balances[long] += size;
    _balances[short] -= size;

    // Add the new short address to the registry of net shorts if necessary
    if (_balances[short] < 0 && _shorts_index[short] == 0)
    {
      _shorts_index[short] = _shorts.length;
      _shorts.push(short);
    }

    // Remove new long from shorts registry if they have fully covered
    if (_balances[long] >= 0 && _shorts_index[long] > 0)
    {
      // Remove from end of short array if at end
      if (_shorts_index[long] == _shorts.length - 1)
      {
        _shorts.pop();
        _shorts_index[long] = 0;
      }
      else
      {
        address swap = _shorts[_shorts.length - 1];                             // Get address at end of short array
        _shorts[_shorts_index[long]] = swap;                                    // Put them where current short is
        _shorts_index[swap] = _shorts_index[long];                              // Update their new index
        _shorts_index[long] = 0;                                                // Reset the new long's short index
        _shorts.pop();                                                          // Remove duplicate of swap from end of short array
      }
    }
  }

  // Not sure how a short transfer could be implemented but will look into it
  function transfer(address to, uint amount) external
  {
    require(amount <= _balances[msg.sender]);
    _balances[to] += amount;
    _balances[msg.sender] -= amount;
  }

  // Exercise a certain number of calls
  // This may later be simplified to exxercise entire position
  function exercise(uint amount) external payable
  {
    require(block.timestamp < expiration);
    require(_balances[msg.sender] >= amount);
    require(msg.value >= price * amount);

    interest -= amount;

    while (amount > 0)
    {
      address short = _shorts[_shorts.length - 1];
      if (amount < -_balances[short])
      {
          _balances[msg.sender] -= amount;
          _coverage[short] -= amount;
          _balances[short] += amount;
          uint copy = amount;                                                   // Make a copy to avoid state changes after external call
          amount = 0;

          transfer(payable(short), msg.value * (100 - ASSIGNMENT_FEE) / 100);
          underlying.transfer(msg.sender, copy * 10 ** underlying_decimals);
      }
      else
      {
        uint filled = -_balances[short];
        _balances[msg.sender] -= filled;
        _balances[short] = 0;
        _coverage[short] = 0;

        _shorts_index[short] = 0;
        _shorts.pop();

        amount -= filled;

        transfer(payable(short), filled * price * (100 - ASSIGNMENT_FEE) / 100);
        underlying.transfer(msg.sender, filled * 10 ** underlying_decimals);
      }
    }

    transfer(payable(origin), address(this).balance);                           // Transfer fees to treasury
  }

  // Reclaim coverage from a short position
  function claim() external
  {
    uint coverage = _coverage[msg.sender];
    if (block.timestamp > expiration)
    {
      _coverage[msg.sender] = 0;
      underlying.transfer(msg.sender, coverage * 10 ** underlying_decimals);
    }
    else
    {
      require(coverage >= -_balances[msg.sender]);                              // Coverage must exceed short balance
      if (_balances[msg.sender] < 0)
      {
        uint net = coverage + _balances[msg.sender];
        _coverage[msg.sender] -= net;
        underlying.transfer(msg.sender, net * 10 ** underlying_decimals);
      }
      else
      {
        _coverage[msg.sender] = 0;
        underlying.transfer(msg.sender, coverage);
      }
    }
  }

}
