import argparse

import ray


@ray.remote
def square(value: int) -> int:
    return value * value


def main() -> None:
    parser = argparse.ArgumentParser(description="Submit a simple Ray square job.")
    parser.add_argument("--count", type=int, default=10, help="How many integers to square.")
    args = parser.parse_args()

    ray.init(address="auto")
    results = ray.get([square.remote(i) for i in range(args.count)])
    print("Ray demo results:", results)


if __name__ == "__main__":
    main()
