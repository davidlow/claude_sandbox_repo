"""
Basic arithmetic calculator.

Intentionally leaves several edge cases untested so the QA pipeline
(claude-qa) has meaningful work to discover and cover:
  - float division by zero vs int division by zero
  - power() with negative exponents or fractional exponents
  - integer overflow in pure-Python (academic — but type errors with numpy)
  - modulo with negative operands (sign conventions differ by language)
  - sqrt() of negative numbers
  - type mixing: passing strings, None, lists
  - chaining operations (order-of-operations edge cases)
"""

import math


def add(a, b):
    return a + b


def subtract(a, b):
    return a - b


def multiply(a, b):
    return a * b


def divide(a, b):
    if b == 0:
        raise ValueError("Cannot divide by zero")
    return a / b


def power(base, exponent):
    return base ** exponent


def sqrt(n):
    if n < 0:
        raise ValueError("Cannot take square root of a negative number")
    return math.sqrt(n)


def modulo(a, b):
    if b == 0:
        raise ValueError("Cannot take modulo with zero divisor")
    return a % b


def integer_divide(a, b):
    if b == 0:
        raise ValueError("Cannot integer-divide by zero")
    return a // b


def absolute_value(n):
    return abs(n)


def clamp(value, low, high):
    """Clamp value to the range [low, high]."""
    if low > high:
        raise ValueError(f"low ({low}) must not exceed high ({high})")
    return max(low, min(high, value))
