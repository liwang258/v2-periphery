pragma solidity >=0.5.0;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';

import './SafeMath.sol';

library UniswapV2Library {
    using SafeMath for uint;

    /**
     *  这里对交易对按照地址进行归一化排序，确保在后续操作中，交易对的顺序是一致的
     * 即：任意给定两个代币地址tokenA和tokenB，都会返回一个固定顺序的(token0, token1)
     * 这样可以避免在后续的交易对计算中出现混淆
     * @param tokenA tokenA
     * @param tokenB tokenB
     * @return token0 token0 排序后的第一个代币地址
     * @return token1 token1 排序后的第二个代币地址
     */
    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    /**
     * 调用CREATE2合约创建地址的计算方法，计算出给定工厂地址(factory)和两个代币地址(tokenA, tokenB)对应的交易对合约地址
     * 这个地址是通过特定的哈希计算得出的，确保了在不同的环境下，只要输入相同，输出的地址也是相同的
     * 这样可以在不实际部署合约的情况下，预测交易对合约的
     * @param factory 工厂合约地址
     * @param tokenA tokenA
     * @param tokenB tokenB
     * @return pair 计算得到的交易对合约地址
     */
    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        // 步骤1：先对两种资产地址排序（确保顺序唯一，避免 [A,B] 和 [B,A] 算出差异地址）
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        // 步骤2：通过多层哈希+类型转换，计算交易对地址
        pair = address(
            uint(
                // 步骤2.4：将 256 位哈希值截断为 160 位（address 类型长度），转为地址
                keccak256( // 步骤2.3：对“固定前缀 + 工厂地址 + 排序后资产哈希 + 初始化代码哈希”做最终哈希
                    abi.encodePacked( // 步骤2.2：按固定顺序打包多个参数（字节级拼接，顺序不能乱）
                        hex'ff', // 固定前缀（避免与其他哈希冲突，Uniswap 自定义标识）
                        factory, // 工厂合约地址（不同工厂会生成不同交易对地址，隔离不同协议实例）
                        keccak256(abi.encodePacked(token0, token1)), // 排序后两种资产地址的哈希（压缩参数长度，确保唯一性）
                        hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash（UniswapV2Pair 合约的初始化代码哈希）
                    )
                )
            )
        );
    }

    // 获取tokenA和tokenB当前的储备量
    function getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint reserveA, uint reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1, ) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // 根据tokenA和tokenB的储备量和固定乘积公式，计算tokenA输入amountA数量时，tokenB需要多少量
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'UniswapV2Library: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    /**
     * 这个方法用于计算在Uniswap交易中，给定输入代币数量和储备量时，能够获得的最大输出代币数量
     * 这里会扣掉0.3%的交易手续费（即乘以997/1000）
     * @param amountIn 输入代币数量
     * @param reserveIn 输入代币的储备量
     * @param reserveOut 输出代币的储备量
     * @return amountOut 输出代币的最大数量
     */
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        //amountIn*997*reserveOut作为分子
        uint numerator = amountInWithFee.mul(reserveOut);
        //当前的储备量加上输入的代币数量（扣除手续费后的）作为分母
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        //为满足恒定乘积公式：amountOut=(amountIn*997*reserveOut)/(reserveIn*1000 + amountIn*997)
        amountOut = numerator / denominator;
    }
    // 给定要买的token数量，根据恒定乘积公式计算需要支付的token数量是多少
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    /**
     *
     * @param factory 接收token的合约地址(可能是包装了ETH的WETH合约地址)
     * @param amountIn 转入的代币数量
     * @param path  交换路径数组，包含多个代币地址，表示从输入代币到输出代币的交换路线
     * @return amounts 返回一个数组，表示在每一步交换中得到的代币数量
     */
    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(
        address factory,
        uint amountIn,
        address[] memory path
    ) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            //这里获取到的是每一对交易对的储备量
            //reserveIn是输入代币的储备量，reserveOut是输出代币的储备量
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);
            //得到这个交易对，扣除手续费后，能够输出的最大代币数量
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(
        address factory,
        uint amountOut,
        address[] memory path
    ) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
