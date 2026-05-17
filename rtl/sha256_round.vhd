--------------------------------------------------------------------------------
-- File         : sha256_round.vhd
-- Description  : One round of the SHA-256 compression function.
--                Pure combinational. The clocked register that holds a..h
--                between rounds lives in the parent (top-level) entity.
--
-- Reference    : NIST FIPS 180-4, section 6.2.2 step 3.
--
--   T1 = h + Sigma1(e) + Ch(e,f,g) + K_t + W_t
--   T2 = Sigma0(a) + Maj(a,b,c)
--   h_new = g
--   g_new = f
--   f_new = e
--   e_new = d + T1
--   d_new = c
--   c_new = b
--   b_new = a
--   a_new = T1 + T2
--
--   All "+" are addition modulo 2^32 (free, since unsigned() + unsigned()
--   into a 32-bit std_logic_vector truncates the carry).
--------------------------------------------------------------------------------

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.sha256_pkg.all;

entity sha256_round is
    port (
        -- Current working variables (from a..h register, parent entity)
        a, b, c, d, e, f, g, h : in  word;

        -- Round inputs
        wt, kt                 : in  word;

        -- Next-cycle working variables (combinational outputs)
        n_a, n_b, n_c, n_d, n_e, n_f, n_g, n_h : out word
    );
end entity sha256_round;

architecture rtl of sha256_round is
    signal t1, t2 : word;
begin

    ----------------------------------------------------------------------------
    -- T1 / T2 (combinational, 5-input and 2-input adds respectively)
    ----------------------------------------------------------------------------
    t1 <= std_logic_vector( unsigned(h)
                          + unsigned(big_sigma1(e))
                          + unsigned(ch(e, f, g))
                          + unsigned(kt)
                          + unsigned(wt) );

    t2 <= std_logic_vector( unsigned(big_sigma0(a))
                          + unsigned(maj(a, b, c)) );

    ----------------------------------------------------------------------------
    -- Working-variable rotation
    ----------------------------------------------------------------------------
    n_h <= g;
    n_g <= f;
    n_f <= e;
    n_e <= std_logic_vector(unsigned(d) + unsigned(t1));
    n_d <= c;
    n_c <= b;
    n_b <= a;
    n_a <= std_logic_vector(unsigned(t1) + unsigned(t2));

end architecture rtl;
