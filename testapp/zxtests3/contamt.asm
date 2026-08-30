; WITHDRAWN - do not build this into testapp/tests.
;
; It runs on a 128K and resets a 48K. The timed block below is
; ulatest3's, taken verbatim without working through its arithmetic:
; the final delay is FRAMET - TVAR + 32656 with sixteen-bit wrap, which
; happens to land well for a 70908-T frame and does not for 69888. The
; source is kept because the lesson is worth keeping - an instrument
; whose timing its author cannot account for is worth less than no
; instrument - but it is not a working test.
;
; contamt - HOW MUCH each contended access is delayed, T-state by
; T-state, printed as a map.
;
; The measuring core - ALIGNINT, DELAY, INSTINT, FRAME_TIME and the
; timed block below - is Jan Bobrowski's, taken from ulatest3.asm in
; this directory, licence GPL. Only the sweep and the printing are new.
;
; ulatest3 answers whether an access at T was contended. It cannot say
; by how many T-states, and that is the one thing about our contention
; never checked against real hardware: the window's shape and position
; agree with a real 48K cell for cell, but the amount charged has only
; ever been assumed.
;
; The core ends by delaying out the rest of the frame and seeing whether
; a HALT still catches this frame's interrupt. Anything the access cost
; pushes it past, and C comes back 1. So sweep a compensation: take one
; T-state at a time out of that final delay, and the value at which the
; answer flips from late to on-time IS the number of T-states the access
; was charged.
;
; The compensation must not disturb the core's own accounting, which is
; counted to the T-state. It goes in by patching the OPERAND of the
; LD BC,nn that sets the final delay - ten T-states whatever the value -
; so nothing in the timed path changes length.
;
; A 48K should read 6,5,4,3,2,1,0,0 repeating across the display, and
; nothing outside it.

TSTART	equ 14320	; a little before the display starts
TCOUNT	equ 224		; one line, seven rows of thirty-two
DMAX	equ 8		; delays run 0..6; 8 is "more than expected"

	org 32768

START:
	call INSTINT
	call FRAME_TIME
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
	ld (TVAR), hl
	ld b, TCOUNT/32
_row:
	push bc
	ld b, 32
_col:
	push bc

	; Walk the compensation up from zero and stop at the first value
	; that comes back on time. That value is the charge.
	xor a
	ld (DVAR), a
_try:
	call SETCOMP
	call CONTA
	ld a, c
	and a
	jr z, _got		; on time - this compensation is the answer
	ld a,(DVAR)
	inc a
	ld (DVAR), a
	cp DMAX
	jr c, _try
_got:
	ld a,(DVAR)
	cp 10
	jr c, _dig
	add a, 'A'-10
	jr _emit
_dig:
	add a, '0'
_emit:
	rst 16

	ld hl,(TVAR)
	inc hl
	ld (TVAR), hl
	pop bc
	djnz _col
	ld a, 13
	rst 16
	pop bc
	djnz _row

	ld hl, msg_done
	call PRINT
	ret

; Put 32656 minus the compensation into the core's final delay.
SETCOMP:
	ld hl, 32656
	ld a,(DVAR)
	ld e, a
	ld d, 0
	and a
	sbc hl, de
	ld (COMPOP), hl
	ret

msg_ft	 db "frame ", 0
msg_from db "from T ", 0
msg_done db 13, "done", 13, 0

TVAR	dw 0
DVAR	db 0

; ---------------------------------------------------------------------
; From here down: ulatest3.asm by Jan Bobrowski, with GETVAR replaced by
; the value this file sets and the final delay's operand made patchable.
; Nothing in the timed path changes length.
; ---------------------------------------------------------------------

CONTA:
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

	ld a, 0FFh	; TVAR-10T
	in a, (0FEh)	; TVAR+1T+ (in at 7)

	ld bc,(TVAR)	; TVAR+21
	ld hl,(FRAMET)	; TVAR+37
	and a		; TVAR+41
	sbc hl,bc	; TVAR+56
COMPOP equ $+1
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
