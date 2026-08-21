; romtest - isolate the ESXDOS F_OPEN call and report what it says
;
; Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
;
; romload kept coming back with "Path too long" and three plausible
; causes were fixed without moving it, which means the guessing had to
; stop. This does one thing: open 128.rom and print either the handle or
; the error code ESXDOS returned. The number says which of the remaining
; possibilities it is, instead of another round of changing something
; and asking whether it helped.
;
; Everything it needs lives above $4000 for the same reason romload does
; it: ESXDOS pages $0000-$3FFF away while it serves a call.

F_OPEN          equ $9a
FA_READ         equ $01
FNBUF           equ $5b00
CHAN_OPEN       equ $1601

                org $2000

start:          ld      a,2
                call    CHAN_OPEN

                ld      hl,msg_go
                call    print

                ld      hl,fname        ; name up into the printer buffer
                ld      de,FNBUF
cpn:            ld      a,(hl)
                ld      (de),a
                inc     hl
                inc     de
                or      a
                jr      nz,cpn

                ld      ix,FNBUF
                ld      a,'*'
                ld      b,FA_READ
                rst     $08
                defb    F_OPEN
                jr      c,failed

                push    af
                ld      hl,msg_ok
                call    print
                pop     af
                call    phex
                jr      done

failed:         push    af
                ld      hl,msg_err
                call    print
                pop     af
                call    phex

done:           ld      a,13
                call    pchar
                or      a               ; carry clear, no error to ESXDOS
                ret

; ---------------------------------------------------------------------
; A as two hex digits
phex:           push    af
                rra
                rra
                rra
                rra
                call    pnib
                pop     af
pnib:           and     $0f
                add     a,'0'
                cp      '9'+1
                jr      c,pchar
                add     a,7
pchar:          push    hl
                push    de
                push    bc
                push    af
                rst     $10
                pop     af
                pop     bc
                pop     de
                pop     hl
                ret

print:          ld      a,(hl)
                or      a
                ret     z
                inc     hl
                call    pchar
                jr      print

; ---------------------------------------------------------------------
fname:          defb    "128.rom",0
msg_go:         defb    "open 128.rom",13,0
msg_ok:         defb    "ok, handle=",0
msg_err:        defb    "error=",0
