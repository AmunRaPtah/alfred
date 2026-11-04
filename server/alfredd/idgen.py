import random
import string

ALPHABET = string.ascii_lowercase + string.digits


def new_id(n: int = 8) -> str:
    return "".join(random.choice(ALPHABET) for _ in range(n))
