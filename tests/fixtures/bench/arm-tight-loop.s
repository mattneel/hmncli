.syntax unified
.cpu arm7tdmi
.arm

.global _start

_start:
    mov r0, #0

loop:
    add r0, r0, #1
    b loop
