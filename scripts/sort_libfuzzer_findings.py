import os
import sys
from pathlib import Path

def sort_and_rename_files(path):
    # Get all files in directory
    files = []
    for f in os.listdir(path):
        full_path = os.path.join(path, f)
        if os.path.isfile(full_path):
            # Get creation timestamp and original name
            ts = os.path.getctime(full_path)
            files.append((ts, f, full_path))
            
    if not files:
        return
        
    # Sort by timestamp
    files.sort(key=lambda x: x[0])
    
    # Get minimum timestamp for relative offset
    min_ts = files[0][0]
    
    # Rename files with new format
    for idx, (ts, orig_name, full_path) in enumerate(files):
        rel_ts = int(ts - min_ts)
        new_name = f"id:{idx},ts:{rel_ts},{orig_name}"
        new_path = os.path.join(path, new_name)
        os.rename(full_path, new_path)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Please provide the path as first argument")
        sys.exit(1)
        
    sort_and_rename_files(sys.argv[1])
