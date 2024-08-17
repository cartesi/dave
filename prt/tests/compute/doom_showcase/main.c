#include "playpal2rgb.c"

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Expected palette file path\n");
        return EXIT_FAILURE;
    }

    return playpal2rgb((const char*) argv[1]);
}
