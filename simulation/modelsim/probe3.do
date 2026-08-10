run 1600us
echo "--- irq/video ---"
examine dut/vid_irq_n dut/vid/nIRQ dut/vid/vcounter dut/vid/hcounter dut/vid/read_step
examine dut/vid/pixels_next dut/vid/attr_next dut/vid_rd_n
quit -f
