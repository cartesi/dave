#include <stdio.h>
#include <stdlib.h>

#include "playpal.h"

int main()
{
    int c;
    while ((c = getchar()) != EOF)
    {
        for (int i = 0; i < 3; ++i)
        {
            if (putchar(playpal[c][i]) == EOF)
            {
                perror("Error writing to output");
                return EXIT_FAILURE;
            }
        }
    }
    if (ferror(stdin))
    {
        perror("Error reading from input");
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
