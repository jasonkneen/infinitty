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
        "INFINITTY_SOCKET=", "TITERM_SOCKET=",
        "INFINITTY_PANE_ID=", "INFINITTY_APP_SOCKET=", NULL,
    };
    for (int i = 0; keys[i]; i++) {
        if (strncmp(entry, keys[i], strlen(keys[i])) == 0) {
            return keys[i];
        }
    }
    return NULL;
}

/* "KEY=VALUE", or NULL when the value is absent/empty. Caller frees. */
static char *env_entry(const char *key, const char *value) {
    char *entry = NULL;
    if (value == NULL || *value == '\0') {
        return NULL;
    }
    return asprintf(&entry, "%s=%s", key, value) < 0 ? NULL : entry;
}

pid_t cpty_spawn_shell(int *amaster, const struct winsize *ws,
                       const struct cpty_identity *identity, const char *cwd) {
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
    /* room for inherited + 3 terminal keys + CPTY_IDENTITY_MAX + NULL */
    char **envp = calloc(count + 4 + CPTY_IDENTITY_MAX, sizeof(char *));
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
    /* Pane identity: the socket that talks to this pane, the pane's own id,
       and the app-wide socket. Exporting all three means a child process --
       including one an SSH hop away -- can address the pane it runs in. */
    const char *pane_socket = identity ? identity->pane_socket : NULL;
    const char *keys[CPTY_IDENTITY_MAX] = {
        "INFINITTY_SOCKET",
        "TITERM_SOCKET", /* legacy name, kept for existing integrations */
        "INFINITTY_PANE_ID",
        "INFINITTY_APP_SOCKET",
    };
    const char *values[CPTY_IDENTITY_MAX] = {
        pane_socket,
        pane_socket,
        identity ? identity->pane_id : NULL,
        identity ? identity->app_socket : NULL,
    };
    char *owned[CPTY_IDENTITY_MAX] = {NULL};
    for (int i = 0; i < CPTY_IDENTITY_MAX; i++) {
        owned[i] = env_entry(keys[i], values[i]);
        if (owned[i]) {
            envp[n++] = owned[i];
        }
    }
    envp[n] = NULL;

    struct winsize wsz = *ws;
    pid_t pid = forkpty(amaster, NULL, NULL, &wsz);
    if (pid == 0) {
        /* chdir is async-signal-safe; on failure keep the inherited cwd. */
        if (cwd && *cwd) {
            (void)chdir(cwd);
        }
        execve(shell, argv, envp);
        _exit(127);
    }

    free(argv0);
    for (int i = 0; i < CPTY_IDENTITY_MAX; i++) {
        free(owned[i]);
    }
    free(envp);
    return pid;
}

int cpty_set_winsize(int fd, unsigned short rows, unsigned short cols,
                     unsigned short xpixel, unsigned short ypixel) {
    struct winsize ws = {rows, cols, xpixel, ypixel};
    return ioctl(fd, TIOCSWINSZ, &ws);
}
