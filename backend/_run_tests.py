"""Run pytest and write results to file."""
import subprocess
import sys

result = subprocess.run(
    [sys.executable, "-m", "pytest", "backend/tests/", "-q", "--tb=line"],
    cwd=r"c:\Users\Puma\cruiseapp.2",
    capture_output=True,
    text=True,
    timeout=120,
)
output = result.stdout + result.stderr
with open(r"c:\Users\Puma\cruiseapp.2\backend\_test_results.txt", "w", encoding="utf-8") as f:
    f.write(output)
print(output[-3000:] if len(output) > 3000 else output)
