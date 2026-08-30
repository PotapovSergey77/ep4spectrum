library verilog;
use verilog.vl_types.all;
entity T80_Reg is
    port(
        Clk             : in     vl_logic;
        CEN             : in     vl_logic;
        WEH             : in     vl_logic;
        WEL             : in     vl_logic;
        AddrA           : in     vl_logic_vector(2 downto 0);
        AddrB           : in     vl_logic_vector(2 downto 0);
        AddrC           : in     vl_logic_vector(2 downto 0);
        DIH             : in     vl_logic_vector(7 downto 0);
        DIL             : in     vl_logic_vector(7 downto 0);
        DOAH            : out    vl_logic_vector(7 downto 0);
        DOAL            : out    vl_logic_vector(7 downto 0);
        DOBH            : out    vl_logic_vector(7 downto 0);
        DOBL            : out    vl_logic_vector(7 downto 0);
        DOCH            : out    vl_logic_vector(7 downto 0);
        DOCL            : out    vl_logic_vector(7 downto 0)
    );
end T80_Reg;
