#ifndef CSTACKPROBE_H
#define CSTACKPROBE_H

#include <mach/mach.h>
#include <stdint.h>

/// Where another thread of this process is: its return addresses, innermost first, written to
/// `out` (at most `max`). `depth` receives how many frames the thread has in all, counted up to
/// a bound. Returns how many were written, or -1 when the thread could not be read.
///
/// The thread is held only while its frames are read, and nothing is allocated and no lock is
/// taken while it is held, so a thread stopped inside an allocation cannot stop the reader.
int pool_stack_probe(mach_port_t thread, uintptr_t *out, int max, int *depth);

#endif
