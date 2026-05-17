--------------------------------------------------------------------------------
-- File         : sha256_top.vhd
-- Description  : Top-level SHA-256 co-processor with DMA-style memory access.
--
-- Memory layout (starting at BASE_ADDR):
--   Offset 0:   LEN  (message length in bytes, 32-bit)
--   Offset 4:   M[0] (first message word, big-endian after byte-swap)
--   Offset 8:   M[1]
--   ...
--
-- Pipeline (3-stage, ~68 cycles per single block):
--   Stage 1:  Fetch word from RAM (or generate padding)
--   Stage 2:  Store into W window / expand
--   Stage 3:  SHA-256 round computation
--
-- Simplified FSM: IDLE -> INIT -> FETCH -> DRAIN -> FINALIZE
--------------------------------------------------------------------------------

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.sha256_pkg.all;

entity sha256_top is
    generic (
        BASE_ADDR : unsigned(31 downto 0) := x"00001000"
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        -- Control
        start      : in  std_logic;
        done       : out std_logic;

        -- Memory read interface
        mem_addr   : out std_logic_vector(31 downto 0);
        mem_read   : out std_logic;
        mem_rdata  : in  std_logic_vector(31 downto 0);
        mem_valid  : in  std_logic;

        -- Output digest (256 bits = 8 x 32)
        digest_out : out std_logic_vector(255 downto 0)
    );
end entity sha256_top;

architecture rtl of sha256_top is

    ---------------------------------------------------------------------------
    -- FSM states (5 total)
    ---------------------------------------------------------------------------
    type state_t is (
        S_IDLE,       -- waiting for start, done='1'
        S_INIT,       -- read LEN from memory + init a..h from H
        S_FETCH,      -- fetch/pad words into schedule + run rounds
        S_DRAIN,      -- schedule expands via sigma, rounds continue
        S_FINALIZE    -- H += a..h, assert done or loop for next block
    );
    signal state : state_t := S_IDLE;

    ---------------------------------------------------------------------------
    -- Counters and control
    ---------------------------------------------------------------------------
    signal msg_len_bytes : unsigned(31 downto 0) := (others => '0');
    signal msg_len_bits  : unsigned(63 downto 0) := (others => '0');
    signal total_words   : unsigned(31 downto 0) := (others => '0');
    signal words_read    : unsigned(31 downto 0) := (others => '0');
    signal addr_reg      : unsigned(31 downto 0) := (others => '0');
    signal word_cnt      : unsigned(5 downto 0)  := (others => '0');
    signal round_cnt     : unsigned(6 downto 0)  := (others => '0');
    signal block_word_idx: unsigned(3 downto 0)  := (others => '0');
    signal len_received  : std_logic := '0';
    signal init_done     : std_logic := '0';
    signal pad_0x80_done : std_logic := '0';
    signal need_extra_blk: std_logic := '0';

    ---------------------------------------------------------------------------
    -- H register (running hash) and working variables
    ---------------------------------------------------------------------------
    signal H_reg : word_8 := H_INIT;
    signal va, vb, vc, vd, ve, vf, vg, vh : word := (others => '0');
    signal na, nb, nc, nd, ne, nf, ng, nh : word;

    ---------------------------------------------------------------------------
    -- Schedule interface
    ---------------------------------------------------------------------------
    signal sched_load_en  : std_logic := '0';
    signal sched_shift_en : std_logic := '0';
    signal sched_m_in     : word := (others => '0');
    signal sched_wt       : word;

    ---------------------------------------------------------------------------
    -- Byte-swap (little-endian RISC-V -> big-endian SHA)
    ---------------------------------------------------------------------------
    function byte_swap(x : std_logic_vector(31 downto 0)) return word is
    begin
        return x(7 downto 0) & x(15 downto 8) & x(23 downto 16) & x(31 downto 24);
    end function;

begin

    ---------------------------------------------------------------------------
    -- Instantiate schedule (sliding window)
    ---------------------------------------------------------------------------
    u_schedule : entity work.sha256_schedule
        port map (
            clk      => clk,
            rst      => rst,
            load_en  => sched_load_en,
            shift_en => sched_shift_en,
            m_in     => sched_m_in,
            wt       => sched_wt
        );

    ---------------------------------------------------------------------------
    -- Instantiate round (combinational)
    ---------------------------------------------------------------------------
    u_round : entity work.sha256_round
        port map (
            a   => va,  b  => vb,  c  => vc,  d  => vd,
            e   => ve,  f  => vf,  g  => vg,  h  => vh,
            wt  => sched_wt,
            kt  => K(to_integer(round_cnt(5 downto 0))),
            n_a => na,  n_b => nb, n_c => nc, n_d => nd,
            n_e => ne,  n_f => nf, n_g => ng, n_h => nh
        );

    ---------------------------------------------------------------------------
    -- Main FSM
    ---------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state          <= S_IDLE;
                done           <= '1';
                mem_read       <= '0';
                H_reg          <= H_INIT;
                round_cnt      <= (others => '0');
                word_cnt       <= (others => '0');
                words_read     <= (others => '0');
                pad_0x80_done  <= '0';
                len_received   <= '0';
                init_done      <= '0';
                sched_shift_en <= '0';
                sched_load_en  <= '0';
            else
                -- Defaults each cycle
                mem_read       <= '0';
                sched_shift_en <= '0';
                sched_load_en  <= '0';

                case state is

                    ----------------------------------------------------
                    -- S_IDLE: wait for start pulse
                    ----------------------------------------------------
                    when S_IDLE =>
                        done <= '1';
                        if start = '1' then
                            done          <= '0';
                            state         <= S_INIT;
                            addr_reg      <= BASE_ADDR;
                            H_reg         <= H_INIT;
                            words_read    <= (others => '0');
                            pad_0x80_done <= '0';
                            len_received  <= '0';
                            init_done     <= '0';
                            need_extra_blk <= '0';
                            mem_read      <= '1';
                        end if;

                    ----------------------------------------------------
                    -- S_INIT: read LEN + initialize working variables
                    --   Stays here until LEN is received, then loads
                    --   a..h from H and transitions to S_FETCH.
                    ----------------------------------------------------
                    when S_INIT =>
                        if len_received = '0' then
                            -- Waiting for memory to return LEN
                            mem_read <= '1';
                            if mem_valid = '1' then
                                msg_len_bytes <= unsigned(mem_rdata);
                                msg_len_bits  <= shift_left(resize(unsigned(mem_rdata), 64), 3);
                                total_words   <= shift_right(unsigned(mem_rdata) + 3, 2);
                                addr_reg      <= BASE_ADDR + 4;
                                len_received  <= '1';
                            end if;
                        else
                            -- LEN known: init working variables
                            va <= H_reg(0);  vb <= H_reg(1);
                            vc <= H_reg(2);  vd <= H_reg(3);
                            ve <= H_reg(4);  vf <= H_reg(5);
                            vg <= H_reg(6);  vh <= H_reg(7);
                            word_cnt       <= (others => '0');
                            round_cnt      <= (others => '0');
                            block_word_idx <= (others => '0');
                            state          <= S_FETCH;
                            mem_read       <= '1';
                        end if;

                    ----------------------------------------------------
                    -- S_FETCH: fetch message words or generate padding.
                    --   Each time mem_valid='1' (or padding generated),
                    --   push word into schedule + run a round if primed.
                    --   After 16 words in this block -> S_DRAIN.
                    ----------------------------------------------------
                    when S_FETCH =>
                        if words_read < total_words then
                            -- Still real message data to fetch
                            mem_read <= '1';
                            if mem_valid = '1' then
                                sched_m_in     <= byte_swap(mem_rdata);
                                sched_load_en  <= '1';
                                sched_shift_en <= '1';
                                addr_reg       <= addr_reg + 4;
                                words_read     <= words_read + 1;
                                word_cnt       <= word_cnt + 1;
                                block_word_idx <= block_word_idx + 1;

                                -- Run round once pipeline is primed
                                if word_cnt >= 2 then
                                    va <= na; vb <= nb; vc <= nc; vd <= nd;
                                    ve <= ne; vf <= nf; vg <= ng; vh <= nh;
                                    round_cnt <= round_cnt + 1;
                                end if;

                                -- Block full? -> drain
                                if block_word_idx = 15 then
                                    state <= S_DRAIN;
                                end if;
                            end if;
                        else
                            -- Past message end: generate padding word
                            if pad_0x80_done = '0' then
                                sched_m_in    <= x"80000000";
                                pad_0x80_done <= '1';
                            elsif block_word_idx = 14 then
                                sched_m_in <= std_logic_vector(msg_len_bits(63 downto 32));
                            elsif block_word_idx = 15 then
                                sched_m_in <= std_logic_vector(msg_len_bits(31 downto 0));
                            else
                                sched_m_in <= (others => '0');
                            end if;

                            sched_load_en  <= '1';
                            sched_shift_en <= '1';
                            word_cnt       <= word_cnt + 1;
                            block_word_idx <= block_word_idx + 1;

                            -- Run round once pipeline is primed
                            if word_cnt >= 2 then
                                va <= na; vb <= nb; vc <= nc; vd <= nd;
                                ve <= ne; vf <= nf; vg <= ng; vh <= nh;
                                round_cnt <= round_cnt + 1;
                            end if;

                            -- Block full? -> drain
                            if block_word_idx = 15 then
                                state <= S_DRAIN;
                            end if;
                        end if;

                    ----------------------------------------------------
                    -- S_DRAIN: schedule self-expands, rounds continue.
                    --   No memory access. Runs until round 63.
                    ----------------------------------------------------
                    when S_DRAIN =>
                        sched_load_en  <= '0';
                        sched_shift_en <= '1';

                        va <= na; vb <= nb; vc <= nc; vd <= nd;
                        ve <= ne; vf <= nf; vg <= ng; vh <= nh;
                        round_cnt <= round_cnt + 1;

                        if round_cnt = 63 then
                            state <= S_FINALIZE;
                        end if;

                    ----------------------------------------------------
                    -- S_FINALIZE: H += a..h. Then done or next block.
                    ----------------------------------------------------
                    when S_FINALIZE =>
                        H_reg(0) <= std_logic_vector(unsigned(H_reg(0)) + unsigned(va));
                        H_reg(1) <= std_logic_vector(unsigned(H_reg(1)) + unsigned(vb));
                        H_reg(2) <= std_logic_vector(unsigned(H_reg(2)) + unsigned(vc));
                        H_reg(3) <= std_logic_vector(unsigned(H_reg(3)) + unsigned(vd));
                        H_reg(4) <= std_logic_vector(unsigned(H_reg(4)) + unsigned(ve));
                        H_reg(5) <= std_logic_vector(unsigned(H_reg(5)) + unsigned(vf));
                        H_reg(6) <= std_logic_vector(unsigned(H_reg(6)) + unsigned(vg));
                        H_reg(7) <= std_logic_vector(unsigned(H_reg(7)) + unsigned(vh));

                        -- Check if more blocks needed
                        if (words_read < total_words) then
                            -- More message data to process
                            len_received <= '1';  -- skip re-reading LEN
                            state <= S_INIT;
                        elsif (pad_0x80_done = '0') or (need_extra_blk = '1') then
                            -- Need another block for padding overflow
                            need_extra_blk <= '0';
                            len_received <= '1';
                            state <= S_INIT;
                        else
                            -- All done
                            done  <= '1';
                            state <= S_IDLE;
                        end if;

                    when others =>
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output digest
    ---------------------------------------------------------------------------
    digest_out <= H_reg(0) & H_reg(1) & H_reg(2) & H_reg(3)
               & H_reg(4) & H_reg(5) & H_reg(6) & H_reg(7);

    ---------------------------------------------------------------------------
    -- Memory address (active when mem_read = '1')
    ---------------------------------------------------------------------------
    mem_addr <= std_logic_vector(addr_reg);

end architecture rtl;
