; slotboot - load a slot through the port, mark it, and let the machine
; reset into it. The board path, end to end, with nothing forced.
;
; Simulation had the flags and the machine forced, which skipped exactly
; the part that the board does for itself. The board latches rom_from_sd
; correctly - the LED proves it - and still fetches neither half of the
; slot. So do it the board's way here and watch what comes out.
;
; The image written is six bytes: red border, then stop. If the machine
; comes up on the slot, the trace shows it fetching 3e 02 d3 fe.
                org $0000
                di
                ld      sp,$7ff0

                ld      a,$04           ; slot 0, counter to zero
                out     ($9b),a

                ld      hl,img
                ld      b,imglen
wr:             ld      a,(hl)
                out     ($9f),a
                inc     hl
                djnz    wr

                ld      a,$08           ; mark slot 0 filled
                out     ($9b),a

spin:           jr      spin

img:            defb    $3e,$02,$d3,$fe,$18,$fe
imglen          equ     6
