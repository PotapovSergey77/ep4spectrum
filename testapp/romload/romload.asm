; romload - load 128K / Pentagon / TR-DOS ROM images from the SD card
;
; Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
;
; An ESXDOS dot command, run from autoexec.bas at boot.
;
; ESXDOS already has the FAT drivers, so the filesystem stays in
; software and the FPGA only provides a way in:
;
;   port $9B write : [1:0] slot, [2] reset counter, [3] mark filled,
;                    [4] clear filled
;   port $9B read  : [3:0] the filled flags
;   port $9F write : one byte, the counter steps on its own
;
; The ROM area is never writable from the memory map - $0000-$3FFF has
; no write path and no enable bit - so a program cannot overwrite the
; ROM it is running from. The address a byte lands at comes from the
; slot counter inside the FPGA, not from the address bus, so this cannot
; be aimed anywhere else either.
;
; A machine reads its ROM out of SDRAM only once its slot is marked
; filled. Unmarked, it falls back to the 48K image in block RAM, which
; is the behaviour before any of this existed - so a card with no ROM
; files still boots and can print the message saying which are missing.
;
; On screen each file gets one line of its own: the name, a space, and
; then a bar of stars that reaches the right-hand edge exactly when the
; file is fully loaded. The screen is 32 columns, so the bar is as wide
; as whatever the name leaves - a long name simply gets a coarser bar,
; and the end of the line always means done. Nothing is printed before
; the first name and nothing after the last bar: at boot this scrolls
; past in a second and a title line would be half the output.

FA_READ         equ $01
F_OPEN          equ $9a
F_CLOSE         equ $9b
F_READ          equ $9d

PORT_CTL        equ $9b         ; slot select on write, flags on read
PORT_DAT        equ $9f         ; byte sink

CTL_RESET       equ $04         ; bit 2: zero the byte counter
CTL_FILL        equ $08         ; bit 3: mark this slot filled
CTL_DRV_B       equ $20         ; bits 6-5: which drive the disk slot
CTL_DRV_C       equ $40         ; writes to - A is 0
CTL_DRV_D       equ $60

SLOT_128        equ 0
SLOT_PENT       equ 1
SLOT_TRDOS      equ 2
SLOT_DISK       equ 3

SCRWIDTH        equ 32

; Each drive is a full 640K double-sided disk with a megabyte of
; address space to itself. Counted in 256-byte blocks.
DISK_MAXBLK     equ 2560


; Buffers live in the command's own space, which is what the 8K at
; $2000 is for. They were moved to the printer buffer at $5B00 for a
; while, on a guess about paging that turned out to be treating a
; fault that was really CALL $1601. That guess did real damage:
; ESXDOS keeps its own sector cache and filesystem bookkeeping around
; $5B00, so reading into it corrupted the state it needs. The symptom
; was progressive - the first file read in full, the second stopped
; halfway, the third would not open at all.
; A dot command runs with the ESXDOS page already in, and in that
; state the API takes its pointer in HL, not IX - z88dk loads both for
; exactly this reason. F_OPEN only ever worked here by accident, HL
; still holding the filename, while F_READ wrote the file wherever HL
; happened to point: the buffer stayed full of zeros and the byte count
; came back perfectly correct.
RDLEN           equ 256

                org $2000

; No CALL $1601 here. A dot command runs at $2000 with the ESXDOS
; ROM below it, not the Spectrum's, so $1601 is not CHAN-OPEN - it
; is whatever ESXDOS keeps at that address, and calling it was the
; first instruction of every version of this that failed. RST $10
; is fine: ESXDOS puts trampolines at the restart addresses so
; BASIC keeps working. The stream is already channel 2 anyway,
; since the command was typed at the BASIC prompt.
start:
                ; One 64K image with all four banks in it: the 128 menu,
                ; 48 BASIC, TR-DOS and Proteus. TR-DOS is no longer a
                ; file of its own - it is bank 1 of this one.
                ;
                ; Size in 256-byte BLOCKS, not bytes. 65536 does not fit
                ; in sixteen bits and arrives as zero, which made every
                ; block look like an overshoot: the loader gave up on the
                ; first one and the slot stayed empty, so neither the
                ; Pentagon menu nor anything else came up.
                ld      hl,fn_pent
                ld      de,256          ; 64K
                ld      a,SLOT_PENT
                call    one_rom

                ; A blank disk in all four drives.
                ;
                ; They have to come from here. TR-DOS formats with
                ; WRITE TRACK, which writes no data in this controller,
                ; so a drive that comes up holding SDRAM garbage can
                ; never be formatted from the machine - Proteus looks at
                ; it and says it is not a TR-DOS disk, which is true.
                ;
                ; Nine sectors is the whole of a blank one: eight of
                ; catalogue, all zero, and the disk info block at the end
                ; of the ninth. Everything past that is free space and
                ; nothing reads it until something is written there.
                xor     a               ; drive A
                call    blank_drv
                ld      a,CTL_DRV_B
                call    blank_drv
                ld      a,CTL_DRV_C
                call    blank_drv
                ld      a,CTL_DRV_D
                call    blank_drv

                ; Nothing loaded at all is the case worth spelling out.
                ; Three bare "not on card" lines say what happened but
                ; not what to do about it.
                ld      a,(loaded_any)
                or      a
                jr      nz,done

                ld      hl,msg_howto
                call    print

done:           or      a               ; carry clear: no error to ESXDOS
                ret

; ---------------------------------------------------------------------
; one_rom: HL = filename, DE = exact size in 256-byte blocks, A = slot
;
; The size is measured rather than trusted. The commonest mistake is a
; 16K image where 32K is wanted, and that must not read the same as a
; missing file - so the message says which of the two it was, and by how
; much when the length is wrong.
;
; Bytes are fed through as they are read, but the slot is only marked
; filled once the total comes out exactly right. A wrong file therefore
; leaves the machine on its old ROM rather than on half of a new one,
; and the feed stops at the slot's size so it cannot run on into the
; next slot's space.
; ---------------------------------------------------------------------
one_rom:        ld      (slot),a
                ld      (want),de
                call    hdr

                ; ESXDOS takes the filename in IX, and the string can stay
                ; where it is - a dot command's own memory is readable by
                ; the API perfectly well.
                push    hl
                pop     ix
                ld      a,'*'           ; default drive
                ld      b,FA_READ
                rst     $08
                defb    F_OPEN
                jp      c,no_file
                ld      (handle),a

                ld      a,(slot)
                or      CTL_RESET
                out     (PORT_CTL),a

                ld      hl,0
                ld      (count),hl
                ld      (acc),hl
                ld      (bar_done),hl   ; per file, not per run - three
                                        ; bars share these variables

                ; want is the block count already, which is exactly what
                ; the bar scales to.
                ld      hl,(want)
                ld      (blk_tot),hl

rd_chunk:       ld      a,(handle)
                ld      hl,buffer
                ld      ix,buffer
                ld      bc,RDLEN
                rst     $08
                defb    F_READ
                jp      c,rd_error
                ld      a,b
                or      c
                jp      z,rd_eof        ; nothing more in the file

                ; Never feed more than the slot holds. Past that the
                ; file is too long, and the extra would land in the next
                ; slot's space.
                ;
                ; Counted in BLOCKS, not bytes. A 64K image is 65536
                ; bytes and that does not fit in sixteen bits: carried as
                ; a byte count it arrives as zero, and every block then
                ; looks like an overshoot, so the loader gave up on the
                ; first one and the slot stayed empty. In blocks the
                ; largest number here is 256 and the arithmetic is
                ; ordinary.
                ld      hl,(count)
                inc     hl
                ld      (count),hl
                ld      de,(want)
                or      a
                sbc     hl,de
                jr      z,snd_block     ; this block exactly fills it
                jr      nc,too_long     ; past the end

snd_block:

                ; Re-select the slot before every block, WITHOUT the
                ; reset bit so the counter keeps its place.
                ;
                ; A single write and read-back straight after each other
                ; round-trips correctly even from a dot command, so the
                ; port itself is sound. What sits between the select and
                ; the writes in the loop, and nowhere else, is F_READ -
                ; ESXDOS talking to the card. If that disturbs the slot
                ; number then the bytes go somewhere else entirely, which
                ; matches what the board shows: probe fine, slots empty.
                ld      a,(slot)
                out     (PORT_CTL),a

                ld      hl,buffer
                ; OUT (n),A rather than OUT (C),A: the decode only looks
                ; at A7-A0, so the port fits in the opcode and BC stays
                ; free as the byte counter.
snd_byte:       ld      a,(hl)
                inc     hl
                out     (PORT_DAT),a
                dec     bc
                ld      a,b
                or      c
                jr      nz,snd_byte

                call    bar_step
                jr      rd_chunk

rd_eof:         ld      hl,(count)      ; total must match exactly
                ld      de,(want)
                or      a
                sbc     hl,de
                jr      nz,bad_size

                ld      a,(handle)
                rst     $08
                defb    F_CLOSE

                ld      a,(slot)
                or      CTL_FILL
                out     (PORT_CTL),a

                ld      a,1
                ld      (loaded_any),a

                ; The bar is exact when the file is exactly the size
                ; wanted, but pad anyway: the line ending flush right is
                ; the whole signal, and half a column short would read as
                ; a failure that did not happen. A full line wraps on its
                ; own, so no newline is printed here.
                jp      bar_fill

; Every failure gets a newline first: the bar stopped part-way, and a
; message tacked onto the end of it would be unreadable.
no_file:        call    nl
                ld      hl,msg_nofile
                jp      print

rd_error:       call    shut
                call    nl
                ld      hl,msg_rderr
                jp      print

too_long:       call    shut
                call    nl
                ld      hl,msg_long
                call    print
                ld      hl,(want)
                call    pnum
                ld      hl,msg_bytes
                jp      print

bad_size:       call    shut
                call    nl
                ld      hl,msg_short
                call    print
                ld      hl,(count)
                call    pnum
                ld      hl,msg_wanted
                call    print
                ld      hl,(want)
                call    pnum
                ld      hl,msg_bytes
                jp      print

shut:           ld      a,(handle)
                rst     $08
                defb    F_CLOSE
                ret

; ---------------------------------------------------------------------
; HL = filename. Prints it and a space, and sets the bar width to
; whatever is left of the 32-column line, so a long name simply gets a
; coarser bar instead of wrapping and scrolling. HL comes back unchanged.
; ---------------------------------------------------------------------
hdr:            push    hl
                call    print
                pop     hl
                call    namelen         ; A = length, HL kept
                push    hl
                ld      b,a
                ld      a,' '
                call    putc
                ld      a,SCRWIDTH-1
                sub     b
                ld      l,a
                ld      h,0
                ld      (bar_w),hl
                pop     hl
                ret

; ---------------------------------------------------------------------
; blank_drv: lay an empty TR-DOS filesystem on the drive in A.
;
; 2272 zero bytes, then the 32-byte info block that ends sector 9. The
; numbers in it say: first free sector 0 of track 1, disk type $16 (80
; tracks, double sided), no files, 2544 sectors free - a full 640K disk
; with track 0 spent on the catalogue - and $10, which is what marks it
; as TR-DOS at all.
; ---------------------------------------------------------------------
blank_drv:      ld      (bdrv),a
                or      SLOT_DISK|CTL_RESET
                out     (PORT_CTL),a
                ld      a,(bdrv)
                or      SLOT_DISK
                out     (PORT_CTL),a

                ; XOR A inside the loop, not before it: the loop test
                ; itself uses A to fold B and C together, so a zero
                ; loaded once would be gone by the second byte and the
                ; catalogue would fill with the loop counter.
                ld      bc,2272
bb_zero:        xor     a
                out     (PORT_DAT),a
                dec     bc
                ld      a,b
                or      c
                jr      nz,bb_zero

                ld      hl,tr_info
                ld      b,32
bb_info:        ld      a,(hl)
                inc     hl
                out     (PORT_DAT),a
                djnz    bb_info

                ld      a,(bdrv)
                or      SLOT_DISK|CTL_FILL
                out     (PORT_CTL),a

                ; The drive letter, from the same two bits that aimed
                ; the write: A is 0, so bits 6-5 shifted down are the
                ; distance from A.
                ld      a,(bdrv)
                rrca
                rrca
                rrca
                rrca
                rrca
                and     3
                add     a,'A'
                call    putc
                ld      hl,msg_blankb
                jp      print

bdrv:           defb    0

tr_info:        defb    $00,$00,$01,$16,$00,$f0,$09,$10
                defb    $00,$00,"         ",$00,$00
                defb    "          ",$00

; ---------------------------------------------------------------------
; The progress bar.
;
; Bresenham, so no multiply and no divide: each block adds the bar's
; width to a running total and every whole multiple of the block count
; that comes out is one star. Over the whole file that is exactly
; bar_w stars, with the rounding spread evenly instead of piling up at
; one end - and it works out the same whether the file is 32K or 16K.
; ---------------------------------------------------------------------
bar_step:       ld      hl,(acc)
                ld      de,(bar_w)
                add     hl,de
                ld      (acc),hl
bar_emit:       ld      hl,(acc)
                ld      de,(blk_tot)
                or      a
                sbc     hl,de
                ret     c
                ld      (acc),hl
                ld      a,'*'
                call    putc
                ld      hl,(bar_done)
                inc     hl
                ld      (bar_done),hl
                jr      bar_emit

; Top the bar up to its full width, whatever the arithmetic left.
bar_fill:       ld      hl,(bar_done)
                ld      de,(bar_w)
                or      a
                sbc     hl,de
                ret     nc
                ld      a,'*'
                call    putc
                ld      hl,(bar_done)
                inc     hl
                ld      (bar_done),hl
                jr      bar_fill

; ---------------------------------------------------------------------
; RST $10 does NOT preserve HL - the ROM's print routine uses it
; itself - so the pointer has to be carried across by hand. Without
; this the loop walks off into memory after the first character,
; printing rubbish until it happens on a zero, and by then the
; system variables below it are gone too.
print:          ld      a,(hl)
                or      a
                ret     z
                inc     hl
                call    putc
                jr      print

; One character in A, everything preserved.
putc:           push    hl
                push    de
                push    bc
                rst     $10
                pop     bc
                pop     de
                pop     hl
                ret

nl:             ld      a,13
                jp      putc

; HL -> zero-terminated string; returns A = its length, HL unchanged.
namelen:        push    hl
                ld      b,0
nl_scan:        ld      a,(hl)
                or      a
                jr      z,nl_end
                inc     b
                inc     hl
                jr      nl_scan
nl_end:         ld      a,b
                pop     hl
                ret

; HL printed as decimal, leading zeros suppressed
pnum:           xor     a
                ld      (lead),a
                ld      de,10000
                call    pdig
                ld      de,1000
                call    pdig
                ld      de,100
                call    pdig
                ld      de,10
                call    pdig
                ld      a,l
                add     a,'0'
                jp      putc

pdig:           ld      b,'0'
pd_sub:         or      a
                sbc     hl,de
                jr      c,pd_done
                inc     b
                jr      pd_sub
pd_done:        add     hl,de
                ld      a,b
                cp      '0'
                jr      nz,pd_show
                ld      a,(lead)        ; still in the leading zeros
                or      a
                ret     z
                ld      a,'0'
pd_show:        push    af
                ld      a,1
                ld      (lead),a
                pop     af
                jp      putc
lead:           defb    0

; ---------------------------------------------------------------------
fn_pent:        defb    "pentagon.rom",0

msg_nofile:     defb    "not on card",13,0
msg_blankb:     defb    " : blank 640K",13,0
msg_empty:      defb    "empty",13,0
msg_rderr:      defb    "read error",13,0
msg_short:      defb    "wrong size, got ",0
msg_wanted:     defb    ", wanted ",0
msg_long:       defb    "too long, wanted ",0
msg_bytes:      defb    " bytes",13,0
msg_howto:      defb    13
                defb    "No ROM images found. Put these in",13
                defb    "the root of the card:",13,13
                defb    "  pentagon.rom  65536 bytes",13,13
                defb    "Staying on the 48K ROM.",13,0

slot:           defb    0
handle:         defb    0
loaded_any:     defb    0
want:           defw    0
count:          defw    0
dblk:           defw    0
bar_w:          defw    0
blk_tot:        defw    0
bar_done:       defw    0
acc:            defw    0
buffer:         defs    RDLEN
