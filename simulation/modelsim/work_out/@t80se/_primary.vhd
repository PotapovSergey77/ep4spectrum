library verilog;
use verilog.vl_types.all;
entity T80se is
    generic(
        Mode            : integer := 0;
        T2Write         : integer := 0;
        IOWait          : integer := 1
    );
    port(
        RESET_n         : in     vl_logic;
        CLK_n           : in     vl_logic;
        CLKEN           : in     vl_logic;
        WAIT_n          : in     vl_logic;
        INT_n           : in     vl_logic;
        NMI_n           : in     vl_logic;
        BUSRQ_n         : in     vl_logic;
        M1_n            : out    vl_logic;
        MREQ_n          : out    vl_logic;
        IORQ_n          : out    vl_logic;
        RD_n            : out    vl_logic;
        WR_n            : out    vl_logic;
        RFSH_n          : out    vl_logic;
        HALT_n          : out    vl_logic;
        BUSAK_n         : out    vl_logic;
        A               : out    vl_logic_vector(15 downto 0);
        DI              : in     vl_logic_vector(7 downto 0);
        DO              : out    vl_logic_vector(7 downto 0);
        MC              : out    vl_logic_vector(2 downto 0);
        TS              : out    vl_logic_vector(2 downto 0);
        IO_CYC          : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of Mode : constant is 1;
    attribute mti_svvh_generic_type of T2Write : constant is 1;
    attribute mti_svvh_generic_type of IOWait : constant is 1;
end T80se;
