# gmake
#
# romload - the ESXDOS dot command that loads 128K / Pentagon / TR-DOS
# ROM images off the SD card into the FPGA's ROM slots.
#
# pasmo lives in tools/ so a checkout builds without hunting for it; the
# 0.5.3 Windows binary is the one this was written against.

PASMO = ../../tools/pasmo.exe
SDCARD = ../../sdcard

all: romload.bin

romload.bin: romload.asm
	$(PASMO) --alocal --bin romload.asm romload.bin

# Dot commands go in /bin on the card, with no extension - that is where
# ESXDOS looks when a name is typed after a dot.
install: romload.bin
	mkdir -p $(SDCARD)/bin
	cp romload.bin $(SDCARD)/bin/romload

clean:
	rm -f romload.bin

.PHONY: all install clean
