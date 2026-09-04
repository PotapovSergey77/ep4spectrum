; DivMMC bank viewer.
;
; Sets CONMEM (bit 7 of port $E3) with a bank number, which forces the
; DivMMC memory into $2000-$3FFF, copies a window out to a buffer, drops
; CONMEM again and prints the window as hex through the ROM.
;
; Keys: 0-7 bank, Q/A window +-128, W/S window +-2048.

CLALL   equ $0DAF
OPENCH  equ $1601
LASTK   equ $5C08

        org 49152

start:  ld a,3
        ld (bank),a
        ld hl,$3000
        ld (win),hl
main:   call grab
        call show
        call getkey
        jr main

; Copy 128 bytes of the selected bank into buf.
grab:   di
        ld a,(bank)
        or $80
        out ($e3),a
        ld hl,(win)
        ld de,buf
        ld bc,128
        ldir
        xor a
        out ($e3),a
        ei
        ret

show:   ld a,2
        call OPENCH
        call CLALL
        ld hl,msg
        call prstr
        ld a,(bank)
        add a,'0'
        rst 16
        ld a,' '
        rst 16
        ld hl,(win)
        call phex16
        ld a,13
        rst 16
        ld hl,(win)
        ld (lad),hl
        ld ix,buf
        ld b,16
lrow:   push bc
        ld hl,(lad)
        call phex16
        ld a,' '
        rst 16
        ld b,8
lcol:   ld a,(ix+0)
        inc ix
        call phex8
        ld a,' '
        rst 16
        djnz lcol
        ld a,13
        rst 16
        ld hl,(lad)
        ld de,8
        add hl,de
        ld (lad),hl
        pop bc
        djnz lrow
        ret

phex16: push af
        ld a,h
        call phex8
        ld a,l
        call phex8
        pop af
        ret

phex8:  push af
        rrca
        rrca
        rrca
        rrca
        call pnib
        pop af
pnib:   and 15
        add a,'0'
        cp '9'+1
        jr c,pn1
        add a,7
pn1:    rst 16
        ret

prstr:  ld a,(hl)
        and a
        ret z
        rst 16
        inc hl
        jr prstr

getkey: ld hl,LASTK
        ld (hl),0
gk0:    ld a,(hl)
        and a
        jr z,gk0
        cp '0'
        jr c,gk1
        cp '8'
        jr nc,gk1
        sub '0'
        ld (bank),a
        ret
gk1:    cp 'q'
        jr nz,gk2
        ld de,-128
        jr gkmv
gk2:    cp 'a'
        jr nz,gk3
        ld de,128
        jr gkmv
gk3:    cp 'w'
        jr nz,gk4
        ld de,-2048
        jr gkmv
gk4:    cp 's'
        jr nz,gk5
        ld de,2048
        jr gkmv
gk5:    ret
gkmv:   ld hl,(win)
        add hl,de
        ld a,h
        and $3f
        or $20
        ld h,a
        ld (win),hl
        ret

msg:    defb 'BANK ',0
bank:   defb 3
win:    defw $3000
lad:    defw 0
buf:    defs 128
