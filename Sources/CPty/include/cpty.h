#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>
#include <sys/ioctl.h>

/// Fork a child running the user's login shell attached to a fresh pty.
/// Returns the child pid (or -1) and writes the master fd into *amaster.
/// socket_path (may be NULL) is exported to the child as INFINITTY_SOCKET.
/// cwd (may be NULL) is the shell's starting directory; if chdir fails the
/// shell keeps the inherited cwd.
pid_t cpty_spawn_shell(int *amaster, const struct winsize *ws,
                       const char *socket_path, const char *cwd);

/// Update the pty's window size (drives SIGWINCH in the child).
int cpty_set_winsize(int fd, unsigned short rows, unsigned short cols,
                     unsigned short xpixel, unsigned short ypixel);

#endif
