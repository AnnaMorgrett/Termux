# Test helper: simulates a filesystem/platform without file locking (Android shared storage).
# With PYTHONPATH pointing here, "import fcntl" fails in every Python process.
import sys
sys.modules["fcntl"] = None
