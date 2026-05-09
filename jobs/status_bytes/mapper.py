import re
import sys

LINE_RE = re.compile(
    r'^(\S+) \S+ \S+ \[([^\]]+)\] '
    r'"(?:(\S+) (\S+)(?: (\S+))?|[^"]*)" '
    r'(\d{3}|-) (\d+|-)$'
)

def main():
    for line in sys.stdin:
        line = line.rstrip('\n')
        m = LINE_RE.match(line)
        if not m:
            print("reporter:counter:nasa,malformed_line,1", file=sys.stderr)
            continue
        status = m.group(6)
        bytes_field = m.group(7)
        byte_count = int(bytes_field) if bytes_field != "-" else 0
        print(f"{status}\t1\t{byte_count}")

if __name__ == "__main__":
    sys.stdin = open(sys.stdin.fileno(), encoding="utf-8", errors="replace")
    main()
