/* PTY/terminal transport only. Workspace and game policy live in e7. */
#define _GNU_SOURCE
#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vterm.h>

extern char **environ;
static int master = -1, focused, cols = 80, rows = 24, dirty;
static pid_t child = -1;
static long saved_generation;
static int save_fd = -1;
static char save_path[64];
static char last_save[128];
static ssize_t last_save_len;
static VTerm *term;
static TTF_Font *font;
static SDL_Surface *frame;
static char message[256] = "Open a script to start Neovim";
static const int cell_w = 8, cell_h = 17;

static char pending_input[65536];
static size_t pending_length;
static int ttf_started;
static void flush_input(void) {
    while (master >= 0 && pending_length) {
        ssize_t n = write(master, pending_input, pending_length);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        pending_length -= (size_t)n;
        memmove(pending_input, pending_input + n, pending_length);
    }
}
static void send_bytes(const char *data, size_t count) {
    if (master < 0)
        return;
    flush_input();
    if (count > sizeof pending_input - pending_length) {
        snprintf(message, sizeof message, "Neovim input queue full; paste in smaller chunks");
        return;
    }
    memcpy(pending_input + pending_length, data, count);
    pending_length += count;
    flush_input();
}
static void output(const char *s, size_t n, void *unused) {
    (void)unused;
    send_bytes(s, n);
}
void e7_terminal_close(void) {
    focused = 0;
    pending_length = 0;
    if (save_fd >= 0)
        close(save_fd);
    save_fd = -1;
    if (save_path[0])
        unlink(save_path);
    save_path[0] = 0;
    last_save_len = 0;
    if (master >= 0)
        close(master);
    master = -1;
    if (child > 0) {
        kill(-child, SIGTERM);
        for (int i = 0; i < 20; ++i) {
            if (waitpid(child, NULL, WNOHANG) != 0) {
                child = -1;
                break;
            }
            usleep(1000);
        }
        if (child > 0) {
            kill(-child, SIGKILL);
            waitpid(child, NULL, 0);
        }
    }
    child = -1;
    if (term)
        vterm_free(term);
    term = NULL;
    if (frame)
        SDL_DestroySurface(frame);
    frame = NULL;
    if (font)
        TTF_CloseFont(font);
    font = NULL;
    if (ttf_started)
        TTF_Quit();
    ttf_started = 0;
}
int e7_terminal_open(const char *path) {
    if (master < 0 && term)
        e7_terminal_close();
    if (master >= 0) {
        /* Escape Vim command metacharacters; never interpolate a shell command. */
        size_t n = strlen(path);
        if (n > 4096 || strchr(path, '\n') || strchr(path, '\r'))
            return -1;
        char command[8300];
        size_t at = 0;
        memcpy(command, "\033:edit ", 7);
        at = 7;
        for (size_t i = 0; i < n; ++i) {
            if (strchr(" \t\\|\"%#*?[]<>{}`$!'", path[i]))
                command[at++] = '\\';
            command[at++] = path[i];
        }
        command[at++] = '\r';
        send_bytes(command, at);
        return 0;
    }
    if (!TTF_Init())
        return -1;
    ttf_started = 1;
    const char *fonts[] = {"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
                           "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                           "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
                           "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf"};
    for (size_t i = 0; i < sizeof fonts / sizeof *fonts && !font; ++i)
        font = TTF_OpenFont(fonts[i], 14);
    if (!font) {
        e7_terminal_close();
        snprintf(message, sizeof message, "No monospace font found");
        return -1;
    }
    int slave;
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    if (openpty(&master, &slave, NULL, NULL, &size) < 0) {
        e7_terminal_close();
        return -1;
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    for (int i = 0; i < 3; ++i)
        posix_spawn_file_actions_adddup2(&actions, slave, i);
    posix_spawn_file_actions_addclose(&actions, master);
    posix_spawn_file_actions_addclose(&actions, slave);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);
    size_t count = 0;
    while (environ[count])
        ++count;
    strcpy(save_path, "/tmp/engine7-editor-XXXXXX");
    save_fd = mkstemp(save_path);
    if (save_fd < 0) {
        close(slave);
        e7_terminal_close();
        return -1;
    }
    fcntl(save_fd, F_SETFD, FD_CLOEXEC);
    char notify_env[128];
    snprintf(notify_env, sizeof notify_env, "E7_EDITOR_SAVE_FILE=%s", save_path);
    char **env = calloc(count + 3, sizeof *env);
    size_t j = 0;
    if (!env) {
        close(slave);
        e7_terminal_close();
        return -1;
    }
    for (size_t i = 0; i < count; ++i)
        if (strncmp(environ[i], "TERM=", 5) && strncmp(environ[i], "NVIM=", 5) &&
            strncmp(environ[i], "E7_EDITOR_SAVE_FILE=", 20))
            env[j++] = environ[i];
    env[j++] = "TERM=xterm-256color";
    env[j++] = notify_env;
    char *args[] = {"nvim", "--clean",    "-i", "NONE", "-u", "engine/editor/neovim.vim",
                    "--",   (char *)path, NULL};
    int rc = posix_spawnp(&child, "nvim", &actions, &attr, args, env);
    free(env);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    close(slave);
    if (rc) {
        e7_terminal_close();
        snprintf(message, sizeof message, "Cannot start nvim: %s", strerror(rc));
        return -1;
    }
    fcntl(master, F_SETFL, O_NONBLOCK);
    term = vterm_new(rows, cols);
    if (!term) {
        e7_terminal_close();
        return -1;
    }
    vterm_set_utf8(term, 1);
    vterm_output_set_callback(term, output, NULL);
    vterm_screen_enable_altscreen(vterm_obtain_screen(term), 1);
    vterm_screen_reset(vterm_obtain_screen(term), 1);
    dirty = 1;
    snprintf(message, sizeof message, "Neovim: :w saves; Apply code compiles and reloads");
    return 0;
}
int e7_terminal_alive(void) { return master >= 0; }
void e7_terminal_focus(int value) { focused = value; }
void e7_terminal_input(const char *data, size_t count) { send_bytes(data, count); }
void e7_terminal_resize(int width, int height) {
    int c = width / cell_w, r = height / cell_h;
    if (c < 12)
        c = 12;
    if (r < 4)
        r = 4;
    if (c > 240)
        c = 240;
    if (r > 100)
        r = 100;
    if (c == cols && r == rows)
        return;
    cols = c;
    rows = r;
    if (term)
        vterm_set_size(term, rows, cols);
    if (master >= 0) {
        struct winsize size = {.ws_row = rows, .ws_col = cols};
        ioctl(master, TIOCSWINSZ, &size);
    }
    dirty = 1;
}
void e7_terminal_event(const SDL_Event *event) {
    if (!focused || !term)
        return;
    if (event->type == SDL_EVENT_TEXT_INPUT) {
        send_bytes(event->text.text, strlen(event->text.text));
        return;
    }
    if (event->type != SDL_EVENT_KEY_DOWN)
        return;
    SDL_Keymod mods = event->key.mod;
    VTermModifier mod = VTERM_MOD_NONE;
    if (mods & SDL_KMOD_CTRL)
        mod |= VTERM_MOD_CTRL;
    if (mods & SDL_KMOD_ALT)
        mod |= VTERM_MOD_ALT;
    if (mods & SDL_KMOD_SHIFT)
        mod |= VTERM_MOD_SHIFT;
    VTermKey key = VTERM_KEY_NONE;
    switch (event->key.key) {
    case SDLK_ESCAPE:
        key = VTERM_KEY_ESCAPE;
        break;
    case SDLK_RETURN:
    case SDLK_KP_ENTER:
        key = VTERM_KEY_ENTER;
        break;
    case SDLK_TAB:
        key = VTERM_KEY_TAB;
        break;
    case SDLK_BACKSPACE:
        key = VTERM_KEY_BACKSPACE;
        break;
    case SDLK_DELETE:
        key = VTERM_KEY_DEL;
        break;
    case SDLK_UP:
        key = VTERM_KEY_UP;
        break;
    case SDLK_DOWN:
        key = VTERM_KEY_DOWN;
        break;
    case SDLK_LEFT:
        key = VTERM_KEY_LEFT;
        break;
    case SDLK_RIGHT:
        key = VTERM_KEY_RIGHT;
        break;
    case SDLK_HOME:
        key = VTERM_KEY_HOME;
        break;
    case SDLK_END:
        key = VTERM_KEY_END;
        break;
    case SDLK_PAGEUP:
        key = VTERM_KEY_PAGEUP;
        break;
    case SDLK_PAGEDOWN:
        key = VTERM_KEY_PAGEDOWN;
        break;
    }
    if (key)
        vterm_keyboard_key(term, key, mod);
    else if ((mod & (VTERM_MOD_CTRL | VTERM_MOD_ALT)) && event->key.key < 128)
        vterm_keyboard_unichar(term, event->key.key, mod);
}
long e7_terminal_saved(void) { return saved_generation; }
const char *e7_terminal_status(void) { return message; }
/* Nonblocking drain, then rasterize one whole grid into one GPU image. */
SDL_Surface *e7_terminal_frame(void) {
    if (!term)
        return NULL;
    flush_input();
    char bytes[16384];
    for (int i = 0; i < 32; ++i) {
        ssize_t n = read(master, bytes, sizeof bytes);
        if (n > 0) {
            vterm_input_write(term, bytes, (size_t)n);
            dirty = 1;
        } else
            break;
    }
    if (child > 0 && waitpid(child, NULL, WNOHANG) == child) {
        /* Keep the last frame; allow reopening after :q. */
        close(master);
        master = -1;
        child = -1;
        snprintf(message, sizeof message, "Neovim exited; open a file to restart");
    }
    if (save_fd >= 0) {
        char notification[128];
        ssize_t n = pread(save_fd, notification, sizeof notification, 0);
        if (n > 0 && notification[n - 1] == '\n' &&
            (n != last_save_len || memcmp(notification, last_save, (size_t)n))) {
            memcpy(last_save, notification, (size_t)n);
            last_save_len = n;
            ++saved_generation;
        }
    }
    if (!dirty)
        return NULL;
    dirty = 0;
    if (frame)
        SDL_DestroySurface(frame);
    frame = SDL_CreateSurface(cols * cell_w, rows * cell_h, SDL_PIXELFORMAT_ARGB8888);
    if (!frame)
        return NULL;
    VTermScreen *screen = vterm_obtain_screen(term);
    VTermPos cursor;
    vterm_state_get_cursorpos(vterm_obtain_state(term), &cursor);
    for (int pass = 0; pass < 2; ++pass)
        for (int y = 0; y < rows; ++y)
            for (int x = 0; x < cols; ++x) {
                VTermScreenCell cell;
                if (!vterm_screen_get_cell(screen, (VTermPos){y, x}, &cell))
                    continue;
                vterm_screen_convert_color_to_rgb(screen, &cell.fg);
                vterm_screen_convert_color_to_rgb(screen, &cell.bg);
                VTermColor fg = cell.fg, bg = cell.bg;
                if (cell.attrs.reverse || (cursor.row == y && cursor.col == x)) {
                    VTermColor t = fg;
                    fg = bg;
                    bg = t;
                }
                SDL_Rect rect = {x * cell_w, y * cell_h, cell_w, cell_h};
                if (!pass) {
                    SDL_FillSurfaceRect(
                        frame, &rect,
                        SDL_MapSurfaceRGB(frame, bg.rgb.red, bg.rgb.green, bg.rgb.blue));
                    continue;
                }
                if (!cell.chars[0] || cell.chars[0] == ' ' || cell.chars[0] == UINT32_MAX)
                    continue;
                char text[32];
                int length = 0;
                for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; ++i) {
                    if (length + 4 >= (int)sizeof text)
                        break;
                    length += SDL_UCS4ToUTF8(cell.chars[i], text + length) - (text + length);
                }
                text[length] = 0;
                SDL_Surface *glyph = TTF_RenderText_Blended(
                    font, text, length, (SDL_Color){fg.rgb.red, fg.rgb.green, fg.rgb.blue, 255});
                if (glyph) {
                    SDL_BlitSurface(glyph, NULL, frame, &rect);
                    SDL_DestroySurface(glyph);
                }
            }
    return frame;
}
/* Screen text is also exposed for an integration test without a GPU. */
size_t e7_terminal_text(char *out, size_t capacity) {
    if (!term)
        return 0;
    size_t at = 0;
    VTermScreen *screen = vterm_obtain_screen(term);
    for (int y = 0; y < rows && at + 1 < capacity; ++y) {
        for (int x = 0; x < cols && at + 1 < capacity; ++x) {
            VTermScreenCell cell;
            if (vterm_screen_get_cell(screen, (VTermPos){y, x}, &cell))
                out[at++] = cell.chars[0] >= 32 && cell.chars[0] < 127 ? (char)cell.chars[0] : ' ';
        }
        out[at++] = '\n';
    }
    return at;
}
