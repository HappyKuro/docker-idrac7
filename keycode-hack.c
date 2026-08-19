// from https://github.com/anchor/idrac-kvm-keyboard-fix
/*
 * Shared library hack to translate evdev keycodes to old style keycodes.
 *
 * Dell's Avocent client carries a hardcoded keycode -> PS/2 scancode table
 * built when X still used the XFree86 keymap. Modern X servers hand out evdev
 * keycodes instead, so we intercept XNextEvent, look up which key the event
 * really was via its keysym, and rewrite the keycode to the XFree86 value the
 * client expects.
 *
 * Every value below is therefore an OLD-STYLE XFree86 keycode, never an evdev
 * one. The two keymaps agree across the main typing block (that part of the
 * table doubles as layout normalisation), but they diverge for the navigation
 * cluster, the right-hand modifiers and part of the keypad -- and it is exactly
 * there that writing an evdev value silently turns an entry into a no-op.
 */
#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>


static int (*real_XNextEvent)(Display *, XEvent *) = NULL;
static KeyCode (*real_XKeysymToKeycode)(Display *, KeySym) = NULL;
static KeySym (*sym_XKeycodeToKeysym)(Display *, KeyCode, int) = NULL;
static int hack_initialised = 0;

#define DEBUG 0

#if DEBUG
static FILE *fd = NULL;
#endif

static void
hack_init(void)
{
    void *h;

    h = dlopen("libX11.so", RTLD_LAZY);
    if (h == NULL) {
        h = dlopen("libX11.so.6", RTLD_LAZY);
        if (h == NULL) {
            fprintf(stderr, "Unable to open libX11\n");
            _exit(1);
        }
    }

    real_XNextEvent = dlsym(h, "XNextEvent");
    if (real_XNextEvent == NULL) {
        fprintf(stderr, "Unable to find symbol\n");
        _exit(1);
    }

    real_XKeysymToKeycode = dlsym(h, "XKeysymToKeycode");
    if (real_XKeysymToKeycode == NULL) {
        fprintf(stderr, "Unable to find symbol\n");
        _exit(1);
    }

    sym_XKeycodeToKeysym = dlsym(h, "XKeycodeToKeysym");
    if (sym_XKeycodeToKeysym == NULL) {
        fprintf(stderr, "Unable to find symbol\n");
        _exit(1);
    }

#if DEBUG
    if (fd == NULL) {
        fd = fopen("/tmp/keycode-log", "a");
        if (fd == NULL)
            fprintf(stderr, "Unable to open key-log\n");
    }
#endif

    hack_initialised = 1;
}

int
XNextEvent(Display *display, XEvent *event)
{
    int r;

    if (!hack_initialised)
        hack_init();

    r = real_XNextEvent(display, event);

    if (event->type == KeyPress || event->type == KeyRelease) {
        XKeyEvent *keyevent;
        KeySym keysym;

        keyevent = (XKeyEvent *)event;
#if DEBUG
        if (fd != NULL) {
            fprintf(fd, "KeyEvent: %d\n", keyevent->keycode);
            fflush(fd);
        }
#endif

        /* mangle keycodes */
        keysym = sym_XKeycodeToKeysym(display, keyevent->keycode, 0);
        switch (keysym) {
          /* Modifiers */
          case XK_Shift_R: keyevent->keycode = 62; break;
          case XK_Shift_L: keyevent->keycode = 50; break;
          case XK_Control_L: keyevent->keycode = 37; break;
          case XK_Control_R: keyevent->keycode = 109; break;
          case XK_Alt_L: keyevent->keycode = 64; break;
          case XK_Alt_R: keyevent->keycode = 113; break;
          case XK_Super_L: keyevent->keycode = 115; break;
          case XK_Super_R: keyevent->keycode = 116; break;
          case XK_Menu: keyevent->keycode = 117; break;
          case XK_Caps_Lock: keyevent->keycode = 66; break;
          case XK_Num_Lock: keyevent->keycode = 77; break;
          case XK_Scroll_Lock: keyevent->keycode = 78; break;
          case XK_Pause: keyevent->keycode = 110; break;

          /* Extended keyboard navigation keys */
          case XK_Home: keyevent->keycode = 97; break;
          case XK_End: keyevent->keycode = 103; break;
          case XK_Prior: keyevent->keycode = 99; break;
          case XK_Next: keyevent->keycode = 105; break;
          case XK_Insert: keyevent->keycode = 106; break;
          case XK_Delete: keyevent->keycode = 107; break;
          /* Unmapped, evdev Print is 107 -- which the client would read as
             Delete. Send the XFree86 Print instead. */
          case XK_Print: keyevent->keycode = 111; break;

          /* Numeric keypad keys */
          case XK_KP_Equal: keyevent->keycode = 126; break;
          case XK_KP_Divide: keyevent->keycode = 112; break;
          case XK_KP_Multiply: keyevent->keycode = 63; break;
          case XK_KP_Subtract: keyevent->keycode = 82; break;
          case XK_KP_Add: keyevent->keycode = 86; break;
          case XK_KP_Enter: keyevent->keycode = 108; break;
          /* The digit/decimal cases below never actually match: with NumLock
             off, XKeycodeToKeysym(kc, 0) reports KP_Home/KP_Insert/KP_Delete
             etc. rather than KP_7/KP_0/KP_Decimal. They are harmless because
             keycodes 79-91 are identical in both keymaps, so the untouched
             pass-through is already correct. */
          case XK_KP_Decimal: keyevent->keycode = 91; break;
          case XK_KP_0: keyevent->keycode = 90; break;
          case XK_KP_1: keyevent->keycode = 87; break;
          case XK_KP_2: keyevent->keycode = 88; break;
          case XK_KP_3: keyevent->keycode = 89; break;
          case XK_KP_4: keyevent->keycode = 83; break;
          case XK_KP_5: keyevent->keycode = 84; break;
          case XK_KP_6: keyevent->keycode = 85; break;
          case XK_KP_7: keyevent->keycode = 79; break;
          case XK_KP_8: keyevent->keycode = 80; break;
          case XK_KP_9: keyevent->keycode = 81; break;


          /* top row - function keys */
          case XK_Escape: keyevent->keycode = 9; break;
          case XK_F1: keyevent->keycode = 67; break;
          case XK_F2: keyevent->keycode = 68; break;
          case XK_F3: keyevent->keycode = 69; break;
          case XK_F4: keyevent->keycode = 70; break;
          case XK_F5: keyevent->keycode = 71; break;
          case XK_F6: keyevent->keycode = 72; break;
          case XK_F7: keyevent->keycode = 73; break;
          case XK_F8: keyevent->keycode = 74; break;
          case XK_F9: keyevent->keycode = 75; break;
          case XK_F10: keyevent->keycode = 76; break;
          case XK_F11: keyevent->keycode = 95; break;
          case XK_F12: keyevent->keycode = 96; break;

          /* Second row: numeric keys, 12345 */
          case XK_grave: keyevent->keycode = 49; break;
          case XK_1: keyevent->keycode = 10; break;
          case XK_2: keyevent->keycode = 11; break;
          case XK_3: keyevent->keycode = 12; break;
          case XK_4: keyevent->keycode = 13; break;
          case XK_5: keyevent->keycode = 14; break;
          case XK_6: keyevent->keycode = 15; break;
          case XK_7: keyevent->keycode = 16; break;
          case XK_8: keyevent->keycode = 17; break;
          case XK_9: keyevent->keycode = 18; break;
          case XK_0: keyevent->keycode = 19; break;
          case XK_minus: keyevent->keycode = 20; break;
          case XK_equal: keyevent->keycode = 21; break;
          case XK_BackSpace: keyevent->keycode = 22; break;

          /* Third row: qwerty */
          case XK_Tab: keyevent->keycode = 23; break;
          case XK_q: keyevent->keycode = 24; break;
          case XK_w: keyevent->keycode = 25; break;
          case XK_e: keyevent->keycode = 26; break;
          case XK_r: keyevent->keycode = 27; break;
          case XK_t: keyevent->keycode = 28; break;
          case XK_y: keyevent->keycode = 29; break;
          case XK_u: keyevent->keycode = 30; break;
          case XK_i: keyevent->keycode = 31; break;
          case XK_o: keyevent->keycode = 32; break;
          case XK_p: keyevent->keycode = 33; break;
          case XK_bracketleft: keyevent->keycode = 34; break;
          case XK_bracketright: keyevent->keycode = 35; break;
          case XK_backslash: keyevent->keycode = 51; break;

          /* Fourth row: asdf */
          case XK_a: keyevent->keycode = 38; break;
          case XK_s: keyevent->keycode = 39; break;
          case XK_d: keyevent->keycode = 40; break;
          case XK_f: keyevent->keycode = 41; break;
          case XK_g: keyevent->keycode = 42; break;
          case XK_h: keyevent->keycode = 43; break;
          case XK_j: keyevent->keycode = 44; break;
          case XK_k: keyevent->keycode = 45; break;
          case XK_l: keyevent->keycode = 46; break;
          case XK_semicolon: keyevent->keycode = 47; break;
          case XK_apostrophe: keyevent->keycode = 48; break;
          case XK_Return: keyevent->keycode = 36; break;

          /* Fifth row: zxcv */
          case XK_z: keyevent->keycode = 52; break;
          case XK_x: keyevent->keycode = 53; break;
          case XK_c: keyevent->keycode = 54; break;
          case XK_v: keyevent->keycode = 55; break;
          case XK_b: keyevent->keycode = 56; break;
          case XK_n: keyevent->keycode = 57; break;
          case XK_m: keyevent->keycode = 58; break;
          case XK_comma: keyevent->keycode = 59; break;
          case XK_period: keyevent->keycode = 60; break;
          case XK_slash: keyevent->keycode = 61; break;

          case XK_space: keyevent->keycode = 65; break;

          /* Arrow keys */
          case XK_Up: keyevent->keycode = 98; break;
          case XK_Left: keyevent->keycode = 100; break;
          case XK_Right: keyevent->keycode = 102; break;
          case XK_Down: keyevent->keycode = 104; break;

        }
    }

    return r;
}

#if DEBUG
KeyCode
XKeysymToKeycode(Display *display, KeySym keysym)
{
    KeyCode keycode;

    if (!hack_initialised)
        hack_init();

    keycode = real_XKeysymToKeycode(display, keysym);

    if (fd != NULL) {
        fprintf(fd, "XKeysymToKeycode: %d\n", keycode);
        fflush(fd);
    }

    return keycode;
}
#endif
