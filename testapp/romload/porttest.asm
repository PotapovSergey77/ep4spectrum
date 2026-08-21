; porttest - does a write to the loader port land where it should?
;
; Four recognisable bytes into slot 0, then stop. The testbench reads
; the slot back out of the SDRAM model afterwards. This is the one link
; in the chain never checked: reading a slot was proven in simulation
; and the machine still would not boot from one.
                org $0000
                di
                ld      sp,$7ff0
                ld      a,$04           ; slot 0, counter to zero
                out     ($9b),a
                ld      a,$11
                out     ($9f),a
                ld      a,$22
                out     ($9f),a
                ld      a,$33
                out     ($9f),a
                ld      a,$44
                out     ($9f),a
spin:           jr      spin
