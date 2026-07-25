#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>
#include <sys/ioctl.h>

/// Number of environment entries `cpty_identity` can contribute.
#define CPTY_IDENTITY_MAX 4

/// How the child addresses the pane it is running in. Every field may be
/// NULL; each non-empty one becomes an environment entry.
struct cpty_identity {
    /// This pane's control socket -> INFINITTY_SOCKET (and legacy TITERM_SOCKET).
    const char *pane_socket;
    /// This pane's id, as used by the app socket -> INFINITTY_PANE_ID.
    const char *pane_id;
    /// The app-wide control socket -> INFINITTY_APP_SOCKET.
    const char *app_socket;
};

/// Fork a child running the user's login shell attached to a fresh pty.
/// Returns the child pid (or -1) and writes the master fd into *amaster.
/// identity (may be NULL) is exported to the child; see `cpty_identity`.
/// cwd (may be NULL) is the shell's starting directory; if chdir fails the
/// shell keeps the inherited cwd.
pid_t cpty_spawn_shell(int *amaster, const struct winsize *ws,
                       const struct cpty_identity *identity, const char *cwd);

/// Update the pty's window size (drives SIGWINCH in the child).
int cpty_set_winsize(int fd, unsigned short rows, unsigned short cols,
                     unsigned short xpixel, unsigned short ypixel);

#endif
