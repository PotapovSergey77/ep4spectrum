; rt3 - the smallest possible dot command: return, successfully.
;
; No call, no RST, no port, no ESXDOS hook. Nothing but a clear carry
; and a return. Padded past a sector because the short ones behaved no
; differently and the padding costs nothing.
;
; If .ls2 - a copy of a working command under a new name - runs and this
; does not, then the file is fine and it is the CONTENT of the others
; that ESXDOS objects to. If this runs, the mechanism is sound and the
; fault is in what my code does once it starts: a dot command executes
; at $2000 in DivMMC RAM with the ESXDOS ROM below it, not the
; Spectrum's, so CALL $1601 and RST $10 do not go where they look like
; they go.

                org $2000

                or      a               ; carry clear: report no error
                ret

                defs    700, 0
