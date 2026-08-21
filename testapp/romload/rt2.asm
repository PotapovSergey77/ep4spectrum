; rt2 - does the dot command mechanism work at all?
;
; Prints one character and returns. No ESXDOS API call, no file, no
; port.
;
; Padded past 512 bytes deliberately. At 13 bytes this would not run at
; all - ESXDOS answered "Path too long" without executing a byte of it -
; while romload at 676 bytes ran fine. The suspicion is that a dot
; command shorter than one sector is not loaded properly. If this now
; prints an X with the code unchanged, that is the whole of it, and any
; future test command has to be padded the same way.

                org $2000

; No CALL $1601 here. A dot command runs at $2000 with the ESXDOS
; ROM below it, not the Spectrum's, so $1601 is not CHAN-OPEN - it
; is whatever ESXDOS keeps at that address, and calling it was the
; first instruction of every version of this that failed. RST $10
; is fine: ESXDOS puts trampolines at the restart addresses so
; BASIC keeps working. The stream is already channel 2 anyway,
; since the command was typed at the BASIC prompt.
                ld      a,'X'
                rst     $10
                ld      a,13
                rst     $10
                or      a               ; carry clear: no error reported
                ret

                defs    700, 0          ; past one 512-byte sector
