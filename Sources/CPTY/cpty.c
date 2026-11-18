#include "cpty.h"
#include <util.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>

int cpty_spawn(const char *path, char *const argv[], char *const envp[],
               const char *cwd, unsigned short cols, unsigned short rows,
               int *master_fd) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) return -1;

    if (pid == 0) {
        /* child */
        sigset_t set;
        sigemptyset(&set);
        sigprocmask(SIG_SETMASK, &set, NULL);
        for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);

        struct termios t;
        if (tcgetattr(STDIN_FILENO, &t) == 0) {
            t.c_iflag |= IUTF8;
            tcsetattr(STDIN_FILENO, TCSANOW, &t);
        }
        if (cwd && *cwd) {
            if (chdir(cwd) != 0) chdir("/");
        }
        execve(path, argv, envp);
        _exit(127);
    }

    fcntl(master, F_SETFD, FD_CLOEXEC);
    *master_fd = master;
    return (int)pid;
}

int cpty_set_size(int fd, unsigned short cols, unsigned short rows) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

#include <libproc.h>
int cpty_cwd(pid_t pid, char *buf, unsigned long len) {
    struct proc_vnodepathinfo info;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (n <= 0) return -1;
    strlcpy(buf, info.pvi_cdir.vip_path, len);
    return 0;
}
