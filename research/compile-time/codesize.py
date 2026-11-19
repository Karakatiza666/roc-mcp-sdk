import subprocess, sys
for f in sys.argv[1:]:
    out = subprocess.run(["nm", "-S", "--size-sort", f], capture_output=True, text=True).stdout.split("\n")
    sizes = [int(l.split()[1], 16) for l in out if "roc__p" in l]
    sizes.sort(reverse=True)
    print(f, "procs", len(sizes), "bytes", sum(sizes), "top10", [s // 1024 for s in sizes[:10]], "KB")
