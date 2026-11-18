#ifndef CPTY_H
#define CPTY_H
#include <sys/types.h>

/// Spawns `path` attached to a new pseudo-terminal.
/// Returns the child pid (>0) and stores the master fd in `master_fd`, or -1 on failure.
int cpty_spawn(const char *path, char *const argv[], char *const envp[],
               const char *cwd, unsigned short cols, unsigned short rows,
               int *master_fd);

/// Updates the window size of the pty behind `fd`.
int cpty_set_size(int fd, unsigned short cols, unsigned short rows);



/// Copies the current working directory of `pid` into buf. Returns 0 on success.
int cpty_cwd(pid_t pid, char *buf, unsigned long len);
#endif
