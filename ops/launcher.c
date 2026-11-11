// Tiny launcher so macOS attributes Bluetooth access to AtomHealth.app (which declares
// NSBluetoothAlwaysUsageDescription) instead of the bare Python binary. Runs the server as a child.
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t child;
static void fwd(int s) { if (child > 0) kill(child, s); }

int main(void) {
    const char *py = PY_PATH, *dir = PROJECT_DIR;
    if (chdir(dir) != 0) { perror("chdir"); return 1; }
    signal(SIGTERM, fwd); signal(SIGINT, fwd);
    child = fork();
    if (child == 0) {
        execl(py, py, "-m", "atomhealth", "--port", "8777", (char *)NULL);
        perror("exec"); _exit(127);
    }
    int st; waitpid(child, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
