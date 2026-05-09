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
        path = m.group(4)
        if path is None:
            print("reporter:counter:nasa,unparsed_request,1", file=sys.stderr)
            continue
        print(f"{path}\t1")

if __name__ == "__main__":
    sys.stdin = open(sys.stdin.fileno(), encoding="utf-8", errors="replace")
    main()
