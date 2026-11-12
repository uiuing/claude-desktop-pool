#include "CStackProbe.h"
#include <mach/mach_vm.h>
#include <pthread.h>

#define POOL_STACK_DEPTH_MOST 4096

// A frame record as the platform's calling convention leaves it: the caller's frame, then the return address.
static int read_frame(uintptr_t at, uintptr_t frame[2]) {
    mach_vm_size_t got = 0;
    // Read through the kernel: a frame pointer that points nowhere gives an error, not a fault.
    kern_return_t result = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)at, sizeof(uintptr_t) * 2,
                                                  (mach_vm_address_t)frame, &got);
    return result == KERN_SUCCESS && got == sizeof(uintptr_t) * 2;
}

int pool_stack_probe(mach_port_t thread, uintptr_t *out, int max, int *depth) {
    if (depth) *depth = 0;
    if (max <= 0 || thread == MACH_PORT_NULL || thread == pthread_mach_thread_np(pthread_self())) return -1;
    if (thread_suspend(thread) != KERN_SUCCESS) return -1;
    uintptr_t pc = 0, fp = 0;
    kern_return_t got;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    got = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    if (got == KERN_SUCCESS) { pc = (uintptr_t)arm_thread_state64_get_pc(state); fp = (uintptr_t)arm_thread_state64_get_fp(state); }
    // Addresses a system library signed keep the signature in their high bits.
    const uintptr_t address = 0x00007FFFFFFFFFFFull;
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    got = thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    if (got == KERN_SUCCESS) { pc = (uintptr_t)state.__rip; fp = (uintptr_t)state.__rbp; }
    const uintptr_t address = ~(uintptr_t)0;
#else
    got = KERN_FAILURE;
    const uintptr_t address = ~(uintptr_t)0;
#endif
    int written = 0, seen = 0;
    if (got == KERN_SUCCESS) {
        out[written++] = pc & address; seen = 1;
        uintptr_t frame[2];
        while (seen < POOL_STACK_DEPTH_MOST && fp != 0 && (fp & (sizeof(uintptr_t) - 1)) == 0 && read_frame(fp, frame)) {
            uintptr_t next = frame[0], back = frame[1] & address;
            if (back == 0) break;
            if (written < max) out[written++] = back;
            seen++;
            // Frames lie further up the stack the further out they are.
            if (next <= fp) break;
            fp = next;
        }
    }
    thread_resume(thread);
    if (depth) *depth = seen;
    return got == KERN_SUCCESS ? written : -1;
}
