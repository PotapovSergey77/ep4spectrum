library verilog;
use verilog.vl_types.all;
entity T80_ALU is
    generic(
        Mode            : integer := 0;
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
        Arith16         : in     vl_logic;
        Z16             : in     vl_logic;
        ALU_Op          : in     vl_logic_vector(3 downto 0);
        IR              : in     vl_logic_vector(5 downto 0);
        ISet            : in     vl_logic_vector(1 downto 0);
        BusA            : in     vl_logic_vector(7 downto 0);
        BusB            : in     vl_logic_vector(7 downto 0);
        F_In            : in     vl_logic_vector(7 downto 0);
        Q               : out    vl_logic_vector(7 downto 0);
        F_Out           : out    vl_logic_vector(7 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of Mode : constant is 1;
    attribute mti_svvh_generic_type of Flag_C : constant is 1;
    attribute mti_svvh_generic_type of Flag_N : constant is 1;
    attribute mti_svvh_generic_type of Flag_P : constant is 1;
    attribute mti_svvh_generic_type of Flag_X : constant is 1;
    attribute mti_svvh_generic_type of Flag_H : constant is 1;
    attribute mti_svvh_generic_type of Flag_Y : constant is 1;
    attribute mti_svvh_generic_type of Flag_Z : constant is 1;
    attribute mti_svvh_generic_type of Flag_S : constant is 1;
end T80_ALU;
