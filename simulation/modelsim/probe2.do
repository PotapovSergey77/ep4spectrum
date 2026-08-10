run 1000us
echo "--- signals ---"
examine dut/cpu_wait_n dut/cpu_served dut/cpu_mem_active dut/cpu_needs_sdram
examine dut/ram_enable dut/rom_enable dut/divmmc_paged_in dut/esxdos_downloaded
examine dut/cur_own dut/prev_own dut/cpu_addr dut/cpu_addr_held
examine dut/cpu_mreq_n dut/cpu_rd_n dut/cpu_wr_n dut/cpu_a dut/reset_n
quit -f
