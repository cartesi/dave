#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int read_palette(FILE* palette_fp, uint8_t palette[256][3]) {
    int c;
    for (int i = 0; i < 256; ++i) {
        for (int j = 0; j < 4; ++j) {
            c = fgetc(palette_fp);
            if (c == EOF) {
                fprintf(stderr, "Palette file is too small\n");
                return EXIT_FAILURE;
            } else {
                // Ignore every fourth byte
                if (j < 3) {
                    palette[i][j] = (uint8_t)c;
                }
            }
        }
    }
    if (fgetc(palette_fp) != EOF) {
        fprintf(stderr, "Palette file is too big\n");
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

int apply_palette(uint8_t const palette[256][3]) {
    int c;
    while ((c = getchar()) != EOF) {
        for (int i = 0; i < 3; ++i) {
            if (putchar(palette[c][i]) == EOF) {
                perror("Error writing to output");
                return EXIT_FAILURE;
            }
        }
    }
    if (ferror(stdin)) {
        perror("Error reading from input");
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Expected palette file path\n");
        return EXIT_FAILURE;
    }
    uint8_t palette[256][3];
    FILE* palette_fp = fopen(argv[1], "rb");
    if (palette_fp == NULL) {
        perror("Error opening palette file");
        return EXIT_FAILURE;
    }
    int ret;
    ret = read_palette(palette_fp, palette);
    fclose(palette_fp);
    if (ret != EXIT_SUCCESS) { return ret; }
    return apply_palette(palette);
}
