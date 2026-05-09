import sys

# Input is sorted by key (Hadoop guarantee for combiner input).
def main():
    current_key = None
    total = 0
    for line in sys.stdin:
        key, val = line.rstrip('\n').split('\t', 1)
        if key == current_key:
            total += int(val)
        else:
            if current_key is not None:
                print(f"{current_key}\t{total}")
            current_key = key
            total = int(val)
    if current_key is not None:
        print(f"{current_key}\t{total}")

if __name__ == "__main__":
    main()
