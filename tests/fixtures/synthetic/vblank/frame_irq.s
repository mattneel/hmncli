.syntax unified
.cpu arm7tdmi
.arm

.global _start

.equ REG_DISPCNT,  0x04000000
.equ REG_DISPSTAT, 0x04000004
.equ REG_IE,       0x04000200
.equ REG_IF,       0x04000202
.equ REG_IME,      0x04000208
.equ IRQ_VECTOR,   0x03007FFC
.equ PAL_BG,       0x05000000
.equ VRAM,         0x06000000

_start:
    bl handler

    ldr r0, =VRAM
    mov r1, #0
    strb r1, [r0]

    ldr r0, =PAL_BG
    mov r1, #0
    strh r1, [r0]
    add r0, r0, #2
    mov r1, #0xE0
    orr r1, r1, #0x0300
    strh r1, [r0]

    ldr r0, =IRQ_VECTOR
    ldr r1, =handler
    str r1, [r0]

    ldr r0, =REG_DISPCNT
    mov r1, #4
    orr r1, r1, #0x0400
    strh r1, [r0]

    ldr r0, =REG_DISPSTAT
    mov r1, #8
    strh r1, [r0]

    ldr r0, =REG_IE
    mov r1, #1
    strh r1, [r0]

    ldr r0, =REG_IME
    mov r1, #1
    strh r1, [r0]

loop:
    swi 0x05
    b loop

handler:
    stmfd sp!, {r0-r1, lr}
    ldr r0, =VRAM
    mov r1, #1
    strb r1, [r0]
    ldr r0, =REG_IF
    mov r1, #1
    strh r1, [r0]
    ldmfd sp!, {r0-r1, lr}
    bx lr
