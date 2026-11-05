#ifndef CLAUDE_POOL_PTY_H
#define CLAUDE_POOL_PTY_H
#include <sys/types.h>

typedef struct {
    pid_t pid;
    int master;
} pool_pty_child;

int pool_pty_start(const char *executable, char *const argv[], char *const environment[],
                   const char *directory, unsigned short rows, unsigned short columns,
                   pool_pty_child *result);
int pool_pty_wait(pid_t pid, int *exit_status);
#endif
