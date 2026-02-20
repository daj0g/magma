/*
 * persistent_hook.c — AFL++ QEMU persistent mode in-memory fuzzing hook
 *
 * This hook runs on the HOST (x86), not inside QEMU (ARM).
 * On every persistent iteration it copies the AFL++ testcase directly into
 * the guest's input buffer and updates the size register.
 *
 * Compile (x86, shared library):
 *   gcc -fPIC -shared persistent_hook.c -o persistent_hook.so
 *
 * Usage:
 *   export AFL_QEMU_PERSISTENT_HOOK=/path/to/persistent_hook.so
 *
 * See: qemu_mode/README.persistent.md §3.2
 */

#include <stdint.h>
#include <string.h>

/* Include the qemuafl API header for struct arm_regs.
 * Path is relative to the AFL++ repo root. */
#include "../../qemu_mode/qemuafl/qemuafl/api.h"

/* Guest-to-host address translation */
#define g2h(x) ((void *)((unsigned long)(x) + guest_base))

/* Must match kMaxAflInputSize in aflpp_qemu_driver.c */
#define MAX_INPUT_SIZE (1 * 1024 * 1024)

/*
 * Called on every persistent iteration, BEFORE the guest resumes at
 * AFL_QEMU_PERSISTENT_ADDR (= LLVMFuzzerTestOneInput).
 *
 * ARM32 calling convention (AAPCS):
 *   regs[0] (r0) = const uint8_t *data   — pointer to input buffer
 *   regs[1] (r1) = size_t size            — input length
 */
void afl_persistent_hook(struct arm_regs *regs, uint64_t guest_base,
                         uint8_t *input_buf, uint32_t input_buf_len) {

    if (input_buf_len > MAX_INPUT_SIZE)
        input_buf_len = MAX_INPUT_SIZE;

    memcpy(g2h(regs->r0), input_buf, input_buf_len);
    regs->r1 = input_buf_len;
}

#undef g2h

/*
 * Called once when QEMU loads this shared object.
 * Return 1 to enable shared memory testcase delivery (faster).
 * Return 0 to use stdin (input_buf will be NULL in the hook).
 */
int afl_persistent_hook_init(void) {

    return 1;
}