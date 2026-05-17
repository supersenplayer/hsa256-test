--------------------------------------------------------------------------------
-- File         : sha256_pkg.vhd
-- Description  : Common package for the SHA-256 co-processor.
--                Holds the FIPS 180-4 constants (K, H_INIT), shared types,
--                and the bit-level helper functions Ch, Maj, BigSigma0/1,
--                SmallSigma0/1.
--
-- Reference    : NIST FIPS 180-4
--                  - Section 4.1.2  Logical functions (Ch, Maj, sigmas)
--                  - Section 4.2.2  K constants
--                  - Section 5.3.3  H(0) initial hash values
--
-- Notes        : All "+" used in SHA-256 are addition modulo 2^32.
--                Use unsigned() in the round/schedule logic; the assignment
--                back to a 32-bit std_logic_vector truncates the carry and
--                gives mod 2^32 for free.
--------------------------------------------------------------------------------

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

package sha256_pkg is

    ----------------------------------------------------------------------------
    -- Common types
    ----------------------------------------------------------------------------
    subtype word is std_logic_vector(31 downto 0);

    type word_8  is array (0 to 7)  of word;   -- H[0..7]
    type word_16 is array (0 to 15) of word;   -- M[0..15] / sliding window
    type word_64 is array (0 to 63) of word;   -- K[0..63]

    ----------------------------------------------------------------------------
    -- K constants  (FIPS 180-4, section 4.2.2)
    -- Fractional parts of cube roots of the first 64 primes.
    ----------------------------------------------------------------------------
    constant K : word_64 := (
        x"428a2f98", x"71374491", x"b5c0fbcf", x"e9b5dba5",
        x"3956c25b", x"59f111f1", x"923f82a4", x"ab1c5ed5",
        x"d807aa98", x"12835b01", x"243185be", x"550c7dc3",
        x"72be5d74", x"80deb1fe", x"9bdc06a7", x"c19bf174",
        x"e49b69c1", x"efbe4786", x"0fc19dc6", x"240ca1cc",
        x"2de92c6f", x"4a7484aa", x"5cb0a9dc", x"76f988da",
        x"983e5152", x"a831c66d", x"b00327c8", x"bf597fc7",
        x"c6e00bf3", x"d5a79147", x"06ca6351", x"14292967",
        x"27b70a85", x"2e1b2138", x"4d2c6dfc", x"53380d13",
        x"650a7354", x"766a0abb", x"81c2c92e", x"92722c85",
        x"a2bfe8a1", x"a81a664b", x"c24b8b70", x"c76c51a3",
        x"d192e819", x"d6990624", x"f40e3585", x"106aa070",
        x"19a4c116", x"1e376c08", x"2748774c", x"34b0bcb5",
        x"391c0cb3", x"4ed8aa4a", x"5b9cca4f", x"682e6ff3",
        x"748f82ee", x"78a5636f", x"84c87814", x"8cc70208",
        x"90befffa", x"a4506ceb", x"bef9a3f7", x"c67178f2"
    );

    ----------------------------------------------------------------------------
    -- H(0) initial hash values  (FIPS 180-4, section 5.3.3)
    -- Fractional parts of square roots of the first 8 primes.
    ----------------------------------------------------------------------------
    constant H_INIT : word_8 := (
        x"6a09e667",  -- H0
        x"bb67ae85",  -- H1
        x"3c6ef372",  -- H2
        x"a54ff53a",  -- H3
        x"510e527f",  -- H4
        x"9b05688c",  -- H5
        x"1f83d9ab",  -- H6
        x"5be0cd19"   -- H7
    );

    ----------------------------------------------------------------------------
    -- Helper functions  (FIPS 180-4, section 4.1.2)
    --
    --   Ch (x,y,z) = (x AND y) XOR ((NOT x) AND z)
    --   Maj(x,y,z) = (x AND y) XOR (x AND z) XOR (y AND z)
    --
    --   BigSigma0(x)   = ROTR(x, 2)  XOR ROTR(x,13) XOR ROTR(x,22)
    --   BigSigma1(x)   = ROTR(x, 6)  XOR ROTR(x,11) XOR ROTR(x,25)
    --   SmallSigma0(x) = ROTR(x, 7)  XOR ROTR(x,18) XOR  SHR(x, 3)
    --   SmallSigma1(x) = ROTR(x,17)  XOR ROTR(x,19) XOR  SHR(x,10)
    --
    -- ROTR = rotate right (no bits lost).  SHR = shift right with zero fill.
    ----------------------------------------------------------------------------
    function rotr (x : word; n : natural) return word;
    function shr  (x : word; n : natural) return word;

    function ch   (x, y, z : word) return word;
    function maj  (x, y, z : word) return word;

    function big_sigma0   (x : word) return word;
    function big_sigma1   (x : word) return word;
    function small_sigma0 (x : word) return word;
    function small_sigma1 (x : word) return word;

end package sha256_pkg;


package body sha256_pkg is

    ----------------------------------------------------------------------------
    -- Bit-level primitives (using numeric_std for portability)
    ----------------------------------------------------------------------------
    function rotr (x : word; n : natural) return word is
    begin
        return std_logic_vector(rotate_right(unsigned(x), n));
    end function;

    function shr (x : word; n : natural) return word is
    begin
        return std_logic_vector(shift_right(unsigned(x), n));
    end function;

    ----------------------------------------------------------------------------
    -- Logical functions
    ----------------------------------------------------------------------------
    function ch (x, y, z : word) return word is
    begin
        return (x and y) xor ((not x) and z);
    end function;

    function maj (x, y, z : word) return word is
    begin
        return (x and y) xor (x and z) xor (y and z);
    end function;

    ----------------------------------------------------------------------------
    -- Sigma functions
    ----------------------------------------------------------------------------
    function big_sigma0 (x : word) return word is
    begin
        return rotr(x, 2) xor rotr(x, 13) xor rotr(x, 22);
    end function;

    function big_sigma1 (x : word) return word is
    begin
        return rotr(x, 6) xor rotr(x, 11) xor rotr(x, 25);
    end function;

    function small_sigma0 (x : word) return word is
    begin
        return rotr(x, 7) xor rotr(x, 18) xor shr(x, 3);
    end function;

    function small_sigma1 (x : word) return word is
    begin
        return rotr(x, 17) xor rotr(x, 19) xor shr(x, 10);
    end function;

end package body sha256_pkg;
