--------------------------------------------------------------------------------
-- File         : sha256_tb.vhd
-- Description  : Testbench for sha256_top.
--                Instantiates sha256_top + sha256_ram, runs the hash,
--                and checks the digest against the known FIPS answer.
--
-- Usage        : Change TEST_SEL generic to select test vector (0, 1, or 2).
--                Simulate for ~500 ns at 100 MHz clock (enough for any single
--                or two-block message).
--
-- Expected results:
--   TEST_SEL=0 ("abc"):
--     ba7816bf8f01cfea414140de5dae2223b00361a396177a9d51b2c3261bfac6e7
--   TEST_SEL=1 (56-byte):
--     248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
--   TEST_SEL=2 (empty):
--     e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
--------------------------------------------------------------------------------

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.sha256_pkg.all;

entity sha256_tb is
end entity sha256_tb;

architecture sim of sha256_tb is

    constant CLK_PERIOD : time := 10 ns;  -- 100 MHz
    constant BASE_ADDR  : unsigned(31 downto 0) := x"00001000";
    constant TEST_SEL   : integer := 0;   -- change to 0, 1, or 2

    -- Expected digests
    type digest_array_t is array (0 to 2) of std_logic_vector(255 downto 0);
    constant EXPECTED : digest_array_t := (
        -- TEST 0: "abc"
        x"ba7816bf8f01cfea414140de5dae2223b00361a396177a9d51b2c3261bfac6e7",
        -- TEST 1: 56-byte
        x"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        -- TEST 2: empty
        x"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );

    -- Signals
    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal start      : std_logic := '0';
    signal done       : std_logic;
    signal mem_addr   : std_logic_vector(31 downto 0);
    signal mem_read   : std_logic;
    signal mem_rdata  : std_logic_vector(31 downto 0);
    signal mem_valid  : std_logic;
    signal digest_out : std_logic_vector(255 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Clock generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2;

    ---------------------------------------------------------------------------
    -- DUT: SHA-256 co-processor
    ---------------------------------------------------------------------------
    u_dut : entity work.sha256_top
        generic map (
            BASE_ADDR => BASE_ADDR
        )
        port map (
            clk        => clk,
            rst        => rst,
            start      => start,
            done       => done,
            mem_addr   => mem_addr,
            mem_read   => mem_read,
            mem_rdata  => mem_rdata,
            mem_valid  => mem_valid,
            digest_out => digest_out
        );

    ---------------------------------------------------------------------------
    -- RAM model (pre-loaded with test vector)
    ---------------------------------------------------------------------------
    u_ram : entity work.sha256_ram
        generic map (
            BASE_ADDR => BASE_ADDR,
            TEST_SEL  => TEST_SEL
        )
        port map (
            clk   => clk,
            addr  => mem_addr,
            rd    => mem_read,
            rdata => mem_rdata,
            valid => mem_valid
        );

    ---------------------------------------------------------------------------
    -- Stimulus process
    ---------------------------------------------------------------------------
    process
    begin
        -- Hold reset for a few cycles
        rst <= '1';
        wait for CLK_PERIOD * 5;
        rst <= '0';
        wait for CLK_PERIOD * 2;

        -- Pulse start
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';

        -- Wait for done
        wait until done = '1';
        wait for CLK_PERIOD;  -- let signals settle

        -- Check result
        if digest_out = EXPECTED(TEST_SEL) then
            report "TEST " & integer'image(TEST_SEL) & " PASSED!" severity note;
        else
            report "TEST " & integer'image(TEST_SEL) & " FAILED!" severity error;
            report "  Expected: " & to_hstring(unsigned(EXPECTED(TEST_SEL))) severity error;
            report "  Got:      " & to_hstring(unsigned(digest_out)) severity error;
        end if;

        -- End simulation
        wait for CLK_PERIOD * 10;
        report "Simulation complete." severity note;
        wait;
    end process;

end architecture sim;
