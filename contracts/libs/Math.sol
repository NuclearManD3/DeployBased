// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


library Math {

	// https://ethereum-magicians.org/t/eip-7054-gas-efficient-square-root-calculation-with-binary-search-approach/14539
	function sqrt(uint x) internal pure returns (uint128) {
		if (x == 0) return 0;
		else {
			uint xx = x;
			uint r = 1;
			if (xx >= 0x100000000000000000000000000000000) { xx >>= 128; r <<= 64; }
			if (xx >= 0x10000000000000000) { xx >>= 64; r <<= 32; }
			if (xx >= 0x100000000) { xx >>= 32; r <<= 16; }
			if (xx >= 0x10000) { xx >>= 16; r <<= 8; }
			if (xx >= 0x100) { xx >>= 8; r <<= 4; }
			if (xx >= 0x10) { xx >>= 4; r <<= 2; }
			if (xx >= 0x8) { r <<= 1; }

			unchecked {
				r = (r + x / r) >> 1;
				r = (r + x / r) >> 1;
				r = (r + x / r) >> 1;
				r = (r + x / r) >> 1;
				r = (r + x / r) >> 1;
				r = (r + x / r) >> 1;
				r = (r + x / r) >> 1;
			}
			uint r1 = x / r;
			return uint128 (r < r1 ? r : r1);
		}
	}

	// From https://arbiscan.io/contractdiffchecker?a2=0x819356bf26d384e7e70cd26c07fc807e6b354f08&a1=0x48e455852669adb747b3d16f2bd8b541d696b697
	function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
		unchecked {
			// 512-bit multiply [prod1 prod0] = a * b
			// Compute the product mod 2**256 and mod 2**256 - 1
			// then use the Chinese Remainder Theorem to reconstruct
			// the 512 bit result. The result is stored in two 256
			// variables such that product = prod1 * 2**256 + prod0
			uint256 prod0; // Least significant 256 bits of the product
			uint256 prod1; // Most significant 256 bits of the product
			assembly {
				let mm := mulmod(a, b, not(0))
				prod0 := mul(a, b)
				prod1 := sub(sub(mm, prod0), lt(mm, prod0))
			}

			// Make sure the result is less than 2**256.
			// Also prevents denominator == 0
			require(denominator > prod1);

			// Handle non-overflow cases, 256 by 256 division
			if (prod1 == 0) {
				assembly {
					result := div(prod0, denominator)
				}
				return result;
			}

			///////////////////////////////////////////////
			// 512 by 256 division.
			///////////////////////////////////////////////

			// Make division exact by subtracting the remainder from [prod1 prod0]
			// Compute remainder using mulmod
			uint256 remainder;
			assembly {
				remainder := mulmod(a, b, denominator)
			}
			// Subtract 256 bit number from 512 bit number
			assembly {
				prod1 := sub(prod1, gt(remainder, prod0))
				prod0 := sub(prod0, remainder)
			}

			// Factor powers of two out of denominator
			// Compute largest power of two divisor of denominator.
			// Always >= 1.
			uint256 twos = (0 - denominator) & denominator;
			// Divide denominator by power of two
			assembly {
				denominator := div(denominator, twos)
			}

			// Divide [prod1 prod0] by the factors of two
			assembly {
				prod0 := div(prod0, twos)
			}
			// Shift in bits from prod1 into prod0. For this we need
			// to flip `twos` such that it is 2**256 / twos.
			// If twos is zero, then it becomes one
			assembly {
				twos := add(div(sub(0, twos), twos), 1)
			}
			prod0 |= prod1 * twos;

			// Invert denominator mod 2**256
			// Now that denominator is an odd number, it has an inverse
			// modulo 2**256 such that denominator * inv = 1 mod 2**256.
			// Compute the inverse by starting with a seed that is correct
			// correct for four bits. That is, denominator * inv = 1 mod 2**4
			uint256 inv = (3 * denominator) ^ 2;
			// Now use Newton-Raphson iteration to improve the precision.
			// Thanks to Hensel's lifting lemma, this also works in modular
			// arithmetic, doubling the correct bits in each step.
			inv *= 2 - denominator * inv; // inverse mod 2**8
			inv *= 2 - denominator * inv; // inverse mod 2**16
			inv *= 2 - denominator * inv; // inverse mod 2**32
			inv *= 2 - denominator * inv; // inverse mod 2**64
			inv *= 2 - denominator * inv; // inverse mod 2**128
			inv *= 2 - denominator * inv; // inverse mod 2**256

			// Because the division is now exact we can divide by multiplying
			// with the modular inverse of denominator. This will give us the
			// correct result modulo 2**256. Since the precoditions guarantee
			// that the outcome is less than 2**256, this is the final result.
			// We don't need to compute the high bits of the result and prod1
			// is no longer required.
			result = prod0 * inv;
			return result;
		}
	}
}