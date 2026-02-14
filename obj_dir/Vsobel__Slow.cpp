// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vsobel.h for the primary calling header

#include "Vsobel.h"
#include "Vsobel__Syms.h"

//==========

VL_CTOR_IMP(Vsobel) {
    Vsobel__Syms* __restrict vlSymsp = __VlSymsp = new Vsobel__Syms(this, name());
    Vsobel* const __restrict vlTOPp VL_ATTR_UNUSED = vlSymsp->TOPp;
    // Reset internal values
    
    // Reset structure values
    _ctor_var_reset();
}

void Vsobel::__Vconfigure(Vsobel__Syms* vlSymsp, bool first) {
    if (false && first) {}  // Prevent unused
    this->__VlSymsp = vlSymsp;
    if (false && this->__VlSymsp) {}  // Prevent unused
    Verilated::timeunit(-12);
    Verilated::timeprecision(-12);
}

Vsobel::~Vsobel() {
    VL_DO_CLEAR(delete __VlSymsp, __VlSymsp = NULL);
}

void Vsobel::_eval_initial(Vsobel__Syms* __restrict vlSymsp) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vsobel::_eval_initial\n"); );
    Vsobel* const __restrict vlTOPp VL_ATTR_UNUSED = vlSymsp->TOPp;
    // Body
    vlTOPp->__Vclklast__TOP__clk = vlTOPp->clk;
}

void Vsobel::final() {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vsobel::final\n"); );
    // Variables
    Vsobel__Syms* __restrict vlSymsp = this->__VlSymsp;
    Vsobel* const __restrict vlTOPp VL_ATTR_UNUSED = vlSymsp->TOPp;
}

void Vsobel::_eval_settle(Vsobel__Syms* __restrict vlSymsp) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vsobel::_eval_settle\n"); );
    Vsobel* const __restrict vlTOPp VL_ATTR_UNUSED = vlSymsp->TOPp;
}

void Vsobel::_ctor_var_reset() {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vsobel::_ctor_var_reset\n"); );
    // Body
    clk = VL_RAND_RESET_I(1);
    rst = VL_RAND_RESET_I(1);
    valid_in = VL_RAND_RESET_I(1);
    pixel_in = VL_RAND_RESET_I(8);
    valid_out = VL_RAND_RESET_I(1);
    pixel_out = VL_RAND_RESET_I(8);
}
