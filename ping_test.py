#!/usr/bin/env python3
import subprocess
host = input("Host to ping: ")
result = subprocess.run(["ping", "-c", "4", host])
print("Reachable" if result.returncode == 0 else "Unreachable")
