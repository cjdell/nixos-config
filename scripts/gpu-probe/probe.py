#!/usr/bin/env python3
"""Selective GPU workload probes for the Xid 79 / AER fault on the Z240 1060.

One axis per mode, so a death names the axis:
  engine        : ctx (no work) | fma (SM ALU) | vram (GDDR5) | dma (copy engine only)
  path          : CUDA driver API (hand PTX JIT'ed via ctypes) vs OpenCL ICD (C source)
  launch shape  : churn (tiny launch + host sync = OpenMM's pattern) vs continuous
  concurrency   : mixed (compute kernel + concurrent pinned H2D on another stream)
  cold bring-up : upshift (release the context, idle until the PCIe link parks, then
                  retain + JIT + exactly one kernel, timed — the death-adjacent event)

Hand-written PTX is JIT'ed by the driver, so no toolchain is needed on the host.
Every mode emits flushed progress markers, so the last marker before a death names
the axis the card died on.  Exit codes:
  0 ok | 17 CUDA/driver error (card went away) | 18 PTX/tooling error | 20 unused
"""
import argparse
import ctypes as C
from glob import glob
import os
import sys
import time

CUresult = C.c_int
MOD = C.c_void_p
FN = C.c_void_p
PTR = C.c_uint64
ST = C.c_void_p
CTX = C.c_void_p

CUDA_OK = 0
T0 = time.monotonic()


def log(msg):
    print(msg, flush=True)


def ms():
    return int((time.monotonic() - T0) * 1000)


class Cuda:
    def __init__(self):
        try:
            self.lib = C.CDLL("libcuda.so.1")
        except OSError as e:
            raise SystemExit((18, f"SKIP: no libcuda on this host ({e})"))
        self.f = {}
        for name, args in [
            ("cuInit", [C.c_uint]),
            ("cuDeviceGet", [C.POINTER(C.c_int), C.c_int]),
            ("cuDeviceGetName", [C.c_char_p, C.c_int, C.c_int]),
            ("cuDevicePrimaryCtxRetain", [C.POINTER(CTX), C.c_int]),
            ("cuDevicePrimaryCtxReset", [C.c_int]),
            ("cuCtxSetCurrent", [CTX]),
            ("cuModuleLoadData", [C.POINTER(MOD), C.c_char_p]),
            ("cuModuleGetFunction", [C.POINTER(FN), MOD, C.c_char_p]),
            ("cuLaunchKernel", [FN, C.c_uint, C.c_uint, C.c_uint,
                                C.c_uint, C.c_uint, C.c_uint,
                                C.c_uint, ST, C.POINTER(C.c_void_p), C.c_void_p]),
            ("cuMemAlloc", [C.POINTER(PTR), C.c_size_t]),
            ("cuMemFree", [PTR]),
            ("cuMemAllocHost", [C.POINTER(C.c_void_p), C.c_size_t]),
            ("cuMemcpyHtoDAsync", [PTR, C.c_void_p, C.c_size_t, ST]),
            ("cuMemcpyDtoHAsync", [C.c_void_p, PTR, C.c_size_t, ST]),
            ("cuMemsetD32Async", [PTR, C.c_uint, C.c_size_t, ST]),
            ("cuStreamCreate", [C.POINTER(ST), C.c_uint]),
            ("cuStreamSynchronize", [ST]),
        ]:
            # Modern driver-API entry points are the _v2 symbols: the unversioned
            # cuMemAlloc/cuMemAllocHost are the legacy variants and return
            # CUDA_ERROR_INVALID_CONTEXT (201) on a primary context.
            try:
                fn = getattr(self.lib, name + "_v2")
            except AttributeError:
                fn = getattr(self.lib, name)
            fn.restype = CUresult
            fn.argtypes = args
            self.f[name] = fn

    def chk(self, rc, what):
        if rc != CUDA_OK:
            raise SystemExit((17, f"{what} rc={rc}"))


# ------------------------------------------------------------- PTX (JIT'ed by driver)
# Every kernel writes its result back, so the compiler cannot delete the arithmetic.
PTX_NOP = """
.version 6.0
.target sm_50
.address_size 64
.visible .entry nop_k()
{
	ret;
}
"""

PTX_FMA = """
.version 6.0
.target sm_50
.address_size 64
.visible .entry fma_k(.param .u64 p_out, .param .u32 p_iters)
{
	.reg .pred 	%p<2>;
	.reg .b32 	%r<8>;
	.reg .b64 	%rd<4>;
	.reg .f32 	%f<4>;
	ld.param.u64 	%rd1, [p_out];
	ld.param.u32 	%r1, [p_iters];
	mov.u32 	%r2, %ntid.x;
	mov.u32 	%r3, %ctaid.x;
	mov.u32 	%r4, %tid.x;
	mad.lo.u32 	%r2, %r3, %r2, %r4;
	and.b32 	%r5, %r2, 1023;
	mul.lo.u32 	%r5, %r5, 4;
	cvt.u64.u32 	%rd3, %r5;
	add.u64 	%rd2, %rd1, %rd3;
	mov.f32 	%f1, 0f3F7FFFFF;
	mov.f32 	%f2, 0f33800000;
$L__fma:
	fma.rn.f32 	%f1, %f1, %f1, %f2;
	fma.rn.f32 	%f1, %f1, %f1, %f2;
	fma.rn.f32 	%f1, %f1, %f1, %f2;
	fma.rn.f32 	%f1, %f1, %f1, %f2;
	sub.u32 	%r1, %r1, 1;
	setp.ne.u32 	%p1, %r1, 0;
	@%p1 bra 	$L__fma;
	st.global.f32 	[%rd2], %f1;
	ret;
}
"""

PTX_VRAM = """
.version 6.0
.target sm_50
.address_size 64
.visible .entry vram_k(.param .u64 p_buf, .param .u64 p_bytes, .param .u32 p_passes)
{
	.reg .pred 	%p<2>;
	.reg .b32 	%r<8>;
	.reg .b64 	%rd<8>;
	.reg .b32 	%b<2>;
	ld.param.u64 	%rd1, [p_buf];
	ld.param.u64 	%rd2, [p_bytes];
	ld.param.u32 	%r1, [p_passes];
	mov.u32 	%r2, %ntid.x;
	mov.u32 	%r3, %ctaid.x;
	mov.u32 	%r4, %tid.x;
	mad.lo.u32 	%r2, %r3, %r2, %r4;
	mul.lo.u32 	%r5, %r2, 4;
	cvt.u64.u32 	%rd3, %r5;
	mov.u32 	%r6, %nctaid.x;
	mov.u32 	%r7, %ntid.x;
	mul.lo.u32 	%r6, %r6, %r7;
	mul.lo.u32 	%r6, %r6, 4;
	cvt.u64.u32 	%rd4, %r6;
$L__vram:
	add.u64 	%rd5, %rd1, %rd3;
	ld.global.b32 	%b1, [%rd5];
	add.u32 	%b1, %b1, 1;
	st.global.b32 	[%rd5], %b1;
	add.u64 	%rd3, %rd3, %rd4;
	setp.ge.u64 	%p1, %rd3, %rd2;
	@%p1 sub.u64 	%rd3, %rd3, %rd2;
	sub.u32 	%r1, %r1, 1;
	setp.ne.u32 	%p1, %r1, 0;
	@%p1 bra 	$L__vram;
	ret;
}
"""


def ptx_args(*vals):
    holders = list(vals)
    ptrs = (C.c_void_p * len(vals))()
    for i, v in enumerate(holders):
        ptrs[i] = C.cast(C.byref(v), C.c_void_p)
    return ptrs, holders


class Probe:
    def __init__(self, args):
        self.a = args
        self.cu = Cuda()
        self.cu.chk(self.cu.f["cuInit"](0), "cuInit")
        d = C.c_int(0)
        self.cu.chk(self.cu.f["cuDeviceGet"](C.byref(d), self.a.gpu),
                    f"cuDeviceGet({self.a.gpu})")
        name = C.create_string_buffer(128)
        self.cu.chk(self.cu.f["cuDeviceGetName"](name, 128, d), "cuDeviceGetName")
        self.bdf = self.pci_of(d.value)
        self.dev = d.value
        log(f"[{ms()}ms] dev={name.value.decode()} cuda-index={self.a.gpu} pci={self.bdf}")
        self.ctx = CTX()
        self.cu.chk(self.cu.f["cuDevicePrimaryCtxRetain"](C.byref(self.ctx), d),
                    "cuDevicePrimaryCtxRetain")
        self.cu.chk(self.cu.f["cuCtxSetCurrent"](self.ctx), "cuCtxSetCurrent")
        log(f"[{ms()}ms] ctx retained")
        self.mods = {}

    def fn(self, ptx, sym):
        key = (ptx, sym)
        if key not in self.mods:
            m = MOD()
            rc = self.cu.f["cuModuleLoadData"](C.byref(m), ptx.encode())
            if rc != CUDA_OK:
                raise SystemExit((18, f"cuModuleLoadData({sym}) rc={rc}"))
            f = FN()
            rc = self.cu.f["cuModuleGetFunction"](C.byref(f), m, sym.encode())
            if rc != CUDA_OK:
                raise SystemExit((18, f"cuModuleGetFunction({sym}) rc={rc}"))
            self.mods[key] = f
            log(f"[{ms()}ms] JIT ok: {sym}")
        return self.mods[key]

    def pci_of(self, idx):
        """Which physical slot we are really stressing (multi-GPU hosts)."""
        # cuda.h #defines cuDeviceGetPCIBusInfo to the _v2 symbol, so asking for the
        # bare name raises AttributeError — the same legacy-symbol trap this file
        # already documents for cuMemAlloc. Try both, newest first.
        buf = C.create_string_buffer(64)
        for name in ("cuDeviceGetPCIBusInfo_v2", "cuDeviceGetPCIBusInfo"):
            try:
                fn = getattr(self.cu.lib, name)
            except AttributeError:
                continue
            fn.argtypes = [C.POINTER(C.c_char), C.c_int, C.c_int]
            fn.restype = CUresult
            if fn(buf, 64, C.c_int(idx)) == CUDA_OK:
                return buf.value.decode()
        # Fall back to sysfs: one NVIDIA display-class device is unambiguous, and the
        # link-speed axis is worth more than a missing driver symbol.
        cands = []
        for p in sorted(glob("/sys/bus/pci/devices/*")):
            try:
                with open(p + "/vendor") as f: ven = f.read().strip()
                with open(p + "/class") as f: cls = f.read().strip()
            except OSError:
                continue
            if ven == "0x10de" and cls in ("0x030000", "0x030200"):
                cands.append(os.path.basename(p))
        if len(cands) == 1:
            log(f"[{ms()}ms] note: driver gave no bus id, using the only display-class NVIDIA device {cands[0]}")
            return cands[0]
        return "?"

    def link(self):
        """This device's live PCIe link, from sysfs (world-readable, no root)."""
        try:
            with open(f"/sys/bus/pci/devices/{self.bdf}/current_link_speed") as f:
                sp = f.read().strip()
            with open(f"/sys/bus/pci/devices/{self.bdf}/current_link_width") as f:
                wd = f.read().strip()
            return f"{sp} x{wd}"
        except OSError:
            return "?"

    def alloc(self, nbytes):
        p = PTR()
        self.cu.chk(self.cu.f["cuMemAlloc"](C.byref(p), nbytes),
                    f"cuMemAlloc({nbytes>>20}MiB)")
        return p

    def mode_ctx(self):
        f = self.fn(PTX_FMA, "fma_k")
        self.fn(PTX_VRAM, "vram_k")
        log(f"[{ms()}ms] modules JIT'ed; idling in a live CUDA context (no work)")
        end = time.monotonic() + self.a.seconds
        while time.monotonic() < end:
            time.sleep(5)
            log(f"[{ms()}ms] alive, idle in ctx")

    def mode_upshift(self):
        """Cold bring-up, repeatedly: release the primary context, stay silent
        until the card has parked and its link has fallen to its idle speed, then
        bring it back and make it do exactly ONE kernel.
        Every death observed on this fleet happened within seconds of precisely
        this event (FahCore_28 starting after idle), and no other mode here
        reproduces it, because every other mode holds one context on one warm link
        for its whole life. A healthy answer is a few ms and a link that climbs
        back on its own; the fault shows as a launch that never returns, a bring-up
        that takes seconds, or a card that is simply gone."""
        for i in range(self.a.cycles):
            # 1. let go completely: no context, so the driver is free to park the card.
            # On a console-on-this-card host the compositor may hold the CUDA primary
            # context (rc 600); that is a fact about the box, not a fault, so degrade to
            # bring-up-without-reset and say so instead of aborting the axis.
            rc = self.cu.f["cuDevicePrimaryCtxReset"](self.dev)
            reset_ok = (rc == CUDA_OK)
            if not reset_ok:
                log(f"[{ms()}ms] cycle={i} ctx reset rc={rc} (another process holds the CUDA "
                    f"primary context — e.g. the compositor); bring-up without the reset")
            self.mods.clear()          # module handles belong to the (possibly) dead context
            down = self.link()
            time.sleep(self.a.idle_secs)
            idle = self.link()
            # 2. bring it back and ask for exactly one kernel, end to end, timed
            t0 = time.perf_counter()
            if reset_ok:
                self.cu.chk(self.cu.f["cuDevicePrimaryCtxRetain"](C.byref(self.ctx), self.dev),
                            f"cycle {i}: retain")
                self.cu.chk(self.cu.f["cuCtxSetCurrent"](self.ctx), f"cycle {i}: setcurrent")
            f = self.fn(PTX_FMA, "fma_k")
            out = self.alloc(1 << 20)
            s = ST()
            self.cu.chk(self.cu.f["cuStreamCreate"](C.byref(s), 0), "cuStreamCreate")
            pa, hold = ptx_args(C.c_uint64(out.value), C.c_uint32(200000))
            rc = self.cu.f["cuLaunchKernel"](f, 2048, 1, 1, 256, 1, 1, 0, s, pa, None)
            if rc != CUDA_OK:
                raise SystemExit((17, f"cycle {i}: launch rc={rc} link_before={idle}"))
            rc = self.cu.f["cuStreamSynchronize"](s)
            cold_ms = (time.perf_counter() - t0) * 1000.0
            if rc != CUDA_OK:
                raise SystemExit((17, f"cycle {i}: sync rc={rc} after {cold_ms:.0f}ms "
                                      f"link_before={idle}"))
            up = self.link()
            self.cu.chk(self.cu.f["cuMemFree"](out), f"cycle {i}: cuMemFree")
            log(f"[{ms()}ms] cycle={i} link_after_reset={down} idle_for={self.a.idle_secs}s"
                f" link_idle={idle} cold_start={cold_ms:.0f}ms link_after={up}")
            if cold_ms > self.a.slow_ms:
                raise SystemExit((17, f"cycle {i}: cold bring-up took {cold_ms:.0f}ms"
                                      f" > slow-ms={self.a.slow_ms} — the upshift is not clean"))
        log(f"[{ms()}ms] {self.a.cycles} cold bring-ups, every one answered")

    def mode_churn(self):
        f = self.fn(PTX_NOP, "nop_k")
        s = ST()
        self.cu.chk(self.cu.f["cuStreamCreate"](C.byref(s), 0), "cuStreamCreate")
        n = 0
        t_start = time.monotonic()
        end = t_start + self.a.seconds
        while time.monotonic() < end:
            for _ in range(200):
                rc = self.cu.f["cuLaunchKernel"](f, 4, 1, 1, 32, 1, 1, 0, s, None, None)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"launch rc={rc} after {n} launches"))
                rc = self.cu.f["cuStreamSynchronize"](s)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"sync rc={rc} after {n} launches"))
                n += 1
            log(f"[{ms()}ms] launches+sync={n} ({n//(time.monotonic()-t_start):.0f}/s)")

    def mode_continuous(self):
        f = self.fn(PTX_FMA, "fma_k")
        out = self.alloc(1 << 20)
        s = ST()
        self.cu.chk(self.cu.f["cuStreamCreate"](C.byref(s), 0), "cuStreamCreate")
        n, last = 0, time.monotonic()
        end = time.monotonic() + self.a.seconds
        while time.monotonic() < end:
            pa, hold = ptx_args(C.c_uint64(out.value), C.c_uint32(20000))
            rc = self.cu.f["cuLaunchKernel"](f, 2048, 1, 1, 256, 1, 1, 0, s, pa, None)
            if rc != CUDA_OK:
                raise SystemExit((17, f"launch rc={rc} after {n} big launches"))
            n += 1
            if n % 25 == 0 or time.monotonic() - last > 5:
                rc = self.cu.f["cuStreamSynchronize"](s)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"sync rc={rc} after {n} big launches"))
                last = time.monotonic()
                log(f"[{ms()}ms] continuous fma launches={n} (SM busy, no churn)")
        self.cu.chk(self.cu.f["cuStreamSynchronize"](s), "final sync")
        log(f"[{ms()}ms] MODE-DONE continuous launches={n}")

    def mode_vram(self):
        f = self.fn(PTX_VRAM, "vram_k")
        nbytes = 2 * 1024 * 1024 * 1024
        buf = self.alloc(nbytes)
        s = ST()
        self.cu.chk(self.cu.f["cuStreamCreate"](C.byref(s), 0), "cuStreamCreate")
        self.cu.chk(self.cu.f["cuMemsetD32Async"](buf, 0, nbytes // 4, s), "memset")
        self.cu.chk(self.cu.f["cuStreamSynchronize"](s), "memset sync")
        n, last = 0, time.monotonic()
        end = time.monotonic() + self.a.seconds
        while time.monotonic() < end:
            pa, hold = ptx_args(C.c_uint64(buf.value), C.c_uint64(nbytes),
                                C.c_uint32(128))
            rc = self.cu.f["cuLaunchKernel"](f, 4096, 1, 1, 256, 1, 1, 0, s, pa, None)
            if rc != CUDA_OK:
                raise SystemExit((17, f"vram launch rc={rc} after {n} sweeps"))
            n += 1
            if time.monotonic() - last > 5:
                rc = self.cu.f["cuStreamSynchronize"](s)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"vram sync rc={rc} after {n} sweeps"))
                last = time.monotonic()
                log(f"[{ms()}ms] vram sweeps={n} (2GiB working set, no PCIe)")
        self.cu.chk(self.cu.f["cuStreamSynchronize"](s), "final sync")
        log(f"[{ms()}ms] MODE-DONE vram sweeps={n}")

    def mode_alloc(self):
        # VRAM allocation / page-table churn: allocate, first-touch, free, repeat.
        # The Nov 20 death landed 6 s after the CUDA context came up, at step 0 —
        # i.e. inside the core's first big allocations, not mid-simulation.
        s = ST()
        self.cu.chk(self.cu.f["cuStreamCreate"](C.byref(s), 0), "cuStreamCreate")
        n = 0
        end = time.monotonic() + self.a.seconds
        while time.monotonic() < end:
            for mb in (256, 1024, 512, 2048):
                p = self.alloc(mb << 20)
                self.cu.chk(self.cu.f["cuMemsetD32Async"](p, n, (mb << 18), s),
                            f"memset {mb}MiB")
                self.cu.chk(self.cu.f["cuStreamSynchronize"](s), "alloc sync")
                rc = self.cu.f["cuMemFree"](p)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"cuMemFree rc={rc} after {n} rounds"))
                n += 1
            log(f"[{ms()}ms] alloc/touch/free ops={n} (3.75GiB cycled per round)")

    def mode_dma(self):
        chunk = 64 * 1024 * 1024
        dev = self.alloc(chunk)
        h = C.c_void_p()
        self.cu.chk(self.cu.f["cuMemAllocHost"](C.byref(h), chunk), "cuMemAllocHost")
        s = ST()
        self.cu.chk(self.cu.f["cuStreamCreate"](C.byref(s), 0), "cuStreamCreate")
        n = 0
        end = time.monotonic() + self.a.seconds
        while time.monotonic() < end:
            for _ in range(16):
                rc = self.cu.f["cuMemcpyHtoDAsync"](dev, h, chunk, s)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"H2D rc={rc} after {n} chunks"))
                rc = self.cu.f["cuMemcpyDtoHAsync"](h, dev, chunk, s)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"D2H rc={rc} after {n} chunks"))
                rc = self.cu.f["cuStreamSynchronize"](s)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"dma sync rc={rc} after {n} chunks"))
                n += 1
            mb = n * chunk * 2 / 1048576
            log(f"[{ms()}ms] pinned chunks={n} moved={mb:.0f}MiB "
                f"({mb*1000/max(1,ms()):.0f} MiB/s, SM idle)")

    def mode_mixed(self):
        f = self.fn(PTX_VRAM, "vram_k")
        nbytes = 1024 * 1024 * 1024
        buf = self.alloc(nbytes)
        chunk = 32 * 1024 * 1024
        dev = self.alloc(chunk)
        h = C.c_void_p()
        self.cu.chk(self.cu.f["cuMemAllocHost"](C.byref(h), chunk), "cuMemAllocHost")
        sa, sb = ST(), ST()
        self.cu.chk(self.cu.f["cuStreamCreate"](C.byref(sa), 0), "streamA")
        self.cu.chk(self.cu.f["cuStreamCreate"](C.byref(sb), 0), "streamB")
        n = 0
        end = time.monotonic() + self.a.seconds
        while time.monotonic() < end:
            pa, hold = ptx_args(C.c_uint64(buf.value), C.c_uint64(nbytes),
                                C.c_uint32(8))
            rc = self.cu.f["cuLaunchKernel"](f, 1024, 1, 1, 256, 1, 1, 0, sa, pa, None)
            if rc != CUDA_OK:
                raise SystemExit((17, f"mixed launch rc={rc} after {n}"))
            for _ in range(4):
                rc = self.cu.f["cuMemcpyHtoDAsync"](dev, h, chunk, sb)
                if rc != CUDA_OK:
                    raise SystemExit((17, f"mixed H2D rc={rc} after {n}"))
            rc = self.cu.f["cuStreamSynchronize"](sa)
            if rc != CUDA_OK:
                raise SystemExit((17, f"mixed syncA rc={rc} after {n}"))
            rc = self.cu.f["cuStreamSynchronize"](sb)
            if rc != CUDA_OK:
                raise SystemExit((17, f"mixed syncB rc={rc} after {n}"))
            n += 1
            if n % 20 == 0:
                log(f"[{ms()}ms] mixed iters={n} (kernel + {n*128}MiB H2D)")
        log(f"[{ms()}ms] MODE-DONE mixed iters={n}")


# ------------------------------------------------------------------------- OpenCL
try:
    CL_API = C.CDLL("libOpenCL.so.1")
except OSError:
    CL_API = None


class OpenCL:
    def __init__(self):
        self.f = {}
        for name, res, args in [
            ("clGetPlatformIDs", C.c_int,
             [C.c_uint, C.c_void_p, C.POINTER(C.c_uint)]),
            ("clGetDeviceIDs", C.c_int,
             [C.c_void_p, C.c_ulong, C.c_uint, C.POINTER(C.c_void_p),
              C.POINTER(C.c_uint)]),
            ("clCreateContext", C.c_void_p,
             [C.c_void_p, C.c_uint, C.POINTER(C.c_void_p), C.c_void_p, C.c_void_p,
              C.POINTER(C.c_int)]),
            ("clCreateCommandQueue", C.c_void_p,
             [C.c_void_p, C.c_void_p, C.c_ulong, C.POINTER(C.c_int)]),
            ("clCreateProgramWithSource", C.c_void_p,
             [C.c_void_p, C.c_uint, C.POINTER(C.c_char_p), C.POINTER(C.c_size_t),
              C.POINTER(C.c_int)]),
            ("clBuildProgram", C.c_int,
             [C.c_void_p, C.c_uint, C.POINTER(C.c_void_p), C.c_char_p, C.c_void_p,
              C.c_void_p]),
            ("clCreateKernel", C.c_void_p,
             [C.c_void_p, C.c_char_p, C.POINTER(C.c_int)]),
            ("clCreateBuffer", C.c_void_p,
             [C.c_void_p, C.c_ulong, C.c_size_t, C.c_void_p, C.POINTER(C.c_int)]),
            ("clSetKernelArg", C.c_int,
             [C.c_void_p, C.c_uint, C.c_size_t, C.c_void_p]),
            ("clEnqueueNDRangeKernel", C.c_int,
             [C.c_void_p, C.c_void_p, C.c_uint, C.POINTER(C.c_size_t),
              C.POINTER(C.c_size_t), C.POINTER(C.c_size_t), C.c_uint, C.c_void_p,
              C.c_void_p]),
            ("clFinish", C.c_int, [C.c_void_p]),
        ]:
            fn = getattr(CL_API, name)
            fn.restype = res
            fn.argtypes = args
            self.f[name] = fn

    def setup(self):
        n = C.c_uint(0)
        self.f["clGetPlatformIDs"](0, None, C.byref(n))
        plats = (C.c_void_p * n.value)()
        self.f["clGetPlatformIDs"](n.value, plats, None)
        nd = C.c_uint(0)
        rc = self.f["clGetDeviceIDs"](plats[0], 1 << 2, 0, None, C.byref(nd))
        if rc != 0 or nd.value == 0:
            raise SystemExit((18, f"no OpenCL GPU (rc={rc} n={nd.value})"))
        devs = (C.c_void_p * nd.value)()
        self.f["clGetDeviceIDs"](plats[0], 1 << 2, nd.value, devs, None)
        self.dev = devs[0]
        cids = (C.c_void_p * 1)(self.dev)
        err = C.c_int(0)
        self.ctx = self.f["clCreateContext"](None, 1, cids, None, None, C.byref(err))
        if err.value != 0 or not self.ctx:
            raise SystemExit((18, f"clCreateContext err={err.value}"))
        self.q = self.f["clCreateCommandQueue"](self.ctx, self.dev, 0, C.byref(err))
        if err.value != 0 or not self.q:
            raise SystemExit((18, f"clCreateCommandQueue err={err.value}"))
        log(f"[{ms()}ms] opencl ctx+queue ok")

    def build(self, src, name):
        err = C.c_int(0)
        src_b = src.encode()
        lens = (C.c_size_t * 1)(len(src_b))
        ptrs = (C.c_char_p * 1)(src_b)
        prog = self.f["clCreateProgramWithSource"](self.ctx, 1, ptrs, lens,
                                                   C.byref(err))
        if err.value != 0:
            raise SystemExit((18, "clCreateProgramWithSource"))
        rc = self.f["clBuildProgram"](prog, 1, (C.c_void_p * 1)(self.dev),
                                      b"-cl-fast-relaxed-math", None, None)
        if rc != 0:
            raise SystemExit((18, f"clBuildProgram rc={rc}"))
        k = self.f["clCreateKernel"](prog, name.encode(), C.byref(err))
        if err.value != 0 or not k:
            raise SystemExit((18, f"clCreateKernel({name}) err={err.value}"))
        log(f"[{ms()}ms] opencl built {name}")
        return k


CL_FMA = """
__kernel void cl_fma(__global float* out, unsigned int iters){
  float a = 0.99999994f; const float b = 1e-6f;
  size_t g = get_global_id(0);
  for (unsigned int i = 0; i < iters; i++){
    a = a*a + b; a = a*a + b; a = a*a + b; a = a*a + b;
  }
  out[g & 1023] = a;
}
"""

CL_NOP = """
__kernel void cl_nop(__global float* out){
  if (get_global_id(0) == 0) out[0] = 1.0f;
}
"""


def mode_ocl(args, kind):
    if CL_API is None:
        raise SystemExit((18, "SKIP: no libOpenCL (install ocl-icd or the vendor ICD)"))
    cl = OpenCL()
    cl.setup()
    err = C.c_int(0)
    buf = cl.f["clCreateBuffer"](cl.ctx, 1, 1 << 20, None, C.byref(err))
    if err.value != 0 or not buf:
        raise SystemExit((18, f"clCreateBuffer err={err.value}"))
    cl.f["clSetKernelArg"]
    if kind == "churn":
        k = cl.build(CL_NOP, "cl_nop")
        arg = C.c_void_p(buf)
        cl.f["clSetKernelArg"](k, 0, C.sizeof(arg), C.byref(arg))
        n = 0
        t = time.monotonic()
        end = t + args.seconds
        while time.monotonic() < end:
            for _ in range(200):
                rc = cl.f["clEnqueueNDRangeKernel"](
                    cl.q, k, 1, None, (C.c_size_t * 1)(128), (C.c_size_t * 1)(32),
                    0, None, None)
                if rc != 0:
                    raise SystemExit((17, f"ocl enqueue rc={rc} after {n}"))
                rc = cl.f["clFinish"](cl.q)
                if rc != 0:
                    raise SystemExit((17, f"ocl finish rc={rc} after {n}"))
                n += 1
            log(f"[{ms()}ms] ocl launches+finish={n} "
                f"({n//(time.monotonic()-t):.0f}/s)")
    else:
        k = cl.build(CL_FMA, "cl_fma")
        arg = C.c_void_p(buf)
        it = C.c_uint(20000)
        cl.f["clSetKernelArg"](k, 0, C.sizeof(arg), C.byref(arg))
        cl.f["clSetKernelArg"](k, 1, C.sizeof(it), C.byref(it))
        n, last = 0, time.monotonic()
        end = time.monotonic() + args.seconds
        while time.monotonic() < end:
            rc = cl.f["clEnqueueNDRangeKernel"](
                cl.q, k, 1, None, (C.c_size_t * 1)(524288), (C.c_size_t * 1)(256),
                0, None, None)
            if rc != 0:
                raise SystemExit((17, f"ocl fma enqueue rc={rc} after {n}"))
            n += 1
            if time.monotonic() - last > 5:
                rc = cl.f["clFinish"](cl.q)
                if rc != 0:
                    raise SystemExit((17, f"ocl fma finish rc={rc} after {n}"))
                last = time.monotonic()
                log(f"[{ms()}ms] ocl fma launches={n}")
        rc = cl.f["clFinish"](cl.q)
        if rc != 0:
            raise SystemExit((17, f"ocl final finish rc={rc}"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["ctx", "churn", "continuous", "vram", "dma",
                                     "mixed", "alloc", "ocl_churn", "ocl_fma", "upshift"])
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--cycles", type=int, default=10,
                    help="upshift: how many cold bring-ups to perform")
    ap.add_argument("--idle-secs", type=int, default=12,
                    help="upshift: silence between releasing the context and the "
                         "first kernel — long enough for the card to park and the "
                         "link to fall to its idle speed")
    ap.add_argument("--slow-ms", type=int, default=1500,
                    help="upshift: fail a cycle whose cold bring-up exceeds this")
    ap.add_argument("--gpu", type=int, default=0,
                    help="CUDA device index (default 0). Pair with "
                         "CUDA_DEVICE_ORDER=PCI_BUS_ID to pin by slot.")
    a = ap.parse_args()
    log(f"[0ms] mode={a.mode} pid={os.getpid()} seconds={a.seconds}")
    try:
        if a.mode.startswith("ocl"):
            mode_ocl(a, a.mode.split("_")[1])
        else:
            p = Probe(a)
            getattr(p, "mode_" + a.mode)()
    except SystemExit as e:
        code, msg = e.args[0]
        log(f"[{ms()}ms] ABORT rc={code} {msg}")
        return code
    except Exception as e:
        log(f"[{ms()}ms] ABORT exception {type(e).__name__}: {e}")
        return 18
    log(f"[{ms()}ms] MODE-DONE {a.mode}")
    return 0


sys.exit(main())
