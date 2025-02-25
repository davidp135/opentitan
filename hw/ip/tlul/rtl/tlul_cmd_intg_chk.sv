// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

/**
 * Tile-Link UL command integrity check
 */

module tlul_cmd_intg_chk import tlul_pkg::*; (
  // TL-UL interface
  input  tl_h2d_t tl_i,

  // error output
  output logic err_o
);

  logic [1:0] err;
  logic data_err;
  tl_h2d_cmd_intg_t cmd;
  assign cmd = extract_h2d_cmd_intg(tl_i);

  prim_secded_inv_64_57_dec u_chk (
    .data_i({tl_i.a_user.cmd_intg, H2DCmdMaxWidth'(cmd)}),
    .data_o(),
    .syndrome_o(),
    .err_o(err)
  );

  tlul_data_integ_dec u_tlul_data_integ_dec (
    .data_intg_i({tl_i.a_user.data_intg, DataMaxWidth'(tl_i.a_data)}),
    .data_err_o(data_err)
  );

  // error output is transactional, it is up to the instantiating module
  // to determine if a permanent latch is feasible
  logic wr_txn;
  assign wr_txn = tl_i.a_valid &
                  (tl_i.a_opcode == PutFullData | tl_i.a_opcode == PutPartialData);

  assign err_o = tl_i.a_valid & (|err | (|data_err));


  logic unused_tl;
  assign unused_tl = |tl_i;

  `ASSERT_INIT(PayLoadWidthCheck, $bits(tl_h2d_cmd_intg_t) <= H2DCmdMaxWidth)

endmodule // tlul_payload_chk
