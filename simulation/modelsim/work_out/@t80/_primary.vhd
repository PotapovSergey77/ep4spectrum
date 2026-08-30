library verilog;
use verilog.vl_types.all;
entity T80 is
    generic(
        Mode            : integer := 0;
        IOWait          : integer := 0;
        Flag_C          : integer := 0;
        Flag_N          : integer := 1;
        Flag_P          : integer := 2;
        Flag_X          : integer := 3;
        Flag_H          : integer := 4;
        Flag_Y          : integer := 5;
        Flag_Z          : integer := 6;
        Flag_S          : integer := 7
    );
    port(
        RESET_n         : in     vl_logic;
        CLK_n           : in     vl_logic;
        CEN             : in     vl_logic;
        WAIT_n          : in     vl_logic;
        INT_n           : in     vl_logic;
        NMI_n           : in     vl_logic;
        BUSRQ_n         : in     vl_logic;
        M1_n            : out    vl_logic;
        IORQ            : out    vl_logic;
        NoRead          : out    vl_logic;
        Write           : out    vl_logic;
        RFSH_n          : out    vl_logic;
        HALT_n          : out    vl_logic;
        BUSAK_n         : out    vl_logic;
        A               : out    vl_logic_vector(15 downto 0);
        DInst           : in     vl_logic_vector(7 downto 0);
        DI              : in     vl_logic_vector(7 downto 0);
        DO              : out    vl_logic_vector(7 downto 0);
        MC              : out    vl_logic_vector(2 downto 0);
        TS              : out    vl_logic_vector(2 downto 0);
        IntCycle_n      : out    vl_logic;
        IntE            : out    vl_logic;
        Stop            : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of Mode : constant is 1;
    attribute mti_svvh_generic_type of IOWait : constant is 1;
    attribute mti_svvh_generic_type of Flag_C : constant is 1;
    attribute mti_svvh_generic_type of Flag_N : constant is 1;
    attribute mti_svvh_generic_type of Flag_P : constant is 1;
    attribute mti_svvh_generic_type of Flag_X : constant is 1;
    attribute mti_svvh_generic_type of Flag_H : constant is 1;
    attribute mti_svvh_generic_type of Flag_Y : constant is 1;
    attribute mti_svvh_generic_type of Flag_Z : constant is 1;
    attribute mti_svvh_generic_type of Flag_S : constant is 1;
end T80;
