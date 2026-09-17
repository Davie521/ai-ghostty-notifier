// Native-only integration fixture: a real CLI ancestor with a private PTY,
// or a recording notification executable selected by its argv[0] basename.
// Never reads or modifies the user's actual terminal or notifications.
#include <errno.h>
#include <fcntl.h>
#include <util.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

static void quoted(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; ++s) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { fputc('\\', f); fputc(c, f); }
        else if (c < 32) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}
int main(int argc, char **argv) {
    const char *name = strrchr(argv[0], '/'); name = name ? name + 1 : argv[0];
    // Benchmark-only live identity. It never touches Notification Center or
    // drains the spool; the benchmark validates/removes each request itself.
    if (!strcmp(name, "ghostty-notify-agent")) { for (;;) pause(); }
    if (!strcmp(name, "codex") || !strcmp(name, "claude")) {
        if (argc < 2) return 2;
        int master = -1, slave = -1, first = 1;
        int no_tty = !strcmp(argv[first], "--without-tty");
        if (no_tty) ++first;
        if (argc <= first) return 2;
        if (setsid() < 0 || (!no_tty && (openpty(&master, &slave, NULL, NULL, NULL) < 0 ||
            ioctl(slave, TIOCSCTTY, 0) < 0))) { perror("private PTY"); return 2; }
        pid_t child = fork();
        if (child < 0) return 2;
        if (!child) { execv(argv[first], argv + first); _exit(127); }
        int status;
        while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 2; }
        // Closing a controlling PTY sends its session leader SIGHUP. Ignore
        // it only in this fixture parent, after the hook has already exited.
        signal(SIGHUP, SIG_IGN);
        if (master >= 0) close(master);
        if (slave >= 0) close(slave);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }
    if (argc > 1 && !strcmp(argv[1], "--help")) {
        puts("--close-label --remove --group"); return 0;
    }
    const char *log = getenv("NOTIFY_TEST_LOG");
    if (log) {
        FILE *f = fopen(log, "a");
        if (!f) return 3;
        flock(fileno(f), LOCK_EX);
        fputc('[', f);
        for (int i = 1; i < argc; ++i) { if (i > 1) fputc(',', f); quoted(f, argv[i]); }
        fputs("]\n", f); fflush(f); flock(fileno(f), LOCK_UN); fclose(f);
    }
    if (argc > 1 && (!strcmp(argv[1], "--remove") || !strcmp(argv[1], "-remove"))) return 0;
    const char *delay = getenv("TEST_DELAY_MS");
    if (delay) usleep((useconds_t)(atoi(delay) * 1000));
    const char *action = getenv("TEST_ACTION");
    if (action) puts(action);
    const char *status = getenv("TEST_EXIT");
    return status ? atoi(status) : 0;
}
