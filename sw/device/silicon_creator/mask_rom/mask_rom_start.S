// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/base/multibits_asm.h"
#include "hw/top_earlgrey/sw/autogen/top_earlgrey_memory.h"
#include "aon_timer_regs.h"
#include "ast_regs.h"
#include "csrng_regs.h"
#include "edn_regs.h"
#include "entropy_src_regs.h"
#include "otp_ctrl_regs.h"
#include "pwrmgr_regs.h"
#include "sensor_ctrl_regs.h"
#include "sram_ctrl_regs.h"

/**
 * Mask ROM interrupt vectors.
 */

  // Push Mask ROM interrupt vector options.
  .option push

  // Disable RISC-V instruction compression: we need all instructions to
  // be exactly word wide in the interrupt vector.
  .option norvc

  // Disable RISC-V linker relaxation, as it can compress instructions at
  // link-time, which we also really don't want.
  .option norelax

/**
 * Initial RISC-V vectored exception/interrupt handlers.
 *
 * After reset all interrupts are disabled. Only exceptions (interrupt 0) and
 * non-maskable interrupts (interrupt 31) are possible. For simplicity however
 * we just set all interrupt handlers to the same exception handler.
 *
 * Since the C runtime is not initialized immediately after reset the initial
 * interrupt vector must only call functions written in assembly. Once the C
 * runtime is intialized the interrupt vector should be replaced.
 *
 * If the hardware is operating correctly the assembly interrupt handlers
 * should never be called.
 *
 * Note that the Ibex reset handler (entry point) immediately follows this
 * interrupt vector and can be thought of as an extra entry.
 *
 * More information about Ibex's interrupts can be found here:
 *   https://ibex-core.readthedocs.io/en/latest/03_reference/exception_interrupts.html
 *
 * TODO(lowRISC/ibex#1419): if direct mode support is added to Ibex it probably
 * makes sense to use it instead of vectored mode in the mask ROM.
 */
  .section .vectors, "ax"
  .balign 256
  .globl _mask_rom_interrupt_vector_asm
  .type _mask_rom_interrupt_vector_asm, @function
_mask_rom_interrupt_vector_asm:

  // Each jump instruction must be exactly 4 bytes in order to ensure that the
  // entries are properly located.
  .extern _asm_exception_handler
  .rept 32
  j _asm_exception_handler
  .endr

  // Ibex Reset Handler:
  j _mask_rom_start_boot

  // Set size so this vector can be disassembled.
  .size _mask_rom_interrupt_vector_asm, .-_mask_rom_interrupt_vector_asm

/**
 * Post C runtime initialization RISC-V vectored exception/interrupt handlers.
 *
 * This vector is placed into the .crt section so that .vectors doesn't need to
 * be padded to a 256 byte boundary.
 */
  .section .crt, "ax"
  .balign 256
  .globl _mask_rom_interrupt_vector_c
  .type _mask_rom_interrupt_vector_c, @function
_mask_rom_interrupt_vector_c:

  // Entry 0: exception handler.
  .extern mask_rom_exception_handler
  j mask_rom_exception_handler

  // Entries 1-30: interrupt handlers.
  .extern mask_rom_interrupt_handler
  .rept 30
  j mask_rom_interrupt_handler
  .endr

  // Entry 31: non-maskable interrupt handler.
  .extern mask_rom_nmi_handler
  j mask_rom_nmi_handler

  // Set size so this vector can be disassembled.
  .size _mask_rom_interrupt_vector_c, .-_mask_rom_interrupt_vector_c

  // Pop Mask ROM interrupt vector options.
  //
  // Re-enable compressed instructions, linker relaxation.
  .option pop

/**
 * Mask ROM runtime initialization code.
 */

  // NOTE: The "ax" flag below is necessary to ensure that this section
  // is allocated executable space in ROM by the linker.
  .section .crt, "ax"

  // Linker Relaxation is disabled until `__global_pointer$` is setup, below,
  // because otherwise some sequences may be turned into gp-relative sequences,
  // which is incorrect when `gp` is not initialized.
  .option push
  .option norelax

/**
 * Entry point after reset.
 */
  .globl _mask_rom_start_boot
  .type _mask_rom_start_boot, @function
_mask_rom_start_boot:

  /**
   * The interrupts are disabled globally on reset. However, We cannot disable
   * exceptions, or Ibex's non-maskable interrupts (interrupt 31), so we still
   * need to be careful.
   */

  // Configure the power manager to enable resets.
  // Note: this enables all types of reset request for simplicity.
  li t0, TOP_EARLGREY_PWRMGR_AON_BASE_ADDR
  li t1, -1
  sw t1, PWRMGR_RESET_EN_REG_OFFSET(t0)

  // Trigger a power manager configuration synchronization.
  li t1, (1 << PWRMGR_CFG_CDC_SYNC_SYNC_BIT)
  sw t1, PWRMGR_CFG_CDC_SYNC_REG_OFFSET(t0)

  // Setup the watchdog bite timer in order to reset the chip if the ROM stalls.
  // Since interrupts are disabled the watchdog bark will have no effect
  // therefore the bark threshold is just set to the highest possible value.
  li t0, TOP_EARLGREY_AON_TIMER_AON_BASE_ADDR
  li t1, 0xffffffff // TODO(lowRISC/opentitan##10215): reduce bite timer value.
  sw t1, AON_TIMER_WDOG_BITE_THOLD_REG_OFFSET(t0)
  li t1, 0xffffffff
  sw t1, AON_TIMER_WDOG_BARK_THOLD_REG_OFFSET(t0)

  // Enable the watchdog timer.
  li t1, (1 << AON_TIMER_WDOG_CTRL_ENABLE_BIT)
  sw t1, AON_TIMER_WDOG_CTRL_REG_OFFSET(t0)

  // Clear all the machine-defined interrupts, `MEIE`, `MTIE`, and `MSIE` fields
  // of `mie`.
  li   t0, 0xFFFF0888
  csrc mie, t0

  // Check if AST initialization should be skipped.
  li   t0, (TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR + \
            OTP_CTRL_SW_CFG_WINDOW_REG_OFFSET + \
            OTP_CTRL_PARAM_CREATOR_SW_CFG_AST_INIT_EN_OFFSET)
  li   t1, MULTIBIT_ASM_BOOL4_TRUE
  bne  t0, t1, .L_ast_init_skip

  // Copy the AST configuration from OTP.
  li   a0, (TOP_EARLGREY_AST_BASE_ADDR + AST_REGA_0_REG_OFFSET)
  li   a1, (TOP_EARLGREY_AST_BASE_ADDR + AST_REGAL_REG_OFFSET + 4)
  li   a2, (TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR + \
            OTP_CTRL_SW_CFG_WINDOW_REG_OFFSET + \
            OTP_CTRL_PARAM_CREATOR_SW_CFG_AST_CFG_OFFSET)
  call crt_section_copy

  // Wait for AST initialization to complete.
  li   a0, TOP_EARLGREY_SENSOR_CTRL_BASE_ADDR
.L_ast_done_loop:
  lw   t0, SENSOR_CTRL_STATUS_REG_OFFSET(a0)
  srli t0, t0, SENSOR_CTRL_STATUS_AST_INIT_DONE_BIT // no-op as bit index is currently 0
  andi t0, t0, 0x1
  beqz t0, .L_ast_done_loop

.L_ast_init_skip:
  // The following sequence enables the minimum level of entropy required to
  // initialize memory scrambling, as well as the entropy distribution network.
  li a0, TOP_EARLGREY_ENTROPY_SRC_BASE_ADDR
  // Note for BOOT_ROM initialization the FIPS_ENABLE bit is set to MuBi4False
  // to prevent the release of FIPS entropy until all the thresholds are set
  li t0, (0x5 << ENTROPY_SRC_CONF_FIPS_ENABLE_OFFSET) | \
         (0x5 << ENTROPY_SRC_CONF_ENTROPY_DATA_REG_ENABLE_OFFSET) | \
         (0x5 << ENTROPY_SRC_CONF_BOOT_BYPASS_DISABLE_OFFSET) | \
         (0x5 << ENTROPY_SRC_CONF_HEALTH_TEST_CLR_OFFSET) | \
         (0x5 << ENTROPY_SRC_CONF_RNG_BIT_ENABLE_OFFSET)
  sw t0, ENTROPY_SRC_CONF_REG_OFFSET(a0)

  li t0, (0xa << ENTROPY_SRC_MODULE_ENABLE_MODULE_ENABLE_OFFSET)
  sw t0, ENTROPY_SRC_MODULE_ENABLE_REG_OFFSET(a0)

  li a0, TOP_EARLGREY_CSRNG_BASE_ADDR
  li t0, (0xa << CSRNG_CTRL_ENABLE_OFFSET) | \
         (0xa << CSRNG_CTRL_SW_APP_ENABLE_OFFSET) | \
         (0xa << CSRNG_CTRL_READ_INT_STATE_OFFSET)
  sw t0, CSRNG_CTRL_REG_OFFSET(a0)

  li a0, TOP_EARLGREY_EDN0_BASE_ADDR
  li t0, (0xa << EDN_CTRL_EDN_ENABLE_OFFSET) | \
         (0xa << EDN_CTRL_BOOT_REQ_MODE_OFFSET) | \
         (0x5 << EDN_CTRL_AUTO_REQ_MODE_OFFSET) | \
         (0x5 << EDN_CTRL_CMD_FIFO_RST_OFFSET)
  sw t0, EDN_CTRL_REG_OFFSET(a0)

  // Scramble and initialize main memory (main SRAM).
  // Memory accesses will stall until initialization is complete.
  li a0, TOP_EARLGREY_SRAM_CTRL_MAIN_REGS_BASE_ADDR
  li a1, (1 << SRAM_CTRL_CTRL_RENEW_SCR_KEY_BIT) | (1 << SRAM_CTRL_CTRL_INIT_BIT)
  sw a1, SRAM_CTRL_CTRL_REG_OFFSET(a0)

  /**
   * Clean Device State Part 1 (Please refer to `boot.md` section "Cleaning Device
   * State").
   */

  // Zero all writable registers.
  li x1,  0x0
  li x2,  0x0
  li x3,  0x0
  li x4,  0x0
  li x5,  0x0
  li x6,  0x0
  li x7,  0x0
  li x8,  0x0
  li x9,  0x0
  li x10, 0x0
  li x11, 0x0
  li x12, 0x0
  li x13, 0x0
  li x14, 0x0
  li x15, 0x0
  li x16, 0x0
  li x17, 0x0
  li x18, 0x0
  li x19, 0x0
  li x20, 0x0
  li x21, 0x0
  li x22, 0x0
  li x23, 0x0
  li x24, 0x0
  li x25, 0x0
  li x26, 0x0
  li x27, 0x0
  li x28, 0x0
  li x29, 0x0
  li x30, 0x0
  li x31, 0x0

  // Must be called prior to any Main RAM access.
  .extern mask_rom_epmp_init
  call mask_rom_epmp_init

  /**
   * Setup C Runtime
   */

  // Initialize the `.data` section.
  la   a0, _data_start
  la   a1, _data_end
  la   a2, _data_init_start
  .extern crt_section_copy
  call crt_section_copy

  // Initialize the `.bss` section.
  la   a0, _bss_start
  la   a1, _bss_end
  .extern crt_section_clear
  call crt_section_clear

  // Set up stack pointer.
  //
  // In RISC-V, the stack grows downwards, so we load the address of the highest
  // word in the stack into sp. We don't load in `_stack_end`, as that points
  // beyond the end of RAM, and we always want it to be valid to dereference
  // `sp`, and we need this to be 128-bit (16-byte) aligned to meet the psABI.
  //
  // If an exception fires, the handler is conventionally only allowed to clobber
  // memory at addresses below `sp`.
  la sp, (_stack_end - 16)

  // Set up global pointer.
  //
  // This requires that we disable linker relaxations, or it will be relaxed to
  // `mv gp, gp`, so we disabled relaxations for all of `_mask_rom_start_boot`.
  la gp, __global_pointer$

  // Set exception/interrupt handlers.
  //
  // Now that the C runtime is initialized it is safe to use C functions as
  // exception/interrupt handlers.
  //
  // Note: the increment just sets the low bits to 0b01 which is the vectored
  // mode setting.
  la   t0, (_mask_rom_interrupt_vector_c + 1)
  csrw mtvec, t0

  /**
   * Jump to C Code
   */
  .extern mask_rom_main
  tail mask_rom_main

  // Set size so this function can be disassembled.
  .size _mask_rom_start_boot, .-_mask_rom_start_boot

  // Re-enable linker relaxation.
  .option pop
