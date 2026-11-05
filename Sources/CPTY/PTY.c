#include "CPTY.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#include <utmp.h>
#endif

int pool_pty_start(const char *executable, char *const argv[], char *const environment[],
                   const char *directory, unsigned short rows, unsigned short columns,
                   pool_pty_child *result) {
    int errors[2];
    if (pipe(errors) != 0) return errno;
    if (fcntl(errors[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(errors[1], F_SETFD, FD_CLOEXEC) != 0) {
        int code = errno; close(errors[0]); close(errors[1]); return code;
    }
    int master = -1, slave = -1;
    int descriptor_limit = getdtablesize();
    struct winsize dimensions = { .ws_row = rows, .ws_col = columns };
    if (openpty(&master, &slave, NULL, NULL, &dimensions) != 0) {
        int code = errno; close(errors[0]); close(errors[1]); return code;
    }
    if (fcntl(master, F_SETFD, FD_CLOEXEC) == -1 ||
        fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) == -1) {
        int code = errno;
        close(master); close(slave); close(errors[0]); close(errors[1]); return code;
    }
    pid_t pid = fork();
    if (pid == -1) {
        int code = errno;
        close(master); close(slave); close(errors[0]); close(errors[1]); return code;
    }
    if (pid == 0) {
        close(errors[0]);
        close(master);
        umask(0077);
        struct sigaction defaults = { .sa_handler = SIG_DFL };
        sigemptyset(&defaults.sa_mask);
        for (int signal = 1; signal < NSIG; signal++) {
            if (signal != SIGKILL && signal != SIGSTOP) sigaction(signal, &defaults, NULL);
        }
        sigset_t mask;
        sigemptyset(&mask);
        sigprocmask(SIG_SETMASK, &mask, NULL);
        if (login_tty(slave) != 0) {
            int code = errno;
            ssize_t ignored = write(errors[1], &code, sizeof(code));
            (void)ignored;
            _exit(127);
        }
        for (int fd = 3; fd < descriptor_limit; fd++) {
            if (fd != errors[1]) close(fd);
        }
        if (chdir(directory) == 0) execve(executable, argv, environment);
        int code = errno;
        ssize_t ignored = write(errors[1], &code, sizeof(code));
        (void)ignored;
        _exit(127);
    }
    close(slave);
    close(errors[1]);
    int code = 0;
    ssize_t count;
    do { count = read(errors[0], &code, sizeof(code)); } while (count < 0 && errno == EINTR);
    close(errors[0]);
    if (count != 0) {
        if (count < 0) code = errno;
        close(master);
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        return code ? code : EIO;
    }
    result->pid = pid;
    result->master = master;
    return 0;
}

int pool_pty_wait(pid_t pid, int *exit_status) {
    int status;
    pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return errno;
    *exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 0;
}
