import unittest
from factorial import factorial

class TestFactorial(unittest.TestCase):
    def test_zero(self):
        self.assertEqual(factorial(0), 1)

    def test_one(self):
        self.assertEqual(factorial(1), 1)

    def test_small_numbers(self):
        self.assertEqual(factorial(5), 120)
        self.assertEqual(factorial(3), 6)

    def test_large_number(self):
        self.assertEqual(factorial(10), 3628800)

    def test_negative(self):
        with self.assertRaises(ValueError):
            factorial(-1)

if __name__ == "__main__":
    unittest.main()
