"""Run tests and audit after security fixes."""
import subprocess, sys, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))

out = os.path.join(os.path.dirname(__file__), "_security_test_results.txt")

with open(out, "w", encoding="utf-8") as f:
    # 1. Import check
    f.write("=== IMPORT CHECK ===\n")
    try:
        sys.path.insert(0, os.path.dirname(__file__))
        from routers.dispatch import router as dr
        f.write("dispatch router: OK\n")
    except Exception as e:
        f.write(f"dispatch router: FAIL - {e}\n")
    try:
        from routers.misc import router as mr
        f.write("misc router: OK\n")
    except Exception as e:
        f.write(f"misc router: FAIL - {e}\n")
    try:
        from firestore_sync import sync_client, sync_driver
        f.write("firestore_sync: OK\n")
    except Exception as e:
        f.write(f"firestore_sync: FAIL - {e}\n")

    # 2. pytest
    f.write("\n=== PYTEST ===\n")
    f.flush()
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/", "-q", "--tb=short"],
        capture_output=True, text=True, cwd=os.path.dirname(__file__),
        timeout=120,
    )
    f.write(result.stdout)
    if result.stderr:
        f.write(result.stderr)
    f.write(f"\nReturn code: {result.returncode}\n")

    # 3. Audit
    f.write("\n=== AUDIT ===\n")
    f.flush()
    audit_script = os.path.join(os.path.dirname(__file__), "_audit2.py")
    if os.path.exists(audit_script):
        result2 = subprocess.run(
            [sys.executable, audit_script],
            capture_output=True, text=True, cwd=os.path.dirname(__file__),
            timeout=60,
        )
        f.write(result2.stdout)
        if result2.stderr:
            f.write(result2.stderr)
        f.write(f"\nReturn code: {result2.returncode}\n")
    else:
        f.write("_audit2.py not found\n")

f.write("\nDONE\n")
print(f"Results written to {out}")
