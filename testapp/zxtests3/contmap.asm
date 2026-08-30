; contmap - print the contention window as a map, one character per
; T-state, so the same program can be run on FUSE and on the board and
; the two strings compared character by character.
;
; The measuring core - CONTP, and the helpers it calls - is Jan
; Bobrowski's, copied from ulatest3.asm in this same directory and left
; word for word, licence GPL. Only the driver is new: ulatest3 is driven
; from BASIC through GETVAR, and building that needs mktap, which we do
; not have. So GETVAR is replaced by one that returns a value this file
; sets, and the sweep and printing are done here.
;
; CONTP(T) answers whether an IO access at T-state T of the frame is
; contended - 1 if it was held, 0 if it ran free. Sweeping T across a
; line draws the window.
;
; Each call spends a whole frame, so 256 of them take about five
; seconds.

TSTART	equ 14320	; a little before the display starts on either
			; machine: 14336 on a 48K, 14362 on a 128K
TCOUNT	equ 256		; eight rows of thirty-two

	org 32768

START:
	call INSTINT
	call FRAME_TIME

	; Back to IM1 before printing a single character. INSTINT leaves the
	; machine in IM2 with a handler that does inc sp, inc sp, ei, ret -
	; it exists to return past a pushed continuation, and it eats two
	; bytes of stack every time it fires. Printing under it would unwind
	; the stack fifty times a second. ALIGNINT sets IM2 itself when it
	; needs it, and CONTP puts IM1 back on the way out.
	im 1
	ei

	ld hl, msg_ft
	call PRINT
	ld hl,(FRAMET)
	call PRDEC
	ld a, 13
	rst 16

	ld hl, msg_from
	call PRINT
	ld hl, TSTART
	call PRDEC
	ld a, 13
	rst 16
	ld a, 13
	rst 16

	ld hl, TSTART
	ld (MYVAR), hl
	ld b, TCOUNT/32
_row:
	push bc
	ld b, 32
_col:
	push bc
	call CONTP		; c = 1 contended, 0 free
	ld a, '.'
	bit 0, c
	jr z, _emit
	ld a, '#'
_emit:
	rst 16
	ld hl,(MYVAR)
	inc hl
	ld (MYVAR), hl
	pop bc
	djnz _col
	ld a, 13
	rst 16
	pop bc
	djnz _row

	ld hl, msg_done
	call PRINT
	ret

msg_ft	 db "frame ", 0
msg_from db "from T ", 0
msg_done db 13, "done", 13, 0

MYVAR	dw 0

; The BASIC-facing GETVAR of ulatest3 evaluates a variable by name
; through the ROM. This one ignores the name - it still has to step over
; the inline text so the caller returns to the right place - and hands
; back whatever the sweep above has put in MYVAR.
GETVAR:
	pop hl
_gskip	ld a,(hl)
	inc hl
	cp 13
	jr nz, _gskip
	push hl
	ld bc,(MYVAR)
	ret

; ---------------------------------------------------------------------
; From here down: ulatest3.asm by Jan Bobrowski, unchanged.
; ---------------------------------------------------------------------

TVAR dw 0

CONTP:	; contention test
	call GETVAR
	db "T",13
	ld (TVAR), bc
	ld bc, _test
	call _pjump
	im 1
	ld b,0
	ret

_pjump	push bc
	jp ALIGNINT

_test:			; 46T
	ld bc, (TVAR)	; 66T
	ld hl, -112	; 76T
	add hl, bc	; 87T
	ld b,h
	ld c,l		; 95T
	call DELAY	; TVAR-17T

cPORTh equ $+1
	ld a, 0FFh	; TVAR-10T
cPORTl equ $+1
	in a, (0FEh)	; TVAR+1T+ (in at 7)

	ld bc,(TVAR)	; TVAR+21
	ld hl,(FRAMET)	; TVAR+37
	and a		; TVAR+41
	sbc hl,bc	; TVAR+56
	ld bc,32656	; TVAR+66
	add hl,bc	; TVAR+77
	ld b,h
	ld c,l		; TVAR+85

	call DELAY	; 69861T+
	ld c, 1		; 69868T+
	nop
	nop
	nop
	nop
	nop		; 69888T+
	dec c
	halt

	; The trap that used to be RST 0 - which on a Spectrum is a reset,
	; and on the 48K this test rebooted the machine instead of saying
	; anything. Parking here keeps whatever was printed on the screen,
	; so how far it got is visible.
_trap	jr _trap

	include delay.asm
	include instint.asm
	include frametime.asm
	include alignint.asm
	include print.asm

	end START
