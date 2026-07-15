#include "cpty.h"

#include <crt_externs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <util.h>

/* Keys the child environment overrides. */
static const char *overridden(const char *entry) {
    static const char *keys[] = {
        "TERM=", "COLORTERM=", "TERM_PROGRAM=", "TERM_PROGRAM_VERSION=",
        "INFINITTY_SOCKET=", "TITERM_SOCKET=", NULL,
    };
    for (int i = 0; keys[i]; i++) {
        if (strncmp(entry, keys[i], strlen(keys[i])) == 0) {
            return keys[i];
        }
    }
    return NULL;
}

pid_t cpty_spawn_shell(int *amaster, const struct winsize *ws,
                       const char *socket_path) {
    /* Prepare argv and envp entirely before fork. The app has live worker
       threads, so the forked child may only call async-signal-safe
       functions (execve, _exit) before exec. */
    const char *shell = getenv("SHELL");
    if (shell == NULL || *shell == '\0') {
        shell = "/bin/zsh";
    }
    const char *slash = strrchr(shell, '/');
    const char *base = slash ? slash + 1 : shell;

    char *argv0 = NULL;
    if (asprintf(&argv0, "-%s", base) < 0) {
        return -1;
    }
    char *argv[2] = {argv0, NULL};

    char **environ_now = *_NSGetEnviron();
    int count = 0;
    while (environ_now[count]) {
        count++;
    }
    /* room for inherited + 4 overrides + optional socket + NULL */
    char **envp = calloc(count + 7, sizeof(char *));
    if (envp == NULL) {
        free(argv0);
        return -1;
    }
    int n = 0;
    for (int i = 0; i < count; i++) {
        if (!overridden(environ_now[i])) {
            envp[n++] = environ_now[i];
        }
    }
    envp[n++] = "TERM=xterm-256color";
    envp[n++] = "COLORTERM=truecolor";
    envp[n++] = "TERM_PROGRAM=infinitty";
    char *sock_entry = NULL;
    char *sock_entry_legacy = NULL;
    if (socket_path && *socket_path) {
        if (asprintf(&sock_entry, "INFINITTY_SOCKET=%s", socket_path) >= 0) {
            envp[n++] = sock_entry;
        }
        /* legacy name, kept one release for existing integrations */
        if (asprintf(&sock_entry_legacy, "TITERM_SOCKET=%s", socket_path) >= 0) {
            envp[n++] = sock_entry_legacy;
        }
    }
    envp[n] = NULL;

    struct winsize wsz = *ws;
    pid_t pid = forkpty(amaster, NULL, NULL, &wsz);
    if (pid == 0) {
        execve(shell, argv, envp);
        _exit(127);
    }

    free(argv0);
    free(sock_entry);
    free(sock_entry_legacy);
    free(envp);
    return pid;
}

int cpty_set_winsize(int fd, unsigned short rows, unsigned short cols,
                     unsigned short xpixel, unsigned short ypixel) {
    struct winsize ws = {rows, cols, xpixel, ypixel};
    return ioctl(fd, TIOCSWINSZ, &ws);
}
