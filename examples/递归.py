def factorial(n):
    if n <= 1:
        return 1
    smaller_factorial = factorial(n - 1)
    result = n * smaller_factorial
    return result


answer = factorial(5)
print(answer)
