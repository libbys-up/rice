#include <stdio.h>
#include <stdlib.h>

/* rem: same sign as dividend (a) */
int my_rem(int a, int b)
{
    return a % b;  // C already matches Haskell's rem behavior
}

/* mod: same sign as divisor (b) */
int my_mod(int a, int b)
{
    int r = a % b;// + b * (r != 0 && ((r < 0 && b > 0) || (r > 0 && b < 0)));

    // If remainder has a different sign than divisor, adjust it
    if (r != 0 && ((r < 0 && b > 0) || (r > 0 && b < 0))) {
        r += b;
    }

    return r;
}

/* quot: truncates toward zero (same as C division) */
int my_quot(int a, int b)
{
    return a / b;
}

/* div: rounds toward negative infinity */
int my_div(int a, int b)
{
    return (a - my_mod(a,b)) / b;
}


int main()
{
    printf("rem 5 3 = %d\n", my_rem(5, 3));
    printf("mod 5 3 = %d\n", my_mod(5, 3));

    printf("rem -5 3 = %d\n", my_rem(-5, 3));
    printf("mod -5 3 = %d\n", my_mod(-5, 3));

    printf("rem 5 -3 = %d\n", my_rem(5, -3));
    printf("mod 5 -3 = %d\n", my_mod(5, -3));

    printf("rem -5 -3 = %d\n", my_rem(-5, -3));
    printf("mod -5 -3 = %d\n", my_mod(-5, -3));

    printf("quot 5 3 = %d\n", my_quot(5, 3));
    printf("div 5 3 = %d\n", my_div(5, 3));

    printf("quot -5 3 = %d\n", my_quot(-5, 3));
    printf("div -5 3 = %d\n", my_div(-5, 3));

    printf("quot 5 -3 = %d\n", my_quot(5, -3));
    printf("div 5 -3 = %d\n", my_div(5, -3));

    printf("quot -5 -3 = %d\n", my_quot(-5, -3));
    printf("div -5 -3 = %d\n", my_div(-5, -3));

    return 0;
}
