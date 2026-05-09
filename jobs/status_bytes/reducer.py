import sys

def main():
    current_key = None
    count = 0
    bytes_sum = 0
    for line in sys.stdin:
        key, cnt, b = line.rstrip('\n').split('\t', 2)
        if key == current_key:
            count += int(cnt)
            bytes_sum += int(b)
        else:
            if current_key is not None:
                print(f"{current_key}\t{count}\t{bytes_sum}")
            current_key = key
            count = int(cnt)
            bytes_sum = int(b)
    if current_key is not None:
        print(f"{current_key}\t{count}\t{bytes_sum}")

if __name__ == "__main__":
    main()
