--------------------------------------------------------------------------------
-- File         : sha256_ram.vhd
-- Description  : Simple synchronous RAM model for testbench.
--                Pre-loaded with SHA-256 test vectors.
--                Interface matches sha256_top's memory master:
--                  addr, read -> rdata, valid (1-cycle latency).
--
-- Memory layout (per BASE_ADDR convention):
--   Offset 0: LEN (message length in bytes, little-endian 32-bit)
--   Offset 4: M[0] (first 4 bytes of message, little-endian)
--   Offset 8: M[1]
--   ...
--
-- Test vectors (FIPS 180-4 examples):
--   Select via generic TEST_SEL:
--     0 = "abc"            (3 bytes)
--     1 = "abcdbcde..."    (56 bytes, the two-block vector)
--     2 = ""               (0 bytes, empty message)
--------------------------------------------------------------------------------

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity sha256_ram is
    generic (
        BASE_ADDR : unsigned(31 downto 0) := x"00001000";
        TEST_SEL  : integer := 0   -- 0=abc, 1=56-byte, 2=empty
    );
    port (
        clk       : in  std_logic;
        addr      : in  std_logic_vector(31 downto 0);
        rd        : in  std_logic;
        rdata     : out std_logic_vector(31 downto 0);
        valid     : out std_logic
    );
end entity sha256_ram;

architecture sim of sha256_ram is

    -- RAM: 64 words is enough for the longest test (56 bytes = 14 words + 1 LEN)
    type ram_t is array (0 to 63) of std_logic_vector(31 downto 0);

    -------------------------------------------------------------------------
    -- Helper: store a byte-string as little-endian 32-bit words in RAM
    -- (RISC-V is little-endian, so "abcd" stored as word = 0x64636261)
    -------------------------------------------------------------------------

    function init_ram return ram_t is
        variable r : ram_t := (others => (others => '0'));
    begin
        case TEST_SEL is

            -----------------------------------------------------------------
            -- TEST 0: "abc" (3 bytes)
            -- Expected digest:
            --   ba7816bf 8f01cfea 414140de 5dae2223
            --   b00361a3 96177a9d 51b2c326 1bfac6e7
            -----------------------------------------------------------------
            when 0 =>
                -- Offset 0: LEN = 3
                r(0) := x"00000003";
                -- Offset 4: "abc" + 0x00 padding byte (little-endian)
                -- 'a'=0x61, 'b'=0x62, 'c'=0x63
                -- Little-endian word: byte0=0x61, byte1=0x62, byte2=0x63, byte3=0x00
                -- As 32-bit LE: 0x00636261
                r(1) := x"00636261";

            -----------------------------------------------------------------
            -- TEST 1: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
            --          (56 bytes — forces 2 blocks after padding)
            -- Expected digest:
            --   248d6a61 d20638b8 e5c02693 0c3e6039
            --   a33ce459 64ff2167 f6ecedd4 19db06c1
            -----------------------------------------------------------------
            when 1 =>
                -- Offset 0: LEN = 56
                r(0) := x"00000038";  -- 56 decimal = 0x38
                -- 56 bytes = 14 words, little-endian
                -- "abcd" -> 0x64636261
                r(1)  := x"64636261";  -- "abcd"
                -- "bcde" -> 0x65646362
                r(2)  := x"65646362";  -- "bcde"
                -- "cdef" -> 0x66656463
                r(3)  := x"66656463";  -- "cdef"
                -- "defg" -> 0x67666564
                r(4)  := x"67666564";  -- "defg"
                -- "efgh" -> 0x68676665
                r(5)  := x"68676665";  -- "efgh"
                -- "fghi" -> 0x69686766
                r(6)  := x"69686766";  -- "fghi"
                -- "ghij" -> 0x6a696867
                r(7)  := x"6a696867";  -- "ghij"
                -- "hijk" -> 0x6b6a6968
                r(8)  := x"6b6a6968";  -- "hijk"
                -- "ijkl" -> 0x6c6b6a69
                r(9)  := x"6c6b6a69";  -- "ijkl"
                -- "jklm" -> 0x6d6c6b6a
                r(10) := x"6d6c6b6a";  -- "jklm"
                -- "klmn" -> 0x6e6d6c6b
                r(11) := x"6e6d6c6b";  -- "klmn"
                -- "lmno" -> 0x6f6e6d6c
                r(12) := x"6f6e6d6c";  -- "lmno"
                -- "mnop" -> 0x706f6e6d
                r(13) := x"706f6e6d";  -- "mnop"
                -- "nopq" -> 0x71706f6e
                r(14) := x"71706f6e";  -- "nopq"

            -----------------------------------------------------------------
            -- TEST 2: "" (empty message, 0 bytes)
            -- Expected digest:
            --   e3b0c442 98fc1c14 9afbf4c8 996fb924
            --   27ae41e4 649b934c a495991b 7852b855
            -----------------------------------------------------------------
            when 2 =>
                -- Offset 0: LEN = 0
                r(0) := x"00000000";

            when others =>
                r(0) := x"00000000";

        end case;
        return r;
    end function;

    signal ram : ram_t := init_ram;
    signal rd_pending : std_logic := '0';
    signal rd_data    : std_logic_vector(31 downto 0) := (others => '0');

begin

    -------------------------------------------------------------------------
    -- 1-cycle read latency (simulates real SRAM/BRAM behavior)
    -------------------------------------------------------------------------
    process (clk)
        variable word_idx : integer;
    begin
        if rising_edge(clk) then
            rd_pending <= '0';
            rd_data    <= (others => '0');

            if rd = '1' then
                -- Convert byte address to word index relative to BASE_ADDR
                word_idx := to_integer(unsigned(addr) - BASE_ADDR) / 4;
                if word_idx >= 0 and word_idx <= 63 then
                    rd_data <= ram(word_idx);
                end if;
                rd_pending <= '1';
            end if;
        end if;
    end process;

    rdata <= rd_data;
    valid <= rd_pending;

end architecture sim;
