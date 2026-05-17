--------------------------------------------------------------------------------
-- File         : sha256_schedule.vhd
-- Description  : Message schedule (W expansion) using a 16-word sliding window.
--                In LOAD mode, M words from memory feed the window.
--                In EXPAND mode, sigma functions compute new W values.
--                Output wt is the word consumed by the round each cycle.
--
-- Pipeline integration:
--   Stage 2 of the 3-stage pipeline.  Parent drives load_en to select
--   whether the incoming word is from memory (load_en='1') or from
--   the sigma expansion (load_en='0').
--
-- Reference    : NIST FIPS 180-4, section 6.2.2 step 1.
--   W[t] = M[t]                                         for 0 <= t <= 15
--   W[t] = sigma1(W[t-2]) + W[t-7] + sigma0(W[t-15]) + W[t-16]   for t >= 16
--------------------------------------------------------------------------------

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.sha256_pkg.all;

entity sha256_schedule is
    port (
        clk     : in  std_logic;
        rst     : in  std_logic;

        -- Control
        load_en : in  std_logic;   -- '1' = store m_in (from memory/padding)
                                   -- '0' = store computed expansion
        shift_en: in  std_logic;   -- '1' = shift window this cycle

        -- Data in (from memory read / padding mux)
        m_in    : in  word;

        -- Data out (to round logic)
        wt      : out word
    );
end entity sha256_schedule;

architecture rtl of sha256_schedule is
    signal w_window : word_16 := (others => (others => '0'));
    signal w_new    : word;
begin

    ---------------------------------------------------------------------------
    -- Combinational: compute the next expanded W value from the window
    -- w_new = sigma1(W[t-2]) + W[t-7] + sigma0(W[t-15]) + W[t-16]
    --
    -- Window indexing (slot 15 = newest, slot 0 = oldest):
    --   W[t-2]  -> slot 14
    --   W[t-7]  -> slot 9
    --   W[t-15] -> slot 1
    --   W[t-16] -> slot 0
    ---------------------------------------------------------------------------
    w_new <= std_logic_vector( unsigned(small_sigma1(w_window(14)))
                             + unsigned(w_window(9))
                             + unsigned(small_sigma0(w_window(1)))
                             + unsigned(w_window(0)) );

    ---------------------------------------------------------------------------
    -- Clocked: shift window and insert new word
    ---------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                w_window <= (others => (others => '0'));
            elsif shift_en = '1' then
                -- Shift left: oldest (slot 0) drops off
                w_window(0 to 14) <= w_window(1 to 15);

                -- Insert at slot 15: either from memory or from expansion
                if load_en = '1' then
                    w_window(15) <= m_in;
                else
                    w_window(15) <= w_new;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output: the round always consumes the oldest word in the window (slot 0)
    -- This is W[t] relative to the current round counter.
    ---------------------------------------------------------------------------
    wt <= w_window(0);

end architecture rtl;
