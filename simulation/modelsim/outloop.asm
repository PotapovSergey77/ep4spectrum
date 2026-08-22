; A tight run of border writes, for measuring what contention does to
; them. No interrupts, no synchronisation: the loop free-runs and the
; raster sweeps past it, so every part of the frame gets sampled.
                org $0000
                di
                ld sp,$8000
loop:           ld a,$02
                out ($fe),a
                ld a,$05
                out ($fe),a
                ld a,$02
                out ($fe),a
                ld a,$05
                out ($fe),a
                jr loop
