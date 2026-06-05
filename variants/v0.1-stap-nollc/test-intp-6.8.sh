#!/bin/bash
# Test script for intp-6.8.stp

echo "Testing IntP 6.8.0 patched version..."
echo "This will run a quick syntax check first"

# Syntax check
sudo stap -p2 intp-6.8.stp firefox
if [ $? -ne 0 ]; then
    echo "ERROR: Syntax check failed"
    exit 1
fi

echo ""
echo "Syntax check passed!"
echo ""
echo "Now attempting compilation (this will take a moment)..."

# Try to compile (pass 4)
timeout 60 sudo stap -p4 intp-6.8.stp firefox
if [ $? -ne 0 ]; then
    echo "ERROR: Compilation failed"
    exit 1
fi

echo ""
echo "SUCCESS: IntP 6.8.0 patched version compiles correctly!"
echo ""
echo "To run IntP monitoring, use:"
echo "  Terminal 1: sudo stap --suppress-handler-errors -g intp-6.8.stp firefox"
echo "  Terminal 2: watch -n2 -d cat /proc/systemtap/stap_*/intestbench"
