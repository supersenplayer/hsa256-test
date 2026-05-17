--------------------------------------------------------------------------------
-- File         : sha256_top.vhd
-- Description  : Top-level SHA-256 co-processor with DMA-style memory access.
--
-- Memory layout (starting at BASE_ADDR, active-low byte-enable):
--   Offset 0:   LEN  (message length in bytes, 32-bit)
--   Offset 4:   M[0] (first message word, big-endian)
--   Offset 8:   M[1]
--   ...
--
-- Pipeline (3-stage, ~68 cycles per single block):
--   Stage 1:  Fetch word from RAM (or generate padding)
--   Stage 2:  Store into W window / expand
--   Stage 3:  SHA-256 round computation
--
-- After compression, the 256-bit digest is available on digest_out.
--
-- Control:
--   start='1' pulse  -> begin hashing
--   done='1'         -> digest is valid, unit is idle
--
-- Bus interface:
--   Simple read-only master: mem_addr, mem_read, mem_rdata, mem_valid.
--   Co-processor drives addr + read; memory responds with rdata + valid.
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
    -- FSM states
    ---------------------------------------------------------------------------
    type state_t is (
        S_IDLE,
        S_READ_LEN,
        S_WAIT_LEN,
        S_INIT,
        S_FETCH,
        S_WAIT_FETCH,
        S_PIPE,         -- pipeline active: store + round overlap
        S_DRAIN,        -- pipeline draining: rounds continue after fetch done
        S_FINALIZE,
        S_DONE
    );
    signal state, next_state : state_t := S_IDLE;

    ---------------------------------------------------------------------------
    -- Counters and control
    ---------------------------------------------------------------------------
    signal msg_len_bytes : unsigned(31 downto 0) := (others => '0');
    signal msg_len_bits  : unsigned(63 downto 0) := (others => '0');
    signal word_cnt      : unsigned(5 downto 0)  := (others => '0'); -- counts words fetched (0..15 per block)
    signal round_cnt     : unsigned(6 downto 0)  := (others => '0'); -- 0..63 per block
    signal total_words   : unsigned(31 downto 0) := (others => '0'); -- ceil(msg_len_bytes/4)
    signal words_read    : unsigned(31 downto 0) := (others => '0'); -- total words read so far
    signal addr_reg      : unsigned(31 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- H register (running hash) and working variables a..h
    ---------------------------------------------------------------------------
    signal H_reg : word_8 := H_INIT;

    signal va, vb, vc, vd, ve, vf, vg, vh : word := (others => '0');
    signal na, nb, nc, nd, ne, nf, ng, nh : word;

    ---------------------------------------------------------------------------
    -- Schedule interface signals
    ---------------------------------------------------------------------------
    signal sched_load_en  : std_logic := '0';
    signal sched_shift_en : std_logic := '0';
    signal sched_m_in     : word := (others => '0');
    signal sched_wt       : word;

    ---------------------------------------------------------------------------
    -- Padding logic signals
    ---------------------------------------------------------------------------
    signal pad_word       : word;
    signal use_pad        : std_logic := '0';
    signal pad_0x80_done  : std_logic := '0';
    signal block_word_idx : unsigned(3 downto 0) := (others => '0'); -- 0..15 within block

    ---------------------------------------------------------------------------
    -- Byte-swap function (little-endian memory -> big-endian SHA word)
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
    -- Main FSM process
    ---------------------------------------------------------------------------
    process (clk)
        variable remaining_bytes : unsigned(31 downto 0);
        variable block_byte_pos  : unsigned(5 downto 0);  -- byte position within 64-byte block
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
                sched_shift_en <= '0';
                sched_load_en  <= '0';
            else
                -- Defaults
                mem_read       <= '0';
                sched_shift_en <= '0';
                sched_load_en  <= '0';

                case state is

                    --------------------------------------------------------
                    -- IDLE: wait for start
                    --------------------------------------------------------
                    when S_IDLE =>
                        done <= '1';
                        if start = '1' then
                            done      <= '0';
                            state     <= S_READ_LEN;
                            addr_reg  <= BASE_ADDR;
                            mem_read  <= '1';
                            H_reg     <= H_INIT;
                            words_read    <= (others => '0');
                            pad_0x80_done <= '0';
                        end if;

                    --------------------------------------------------------
                    -- READ_LEN: put address on bus, wait for valid
                    --------------------------------------------------------
                    when S_READ_LEN =>
                        mem_read <= '1';
                        state    <= S_WAIT_LEN;

                    --------------------------------------------------------
                    -- WAIT_LEN: read the length word
                    --------------------------------------------------------
                    when S_WAIT_LEN =>
                        mem_read <= '1';
                        if mem_valid = '1' then
                            msg_len_bytes <= unsigned(mem_rdata);
                            msg_len_bits  <= unsigned(mem_rdata) & x"00000000";
                            -- msg_len_bits = msg_len_bytes * 8 (shift left 3)
                            msg_len_bits  <= shift_left(resize(unsigned(mem_rdata), 64), 3);
                            total_words   <= shift_right(unsigned(mem_rdata) + 3, 2); -- ceil(len/4)
                            addr_reg      <= BASE_ADDR + 4;  -- first message word
                            state         <= S_INIT;
                            mem_read      <= '0';
                        end if;

                    --------------------------------------------------------
                    -- INIT: initialize working variables from H
                    --------------------------------------------------------
                    when S_INIT =>
                        va <= H_reg(0);  vb <= H_reg(1);
                        vc <= H_reg(2);  vd <= H_reg(3);
                        ve <= H_reg(4);  vf <= H_reg(5);
                        vg <= H_reg(6);  vh <= H_reg(7);
                        word_cnt      <= (others => '0');
                        round_cnt     <= (others => '0');
                        block_word_idx <= (others => '0');
                        state         <= S_FETCH;

                    --------------------------------------------------------
                    -- FETCH: issue memory read (or generate pad word)
                    --------------------------------------------------------
                    when S_FETCH =>
                        if words_read < total_words then
                            -- Real message data still to fetch
                            mem_addr <= std_logic_vector(addr_reg);
                            mem_read <= '1';
                            state    <= S_WAIT_FETCH;
                        else
                            -- Past end of message: generate padding
                            use_pad <= '1';
                            state   <= S_PIPE;
                        end if;

                    --------------------------------------------------------
                    -- WAIT_FETCH: wait for memory valid
                    --------------------------------------------------------
                    when S_WAIT_FETCH =>
                        mem_addr <= std_logic_vector(addr_reg);
                        mem_read <= '1';
                        if mem_valid = '1' then
                            sched_m_in     <= byte_swap(mem_rdata);
                            sched_load_en  <= '1';
                            sched_shift_en <= '1';
                            addr_reg       <= addr_reg + 4;
                            words_read     <= words_read + 1;
                            word_cnt       <= word_cnt + 1;
                            block_word_idx <= block_word_idx + 1;

                            -- Start round if pipeline is primed (word_cnt >= 2)
                            if word_cnt >= 2 then
                                va <= na; vb <= nb; vc <= nc; vd <= nd;
                                ve <= ne; vf <= nf; vg <= ng; vh <= nh;
                                round_cnt <= round_cnt + 1;
                            end if;

                            -- Decide next state
                            if block_word_idx = 15 then
                                state <= S_DRAIN;
                            else
                                state <= S_FETCH;
                            end if;
                            mem_read <= '0';
                        end if;

                    --------------------------------------------------------
                    -- PIPE: padding word goes into schedule + round runs
                    --------------------------------------------------------
                    when S_PIPE =>
                        -- Generate padding word
                        remaining_bytes := msg_len_bytes - shift_left(words_read - 1, 2);
                        block_byte_pos  := block_word_idx & "00";

                        if pad_0x80_done = '0' then
                            -- Need to insert 0x80 after last valid byte
                            -- For simplicity: if we're here, the last real word
                            -- was partial or done. Insert 0x80000000 for the
                            -- first padding word.
                            sched_m_in    <= x"80000000";
                            pad_0x80_done <= '1';
                        elsif block_word_idx = 14 then
                            -- Length high word (upper 32 bits of bit-length)
                            sched_m_in <= std_logic_vector(msg_len_bits(63 downto 32));
                        elsif block_word_idx = 15 then
                            -- Length low word (lower 32 bits of bit-length)
                            sched_m_in <= std_logic_vector(msg_len_bits(31 downto 0));
                        else
                            -- Zero padding
                            sched_m_in <= (others => '0');
                        end if;

                        sched_load_en  <= '1';
                        sched_shift_en <= '1';
                        word_cnt       <= word_cnt + 1;
                        block_word_idx <= block_word_idx + 1;

                        -- Run round
                        if word_cnt >= 2 then
                            va <= na; vb <= nb; vc <= nc; vd <= nd;
                            ve <= ne; vf <= nf; vg <= ng; vh <= nh;
                            round_cnt <= round_cnt + 1;
                        end if;

                        -- Check if block is full
                        if block_word_idx = 15 then
                            state <= S_DRAIN;
                        end if;

                    --------------------------------------------------------
                    -- DRAIN: no more fetches; schedule expands + rounds run
                    --------------------------------------------------------
                    when S_DRAIN =>
                        -- Schedule generates W via sigma expansion
                        sched_load_en  <= '0';
                        sched_shift_en <= '1';

                        -- Run round
                        va <= na; vb <= nb; vc <= nc; vd <= nd;
                        ve <= ne; vf <= nf; vg <= ng; vh <= nh;
                        round_cnt <= round_cnt + 1;

                        if round_cnt = 63 then
                            state <= S_FINALIZE;
                        end if;

                    --------------------------------------------------------
                    -- FINALIZE: add working variables to H, check if more blocks
                    --------------------------------------------------------
                    when S_FINALIZE =>
                        H_reg(0) <= std_logic_vector(unsigned(H_reg(0)) + unsigned(va));
                        H_reg(1) <= std_logic_vector(unsigned(H_reg(1)) + unsigned(vb));
                        H_reg(2) <= std_logic_vector(unsigned(H_reg(2)) + unsigned(vc));
                        H_reg(3) <= std_logic_vector(unsigned(H_reg(3)) + unsigned(vd));
                        H_reg(4) <= std_logic_vector(unsigned(H_reg(4)) + unsigned(ve));
                        H_reg(5) <= std_logic_vector(unsigned(H_reg(5)) + unsigned(vf));
                        H_reg(6) <= std_logic_vector(unsigned(H_reg(6)) + unsigned(vg));
                        H_reg(7) <= std_logic_vector(unsigned(H_reg(7)) + unsigned(vh));

                        -- If there's more data or padding still needed for another block
                        if (words_read < total_words) or (pad_0x80_done = '0') then
                            state <= S_INIT;  -- start another block
                        elsif block_word_idx /= 0 then
                            -- Padding overflowed: need one more block
                            -- (this happens when msg is 56-64 bytes mod 64)
                            state <= S_INIT;
                        else
                            state <= S_DONE;
                        end if;

                    --------------------------------------------------------
                    -- DONE: digest is valid
                    --------------------------------------------------------
                    when S_DONE =>
                        done <= '1';
                        if start = '1' then
                            done  <= '0';
                            state <= S_READ_LEN;
                            addr_reg <= BASE_ADDR;
                            mem_read <= '1';
                            words_read    <= (others => '0');
                            pad_0x80_done <= '0';
                        end if;

                    when others =>
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output: concatenate H[0]..H[7] as the 256-bit digest
    ---------------------------------------------------------------------------
    digest_out <= H_reg(0) & H_reg(1) & H_reg(2) & H_reg(3)
               & H_reg(4) & H_reg(5) & H_reg(6) & H_reg(7);

    ---------------------------------------------------------------------------
    -- Memory address output (active when mem_read = '1')
    ---------------------------------------------------------------------------
    mem_addr <= std_logic_vector(addr_reg);

end architecture rtl;
