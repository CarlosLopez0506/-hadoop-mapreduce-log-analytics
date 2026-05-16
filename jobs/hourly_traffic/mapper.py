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
        timestamp = m.group(2)  # e.g. "01/Jul/1995:00:00:01 -0400"
        try:
            hour = timestamp.split(':')[1]  # "00" to "23"
            if not (0 <= int(hour) <= 23):
                raise ValueError
            # zero-pad to ensure lexicographic sort works correctly
            print(f"{int(hour):02d}\t1")
        except (ValueError, IndexError):
            print("reporter:counter:nasa,bad_hour,1", file=sys.stderr)

if __name__ == "__main__":
    sys.stdin = open(sys.stdin.fileno(), encoding="utf-8", errors="replace")
    main()
