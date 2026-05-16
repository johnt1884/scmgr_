import os
import sys
import subprocess
import json
import concurrent.futures
import shutil
import re
import hashlib
from datetime import datetime, timezone

VIDEO_EXTENSIONS = ('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm')
IMAGE_EXTENSIONS = ('.jpg', '.jpeg', '.png', '.webp', '.JPG', '.JPEG', '.PNG', '.WEBP')
ROTATION_LUA_PATH = r"C:\Bridge\misc\tools\mpv-x86_64-v3-20260418-git-4377cce\portable_config\scripts\autorotate.lua"

LANDSCAPE_TARGET_WIDTH = 342
PORTRAIT_TARGET_WIDTH = 192
TARGET_HEIGHT = 256
FLIP_LUA_PATH = r"C:\Bridge\misc\tools\mpv-x86_64-v3-20260418-git-4377cce\portable_config\scripts\flip.lua"

def get_projects(base_path):
    return [d for d in os.listdir(base_path) if os.path.isdir(os.path.join(base_path, d)) and not d.startswith('.')]

def find_videos(project_path):
    videos = []
    skip_dirs = {'thumbnails', 'edit thumbnails'}
    for root, dirs, files in os.walk(project_path):
        dirs[:] = [d for d in dirs if d.lower() not in skip_dirs]
        for file in files:
            if file.lower().endswith(VIDEO_EXTENSIONS):
                videos.append(os.path.join(root, file))
    return videos

def check_thumbnails_optimized(video_path, project_path, thumb_files, edit_files):
    video_name = os.path.splitext(os.path.basename(video_path))[0]
    
    main_found_file = None
    for ext in IMAGE_EXTENSIONS:
        f = video_name + ext
        if f in thumb_files:
            main_found_file = f
            break
            
    edit_found_files = []
    edit_indices_found = []
    for i in range(1, 11):
        for ext in IMAGE_EXTENSIONS:
            f = f"{video_name}_{i}{ext}"
            if f in edit_files:
                edit_found_files.append(f)
                edit_indices_found.append(i)
                break
                
    return main_found_file, edit_indices_found, edit_found_files

def get_video_info(video_path):
    """Get total frames, fps, and dimensions using ffprobe."""
    cmd = [
        'ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=nb_frames,avg_frame_rate,width,height',
        '-of', 'json', video_path
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        stream = data.get('streams', [{}])[0]
        
        fps = 25.0
        avg_frame_rate = stream.get('avg_frame_rate', '25/1')
        if '/' in avg_frame_rate:
            num, den = map(int, avg_frame_rate.split('/'))
            if den != 0: fps = num / den
        else:
            fps = float(avg_frame_rate)
            
        nb_frames = int(stream.get('nb_frames', 0))
        if nb_frames == 0:
            # Fallback for some formats: try to calculate from duration
            cmd_dur = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', video_path]
            res_dur = subprocess.run(cmd_dur, capture_output=True, text=True, check=True)
            dur = float(json.loads(res_dur.stdout).get('format', {}).get('duration', 0))
            nb_frames = int(dur * fps)
            
        width = int(stream.get('width', 0))
        height = int(stream.get('height', 0))
        
        return nb_frames, fps, width, height
    except Exception:
        return 0, 25.0, 0, 0

def get_md5(path):
    if not os.path.exists(path): return None
    hash_md5 = hashlib.md5()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(4096), b""):
                hash_md5.update(chunk)
        return hash_md5.hexdigest().upper()
    except Exception:
        return None

def get_image_dimensions(image_path):
    """Get width and height of an image using ffprobe."""
    cmd = [
        'ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height',
        '-of', 'json', image_path
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        stream = data.get('streams', [{}])[0]
        return int(stream.get('width', 0)), int(stream.get('height', 0))
    except Exception:
        return 0, 0

def get_crop_params(video_path, nb_frames):
    """Detect crop parameters (removing black borders) using ffmpeg cropdetect."""
    if nb_frames <= 0:
        return None
    
    # We'll take a few samples: 20%, 50%, 80%
    samples = [int(nb_frames * 0.2), int(nb_frames * 0.5), int(nb_frames * 0.8)]
    crops = []
    
    for frame_idx in samples:
        cmd = [
            'ffmpeg', '-y', '-i', video_path,
            '-vf', f"select='eq(n,{frame_idx})',cropdetect=limit=24:round=2",
            '-frames:v', '1', '-f', 'null', '-'
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            match = re.search(r"crop=(\d+:\d+:\d+:\d+)", result.stderr)
            if match:
                crops.append(match.group(1))
        except Exception:
            continue
            
    if not crops:
        return None
        
    # Return the most common one
    return max(set(crops), key=crops.count)

def has_black_borders(image_path):
    """Check if an image has black borders using cropdetect."""
    w_orig, h_orig = get_image_dimensions(image_path)
    if w_orig == 0: return False
    
    cmd = [
        'ffmpeg', '-y', '-i', image_path,
        '-vf', 'cropdetect=limit=24:round=2',
        '-frames:v', '1', '-f', 'null', '-'
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        match = re.search(r"crop=(\d+):(\d+):(\d+):(\d+)", result.stderr)
        if match:
            w, h, x, y = map(int, match.groups())
            if w < w_orig or h < h_orig:
                return True
    except Exception:
        pass
    return False

def generate_video_thumbnails(task):
    """Worker function using FFmpeg processes with dimension logic."""
    video_path, project_path, gen_main, missing_edits, *rest = task
    force_ideal = rest[0] if rest else False
    video_name = os.path.splitext(os.path.basename(video_path))[0]
    
    nb_frames, fps, v_width, v_height = get_video_info(video_path)
    if nb_frames <= 0:
        return video_path, False

    thumb_dir = os.path.join(project_path, 'Thumbnails')
    edit_dir = os.path.join(project_path, 'Edit Thumbnails')
    
    # Pre-calculate target frames for all 11 slots (Main + 10 Edits)
    all_target_frames = [min(1, nb_frames - 1)] # Slot 0: Main
    start_idx = 1
    end_idx = max(1, nb_frames - 2)
    step = (end_idx - start_idx) / 9
    for i in range(10):
        all_target_frames.append(int(start_idx + i * step)) # Slots 1-10: Edits

    # Determine which slots need generation
    slots_to_generate = []
    if gen_main:
        slots_to_generate.append(0)
    for i in missing_edits:
        slots_to_generate.append(i)
    
    if not slots_to_generate:
        return video_path, True

    # Identify existing images for dimension matching
    existing_images = {} # slot_index -> (path, width, height)
    
    # Check for main thumbnail
    if not gen_main:
        for ext in IMAGE_EXTENSIONS:
            main_path = os.path.join(thumb_dir, f"{video_name}{ext}")
            if os.path.exists(main_path):
                w, h = get_image_dimensions(main_path)
                if w > 0:
                    existing_images[0] = (main_path, w, h)
                    break
    
    # Check for edit thumbnails
    for i in range(1, 11):
        if i not in missing_edits:
            for ext in IMAGE_EXTENSIONS:
                edit_path = os.path.join(edit_dir, f"{video_name}_{i}{ext}")
                if os.path.exists(edit_path):
                    w, h = get_image_dimensions(edit_path)
                    if w > 0:
                        existing_images[i] = (edit_path, w, h)
                        break

    # Detect crop parameters
    crop_str = get_crop_params(video_path, nb_frames)
    if crop_str:
        # Extract width and height from crop_str "w:h:x:y"
        cw, ch, cx, cy = map(int, crop_str.split(':'))
        is_landscape = cw >= ch
    else:
        cw, ch = v_width, v_height
        is_landscape = v_width >= v_height

    # Determine target dimensions for each missing slot
    target_dims = {} # slot_index -> (w, h)
    
    # Default targets if ALL images are missing
    if is_landscape:
        default_max_w, default_max_h = LANDSCAPE_TARGET_WIDTH, TARGET_HEIGHT
    else:
        default_max_w, default_max_h = PORTRAIT_TARGET_WIDTH, TARGET_HEIGHT

    for slot in slots_to_generate:
        # Deep Scan fallback: if we are fixing wrong dimensions, use the ideal target
        if force_ideal:
            if cw > 0 and ch > 0:
                scale = min(default_max_w / cw, default_max_h / ch)
                target_dims[slot] = (int(cw * scale), int(ch * scale))
            else:
                target_dims[slot] = (default_max_w, default_max_h)
            continue

        # Rule: Use dimensions of the preceding image present in the series
        found_preceding = False
        for prev_slot in range(slot - 1, -1, -1):
            if prev_slot in existing_images:
                target_dims[slot] = (existing_images[prev_slot][1], existing_images[prev_slot][2])
                found_preceding = True
                break
        
        if not found_preceding:
            # Check if ANY image is present for this video to determine if "all are missing"
            if not existing_images:
                # ALL missing: use target dimensions whilst maintaining aspect ratio
                # We need to scale video dimensions to fit into default_w x default_h
                # whilst keeping aspect ratio.
                if cw > 0 and ch > 0:
                    scale = min(default_max_w / cw, default_max_h / ch)
                    target_dims[slot] = (int(cw * scale), int(ch * scale))
                else:
                    target_dims[slot] = (default_max_w, default_max_h)
            else:
                # Some are present, but none preceding. 
                # Requirement says "same dimensions as the preceeding images present"
                # If no preceding, and some are present, it's ambiguous. 
                # Let's use the first available one to be consistent with the "series"
                first_available_slot = min(existing_images.keys())
                target_dims[slot] = (existing_images[first_available_slot][1], existing_images[first_available_slot][2])

    # Group by dimensions to minimize FFmpeg calls
    groups = {} # (w, h) -> [slots]
    for slot, dims in target_dims.items():
        if dims not in groups: groups[dims] = []
        groups[dims].append(slot)

    success = True
    try:
        for (tw, th), slots in groups.items():
            unique_frames = sorted(list(set(all_target_frames[s] for s in slots)))
            select_str = " + ".join([f"eq(n,{idx})" for idx in unique_frames])
            # Use crop and scale filter to match target dimensions
            filter_parts = [f"select='{select_str}'"]
            if crop_str:
                filter_parts.append(f"crop={crop_str}")
            filter_parts.append(f"scale={tw}:{th}")
            filter_parts.append("setpts=N/FRAME_RATE/TB")
            
            filter_graph = ",".join(filter_parts)
            
            temp_pattern = os.path.join(project_path, f"tmp_{video_name}_{tw}_{th}_%d.jpg")
            cmd = [
                'ffmpeg', '-y', '-threads', '1', '-i', video_path,
                '-vf', filter_graph, '-vsync', 'vfr', '-q:v', '2',
                temp_pattern
            ]
            
            if subprocess.run(cmd, capture_output=True).returncode != 0:
                success = False
                continue

            # Move/Rename
            os.makedirs(thumb_dir, exist_ok=True)
            os.makedirs(edit_dir, exist_ok=True)
            
            for slot in slots:
                frame_idx = all_target_frames[slot]
                out_idx = unique_frames.index(frame_idx) + 1
                src = temp_pattern % out_idx
                if slot == 0:
                    dst = os.path.join(thumb_dir, f"{video_name}.jpg")
                else:
                    dst = os.path.join(edit_dir, f"{video_name}_{slot}.jpg")
                shutil.copy2(src, dst)
            
            # Cleanup
            for i in range(1, len(unique_frames) + 1):
                p = temp_pattern % i
                if os.path.exists(p):
                    try:
                        os.remove(p)
                    except Exception:
                        pass
        
        # Fallback for slot 10 if it failed to generate
        if 10 in missing_edits:
            slot_10_path = os.path.join(edit_dir, f"{video_name}_10.jpg")
            if not os.path.exists(slot_10_path):
                # Try to extract the very last possible frame
                tw, th = target_dims[10]
                
                # Build fallback filter
                fallback_filter = []
                if crop_str:
                    fallback_filter.append(f"crop={crop_str}")
                fallback_filter.append(f"scale={tw}:{th}")
                fallback_filter_str = ",".join(fallback_filter)

                # Using -sseof -1 allows seeking to 1 second before end
                cmd_fallback = [
                    'ffmpeg', '-y', '-sseof', '-1', '-i', video_path,
                    '-vf', fallback_filter_str, '-update', '1', '-frames:v', '1', '-q:v', '2',
                    slot_10_path
                ]
                if subprocess.run(cmd_fallback, capture_output=True).returncode != 0:
                    # If -sseof -1 fails (e.g. video < 1s), try without seeking
                    cmd_fallback_no_seek = [
                        'ffmpeg', '-y', '-i', video_path,
                        '-vf', fallback_filter_str, '-frames:v', '1', '-q:v', '2',
                        slot_10_path
                    ]
                    subprocess.run(cmd_fallback_no_seek, capture_output=True)

        return video_path, success
    except Exception:
        return video_path, False

def is_shortcut(path):
    if os.path.islink(path): return True
    if path.lower().endswith('.lnk'): return True
    return False

def get_shortcut_target(path):
    if os.path.islink(path):
        return os.readlink(path)
    if path.lower().endswith('.lnk'):
        # On Windows, use PowerShell to get target. In this environment, it's limited.
        # But we'll implement it for the user's environment.
        if os.name == 'nt':
            cmd = ['powershell', '-Command', f"(New-Object -ComObject WScript.Shell).CreateShortcut('{path}').TargetPath"]
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, check=True)
                return result.stdout.strip()
            except Exception: return None
    return None

def update_shortcut(path, new_target):
    try:
        if os.path.islink(path):
            os.remove(path)
            os.symlink(new_target, path)
            return True
        if path.lower().endswith('.lnk') and os.name == 'nt':
            cmd = ['powershell', '-Command', f"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{path}');$s.TargetPath='{new_target}';$s.Save()"]
            subprocess.run(cmd, check=True)
            return True
    except Exception as e:
        print(f"Error updating shortcut {path}: {e}")
    return False

def update_sc_date():
    print("\nUpdating scdate.txt files...")
    base_path = os.getcwd()
    root_sc = os.path.join(base_path, 'sc')
    cached = []
    if os.path.exists(root_sc):
        for f in os.listdir(root_sc):
            if f.lower().endswith('.lnk'):
                p = os.path.join(root_sc, f)
                target = get_shortcut_target(p)
                if target:
                    mtime = os.path.getmtime(p)
                    cached.append({'target': target, 'date': datetime.fromtimestamp(mtime, timezone.utc).replace(tzinfo=None)})

    target_dirs = {base_path}
    for root, dirs, files in os.walk(base_path):
        if 'sc' in dirs:
            target_dirs.add(root)

    for d in os.listdir(base_path):
        dp = os.path.join(base_path, d)
        if os.path.isdir(dp) and d.lower() not in ('sc', 'landscape', 'landscape rotate', 'edit', 'thumbnails', 'edit thumbnails'):
            target_dirs.add(dp)

    for directory in target_dirs:
        out_file = os.path.join(directory, 'scdate.txt')
        newest = datetime.min
        p_sc = os.path.join(directory, 'sc')
        if os.path.exists(p_sc):
            lnks = [os.path.join(p_sc, f) for f in os.listdir(p_sc) if f.lower().endswith('.lnk')]
            if lnks:
                latest_lnk = max(lnks, key=os.path.getmtime)
                newest = datetime.fromtimestamp(os.path.getmtime(latest_lnk), timezone.utc).replace(tzinfo=None)

        if directory != base_path:
            for c in cached:
                if c['target'].startswith(directory + os.sep) or c['target'] == directory:
                    if c['date'] > newest:
                        newest = c['date']

        if newest > datetime.min:
            write = True
            if os.path.exists(out_file):
                try:
                    with open(out_file, 'r') as f:
                        content = f.read().strip()
                        d_date_str = content
                        if content.startswith('dummy:'):
                            d_date_str = content[6:].strip()
                        # ISO format: yyyy-MM-ddTHH:mm:ss.fffZ
                        # Python's fromisoformat might need a little help with the Z
                        if d_date_str.endswith('Z'):
                            d_date_str = d_date_str[:-1] + '+00:00'
                        d_date = datetime.fromisoformat(d_date_str).replace(tzinfo=None)
                        if newest <= d_date:
                            write = False
                except Exception:
                    pass

            if write:
                iso_date = newest.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
                with open(out_file, 'w', encoding='utf-8') as f:
                    f.write(iso_date)

def update_sc_data():
    print("\nUpdating scdata.txt files...")
    base_path = os.getcwd()
    # Recursive sc folders
    for root, dirs, files in os.walk(base_path):
        if 'sc' in dirs:
            sc_path = os.path.join(root, 'sc')
            links = [f for f in os.listdir(sc_path) if f.lower().endswith('.lnk')]
            if links:
                out = os.path.join(root, 'scdata.txt')
                with open(out, 'w', encoding='utf-8') as f:
                    for l in sorted(links):
                        f.write(l + '\n')

    # Top-level ".\sc" (grouped target output)
    root_sc = os.path.join(base_path, 'sc')
    out = os.path.join(base_path, 'rootdata.txt')
    if os.path.exists(root_sc):
        groups = {}
        for f in os.listdir(root_sc):
            if f.lower().endswith('.lnk'):
                p = os.path.join(root_sc, f)
                t = get_shortcut_target(p)
                if t:
                    folder_path = os.path.dirname(t)
                    folder = os.path.basename(folder_path)
                    tag = '[ROOT]'
                    sub_sc = os.path.join(folder_path, 'sc')
                    if os.path.exists(os.path.join(sub_sc, f)):
                        tag = '[BOTH]'
                    if folder not in groups:
                        groups[folder] = []
                    groups[folder].append(f"{f} {tag}")

        if groups:
            with open(out, 'w', encoding='utf-8') as f:
                for folder in sorted(groups.keys()):
                    f.write(f'"{folder}"\n')
                    for entry in sorted(groups[folder]):
                        f.write(entry + '\n')
                    f.write('\n')
        elif os.path.exists(out):
            os.remove(out)
    elif os.path.exists(out):
        os.remove(out)

def generate_sc_new():
    print("\nGenerating scnew.txt...")
    base_path = os.getcwd()
    root_sc = os.path.join(base_path, 'sc')
    root_links_data = []
    if os.path.exists(root_sc):
        for f in os.listdir(root_sc):
            if f.lower().endswith('.lnk'):
                p = os.path.join(root_sc, f)
                t = get_shortcut_target(p)
                if t:
                    root_links_data.append({'path': p, 'target': t, 'mtime': os.path.getmtime(p)})

    for d in os.listdir(base_path):
        dp = os.path.join(base_path, d)
        if os.path.isdir(dp) and d != 'sc':
            proj_sc = os.path.join(dp, 'sc')
            scnew_file = os.path.join(dp, 'scnew.txt')

            if not os.path.exists(proj_sc):
                if os.path.exists(scnew_file): os.remove(scnew_file)
                continue

            proj_links = [os.path.join(proj_sc, f) for f in os.listdir(proj_sc) if f.lower().endswith('.lnk')]
            if not proj_links:
                if os.path.exists(scnew_file): os.remove(scnew_file)
                continue

            matching_root_links = [l for l in root_links_data if l['target'].lower().startswith(dp.lower() + os.sep) or l['target'].lower() == dp.lower()]

            new_links = []
            if not matching_root_links:
                new_links = sorted(proj_links, key=os.path.getmtime)
            else:
                cutoff = max(l['mtime'] for l in matching_root_links)
                new_links = [l for l in proj_links if os.path.getmtime(l) > cutoff]
                new_links.sort(key=os.path.getmtime)

            if new_links:
                with open(scnew_file, 'w', encoding='utf-8') as f:
                    for l in new_links:
                        f.write(os.path.basename(l) + '\n')
            else:
                if os.path.exists(scnew_file): os.remove(scnew_file)

def update_selections():
    print("\nUpdating selections.txt files...")
    base_path = os.getcwd()
    special_folders = {'sc', 'landscape', 'landscape rotate', 'edit', 'thumbnails', 'edit thumbnails'}

    for d in os.listdir(base_path):
        dp = os.path.join(base_path, d)
        if os.path.isdir(dp) and d.lower() not in special_folders:
            print(f"Processing folder: {d}")
            out = os.path.join(dp, 'selections.txt')
            with open(out, 'w', encoding='utf-8') as f:
                for sub in ["sc", "Landscape", "Landscape Rotate", "Edit"]:
                    f.write(f"# {sub}\n")
                    sub_path = os.path.join(dp, sub)
                    if os.path.exists(sub_path):
                        items = sorted(os.listdir(sub_path))
                        for item in items:
                            if os.path.isfile(os.path.join(sub_path, item)):
                                f.write(item + '\n')
                    f.write("\n")

def update_shortcut_database():
    print("\nUpdating Shortcut Database...")
    base_path = os.getcwd()
    db_file = "shortcut_db.txt"
    database = []
    if os.path.exists(db_file):
        with open(db_file, 'r') as f:
            current_entry = {}
            for line in f:
                line = line.strip()
                if line.startswith('Folder path: '): current_entry['FolderPath'] = line[13:]
                elif line.startswith('Shortcut: '): current_entry['ShortcutName'] = line[10:]
                elif line.startswith('Shortcut Video Path: '): current_entry['VideoPath'] = line[21:]
                elif line.startswith('Shortcut md5: '): current_entry['MD5'] = line[14:]
                elif line == '---':
                    if 'FolderPath' in current_entry: database.append(current_entry)
                    current_entry = {}

    new_database = []
    for root, dirs, files in os.walk(base_path):
        for file in files:
            if file.lower().endswith('.lnk'):
                lnk_path = os.path.join(root, file)
                target = get_shortcut_target(lnk_path)
                if not target: continue

                if not target.lower().endswith(VIDEO_EXTENSIONS): continue

                existing = next((e for e in database if e['FolderPath'] == root and e['ShortcutName'] == file), None)
                if existing:
                    if os.path.exists(target):
                        existing['VideoPath'] = target
                        existing['MD5'] = get_md5(target)
                    new_database.append(existing)
                else:
                    if os.path.exists(target):
                        md5 = get_md5(target)
                        new_database.append({
                            'FolderPath': root,
                            'ShortcutName': file,
                            'VideoPath': target,
                            'MD5': md5
                        })
                        print(f"Added: {file}")

    with open(db_file, 'w', encoding='utf-8') as f:
        for entry in new_database:
            f.write(f"Folder path: {entry['FolderPath']}\n")
            f.write(f"Shortcut: {entry['ShortcutName']}\n")
            f.write(f"Shortcut Video Path: {entry['VideoPath']}\n")
            f.write(f"Shortcut md5: {entry['MD5']}\n")
            f.write("---\n")
    print(f"Database updated. Total entries: {len(new_database)}")

def scan_broken_shortcuts_from_db():
    print("\nScanning for broken shortcuts...")
    db_file = "shortcut_db.txt"
    if not os.path.exists(db_file):
        print("Shortcut database not found. Please run 'Update shortcut Database' first.")
        return

    database = []
    with open(db_file, 'r') as f:
        current_entry = {}
        for line in f:
            line = line.strip()
            if line.startswith('Folder path: '): current_entry['FolderPath'] = line[13:]
            elif line.startswith('Shortcut: '): current_entry['ShortcutName'] = line[10:]
            elif line.startswith('Shortcut Video Path: '): current_entry['VideoPath'] = line[21:]
            elif line.startswith('Shortcut md5: '): current_entry['MD5'] = line[14:]
            elif line == '---':
                if 'FolderPath' in current_entry: database.append(current_entry)
                current_entry = {}

    for entry in database:
        lnk_path = os.path.join(entry['FolderPath'], entry['ShortcutName'])
        if not os.path.exists(lnk_path): continue

        target = get_shortcut_target(lnk_path)
        if target and os.path.exists(target): continue

        print(f"\nBroken Shortcut found: {entry['ShortcutName']} in {entry['FolderPath']}")
        print(f"Original Target: {entry['VideoPath']}")

        original_dir = os.path.dirname(entry['VideoPath'])
        if os.path.exists(original_dir):
            print(f"Searching for matching file in: {original_dir}")
            found_match = None
            for f in os.listdir(original_dir):
                f_path = os.path.join(original_dir, f)
                if os.path.isfile(f_path) and f.lower().endswith(VIDEO_EXTENSIONS):
                    if get_md5(f_path) == entry['MD5']:
                        found_match = f_path
                        break

            if found_match:
                print(f"Match found! New file name: {os.path.basename(found_match)}")
                if input("Repair shortcut? (y/n): ").lower() == 'y':
                    if update_shortcut(lnk_path, found_match):
                        print("Shortcut repaired.")
            else:
                print("No matching file found by MD5 in the original directory.")
        else:
            print(f"Original target directory no longer exists: {original_dir}")

def run_shortcut_manager_menu():
    while True:
        print("\n--- Shortcut Manager ---")
        print("1. Update shortcut Database")
        print("2. Scan for broken Shortcuts")
        print("3. Back")
        choice = input("\nSelect an option: ")
        if choice == '1': update_shortcut_database()
        elif choice == '2': scan_broken_shortcuts_from_db()
        elif choice == '3': break
        else: print("Invalid choice.")

def run_broken_shortcuts_scan(generate_report=False):
    base_path = os.getcwd()
    projects = get_projects(base_path)
    broken_shortcuts = [] # list of (shortcut_path, current_target)

    def scan_dir_for_shortcuts(directory):
        if not os.path.isdir(directory): return
        for f in os.listdir(directory):
            p = os.path.join(directory, f)
            if is_shortcut(p):
                target = get_shortcut_target(p)
                if not target or not os.path.exists(target):
                    broken_shortcuts.append((p, target))

    print("\nScanning for broken shortcuts...")
    # Scan root
    scan_dir_for_shortcuts(base_path)
    # Scan each project's 'sc' folder
    for project in projects:
        scan_dir_for_shortcuts(os.path.join(base_path, project, 'sc'))

    if not broken_shortcuts:
        print("No broken shortcuts found.")
        return

    print(f"Found {len(broken_shortcuts)} broken shortcuts.")

    print("\nBroken Shortcuts:")
    for p, t in broken_shortcuts:
        print(f"  - {os.path.relpath(p, base_path)} -> {t}")

    if generate_report:
        with open('broken_shortcuts_report.txt', 'w', encoding='utf-8') as f:
            f.write(f"BROKEN SHORTCUTS REPORT - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write("========================================================\n\n")
            for p, t in broken_shortcuts:
                f.write(f"{p} -> {t}\n")
        print("broken_shortcuts_report.txt generated.")

    if input("\nWould you like to search for correct paths? (y/n): ").lower() == 'y':
        print("\nSearching for correct paths...")
        # Collect all videos from all projects once
        all_videos = []
        for project in projects:
            all_videos.extend(find_videos(os.path.join(base_path, project)))
        
        # filename -> [full_paths]
        video_map = {}
        for v in all_videos:
            name = os.path.basename(v)
            if name not in video_map: video_map[name] = []
            video_map[name].append(v)

        for p, t in broken_shortcuts:
            # Shortcut name (without extension if it's .lnk)
            sc_name = os.path.basename(p)
            if sc_name.lower().endswith('.lnk'):
                # Try both the name with and without .lnk if needed, 
                # but usually shortcut matches filename or filename.lnk
                # We'll use the base filename part for matching.
                search_name = os.path.splitext(sc_name)[0]
            else:
                search_name = sc_name
            
            matches = []
            # Exact match for search_name in video names
            for v_name, paths in video_map.items():
                if v_name == search_name or os.path.splitext(v_name)[0] == search_name:
                    matches.extend(paths)
            
            if matches:
                print(f"\nBroken shortcut: {os.path.relpath(p, base_path)}")
                print(f"Current invalid target: {t}")
                print("Found matching video(s):")
                for i, match in enumerate(matches):
                    print(f"  {i+1}. {os.path.relpath(match, base_path)}")
                
                choice = input("Enter number to fix shortcut, or 's' to skip: ")
                if choice.isdigit() and 1 <= int(choice) <= len(matches):
                    new_target = matches[int(choice)-1]
                    if update_shortcut(p, new_target):
                        print("Shortcut updated successfully.")
                else:
                    print("Skipped.")
            else:
                print(f"\nNo matches found for broken shortcut: {os.path.relpath(p, base_path)}")

def run_empty_video_scan(generate_report=False):
    base_path = os.getcwd()
    projects = get_projects(base_path)
    empty_videos = []
    
    print("\nScanning for empty videos (< 2KB)...")
    for project in projects:
        project_path = os.path.join(base_path, project)
        videos = find_videos(project_path)
        for video in videos:
            try:
                if os.path.getsize(video) < 2048:
                    empty_videos.append(video)
            except OSError:
                continue

    if not empty_videos:
        print("No empty videos found.")
        return

    print(f"Found {len(empty_videos)} empty videos.")
    
    print("\nEmpty Videos:")
    for v in empty_videos:
        print(f"  - {os.path.relpath(v, base_path)}")
            
    if generate_report:
        with open('empty_videos_report.txt', 'w', encoding='utf-8') as f:
            f.write(f"EMPTY VIDEOS REPORT - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write("========================================================\n\n")
            for v in empty_videos:
                f.write(f"{v}\n")
        print("empty_videos_report.txt generated.")

    if input("\nWould you like to delete these empty videos? (y/n): ").lower() == 'y':
        deleted_count = 0
        for v in empty_videos:
            try:
                os.remove(v)
                deleted_count += 1
            except Exception as e:
                print(f"Error deleting {v}: {e}")
        print(f"Deleted {deleted_count} empty videos.")

def run_rotation_and_flip_scan():
    base_path = os.getcwd()
    projects = sorted(get_projects(base_path))
    
    all_rotation_entries = {} # project_name -> {filename: degree}
    all_flip_entries = {} # project_name -> {filename: 'hflip'}
    
    def clean_filename(fname):
        return fname.replace('\ufeff', '').strip()

    print("\nScanning projects for rotation and flip data...")
    for project in projects:
        project_path = os.path.join(base_path, project)
        rotation_file = os.path.join(project_path, 'rotation_data.txt')
        if os.path.exists(rotation_file):
            rot_entries = {}
            flip_entries = {}
            with open(rotation_file, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    line = line.strip()
                    if not line or ':' not in line: continue
                    
                    parts = line.split(':')
                    filename = clean_filename(parts[0])
                    try:
                        degree = int(parts[1])
                        if degree != 0:
                            rot_entries[filename] = degree
                        
                        if len(parts) > 2 and parts[2].strip().lower() == 'flip':
                            flip_entries[filename] = 'hflip'
                    except (ValueError, IndexError):
                        continue
            if rot_entries:
                all_rotation_entries[project] = rot_entries
            if flip_entries:
                all_flip_entries[project] = flip_entries

    # --- Rotation Verification ---
    lua_rot_dict = {}
    actual_rot_list = []
    if os.path.exists(ROTATION_LUA_PATH):
        with open(ROTATION_LUA_PATH, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            matches = re.findall(r"\['(.+?)'\]\s*=\s*(\d+)", content)
            for fname, deg in matches:
                clean_name = clean_filename(fname.rstrip(':'))
                lua_rot_dict[clean_name] = int(deg)
                actual_rot_list.append((clean_name, int(deg)))

    missing_rot = []
    incorrect_rot = []
    expected_rot_list = []
    for project in sorted(all_rotation_entries.keys()):
        for filename, degree in sorted(all_rotation_entries[project].items()):
            expected_rot_list.append((filename, degree))
            if filename not in lua_rot_dict:
                missing_rot.append((project, filename, degree))
            elif lua_rot_dict[filename] != degree:
                incorrect_rot.append((project, filename, degree, lua_rot_dict[filename]))

    is_rot_unsorted = actual_rot_list != expected_rot_list

    # --- Flip Verification ---
    lua_flip_dict = {}
    actual_flip_list = []
    if os.path.exists(FLIP_LUA_PATH):
        with open(FLIP_LUA_PATH, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            matches = re.findall(r"\['(.+?)'\]\s*=\s*'(.+?)'", content)
            for fname, val in matches:
                clean_name = clean_filename(fname)
                lua_flip_dict[clean_name] = val
                actual_flip_list.append((clean_name, val))

    missing_flip = []
    incorrect_flip = []
    expected_flip_list = []
    for project in sorted(all_flip_entries.keys()):
        for filename, val in sorted(all_flip_entries[project].items()):
            expected_flip_list.append((filename, val))
            if filename not in lua_flip_dict:
                missing_flip.append((project, filename, val))
            elif lua_flip_dict[filename] != val:
                incorrect_flip.append((project, filename, val, lua_flip_dict[filename]))

    is_flip_unsorted = actual_flip_list != expected_flip_list

    # --- Reporting ---
    print("\nVerification Results:")
    print("=====================")
    
    issues_found = missing_rot or incorrect_rot or is_rot_unsorted or missing_flip or incorrect_flip or is_flip_unsorted
    if not issues_found:
        print("No issues found. Rotation and flip data are up to date and sorted.")
        return

    if missing_rot:
        print(f"\nMissing Rotation Entries ({len(missing_rot)}):")
        for proj, fname, deg in missing_rot: print(f"  [{proj}] {fname}:{deg}")
    if incorrect_rot:
        print(f"\nIncorrect Rotation Degrees ({len(incorrect_rot)}):")
        for proj, fname, exp, act in incorrect_rot: print(f"  [{proj}] {fname}: Expected {exp}, Found {act}")
    if is_rot_unsorted:
        print("\nUnsorted or Extra Rotation Entries Detected in autorotate.lua.")

    if missing_flip:
        print(f"\nMissing Flip Entries ({len(missing_flip)}):")
        for proj, fname, val in missing_flip: print(f"  [{proj}] {fname}:{val}")
    if incorrect_flip:
        print(f"\nIncorrect Flip Values ({len(incorrect_flip)}):")
        for proj, fname, exp, act in incorrect_flip: print(f"  [{proj}] {fname}: Expected {exp}, Found {act}")
    if is_flip_unsorted:
        print("\nUnsorted or Extra Flip Entries Detected in flip.lua.")

    if input("\nWould you like to fix these issues? (y/n): ").lower() == 'y':
        # Fix Rotation
        new_rot_content = "local rotations = {\n"
        for project in sorted(all_rotation_entries.keys()):
            new_rot_content += f"    -- {project}\n"
            for filename in sorted(all_rotation_entries[project].keys()):
                degree = all_rotation_entries[project][filename]
                new_rot_content += f"    ['{filename}'] = {degree},\n"
        new_rot_content += "}\n\n"
        new_rot_content += """mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path then return end

    mp.set_property("video-rotate", 0)

    local filename = path:match("([^/\\\\\\\\]+)$") or path

    if rotations[filename] then
        mp.set_property("video-rotate", rotations[filename])
    end
end)"""
        try:
            p = os.path.dirname(ROTATION_LUA_PATH)
            if p: os.makedirs(p, exist_ok=True)
            with open(ROTATION_LUA_PATH, 'w', encoding='utf-8') as f: f.write(new_rot_content)
            print(f"Updated: {ROTATION_LUA_PATH}")
        except Exception as e: print(f"Error updating rotation LUA: {e}")

        # Fix Flip
        new_flip_content = "local flips = {\n"
        for project in sorted(all_flip_entries.keys()):
            new_flip_content += f"    -- {project}\n"
            for filename in sorted(all_flip_entries[project].keys()):
                val = all_flip_entries[project][filename]
                new_flip_content += f"    ['{filename}'] = '{val}',\n"
        new_flip_content += "}\n\n"
        new_flip_content += """mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    local filename = path:match("^.+[\\\\\\\\/](.+)$") or path

    mp.command("vf remove @flip")

    if flips[filename] then
        local filter = flips[filename]
        mp.commandv("vf", "add", "@flip:" .. filter)
    end
end)"""
        try:
            p = os.path.dirname(FLIP_LUA_PATH)
            if p: os.makedirs(p, exist_ok=True)
            with open(FLIP_LUA_PATH, 'w', encoding='utf-8') as f: f.write(new_flip_content)
            print(f"Updated: {FLIP_LUA_PATH}")
        except Exception as e: print(f"Error updating flip LUA: {e}")

def run_normal_scan(deep_scan=False, generate_report=False):
    base_path = os.getcwd()
    projects = get_projects(base_path)
    
    total_projects = len(projects)
    results = {
        'total_videos': 0, 'total_unique_names': 0,
        'total_found_main_slots': 0, 'total_found_edit_slots': 0,
        'total_unique_main_files': 0, 'total_unique_edit_files': 0,
        'total_wrong_dimensions': 0,
    }
    
    project_reports = []
    generation_queue = {}
    obsolete_images = [] # List of (absolute_path)
    
    print()
    for idx, project in enumerate(projects):
        project_path = os.path.join(base_path, project)
        percent = (idx / total_projects) * 100
        
        thumb_dir = os.path.join(project_path, 'Thumbnails')
        edit_dir = os.path.join(project_path, 'Edit Thumbnails')
        thumb_files = set(os.listdir(thumb_dir)) if os.path.isdir(thumb_dir) else set()
        edit_files = set(os.listdir(edit_dir)) if os.path.isdir(edit_dir) else set()
        
        videos = find_videos(project_path)
        project_videos_report = []
        proj_all_names, proj_found_main_names, proj_found_edit_slots_set = set(), set(), set()
        proj_found_main_slots, proj_found_edit_slots = 0, 0
        
        used_thumb_files = set()
        used_edit_files = set()
        
        if not videos:
            print(f"[{percent:6.2f}%] Scanning project: {project} - No videos found.        ", end='\r')
            # Even if no videos, we should check if there are images in Thumbnails/Edit Thumbnails
            # because they'd all be obsolete.
            for f in thumb_files:
                if any(f.lower().endswith(ext.lower()) for ext in IMAGE_EXTENSIONS):
                    obsolete_images.append(os.path.join(thumb_dir, f))
            for f in edit_files:
                if any(f.lower().endswith(ext.lower()) for ext in IMAGE_EXTENSIONS):
                    obsolete_images.append(os.path.join(edit_dir, f))
            continue
            
        for v_idx, video in enumerate(videos):
            video_rel_path = os.path.relpath(video, project_path)
            video_name = os.path.splitext(os.path.basename(video))[0]
            proj_all_names.add(video_name)
            
            overall_percent = ((idx + (v_idx / len(videos))) / total_projects) * 100
            print(f"[{overall_percent:6.2f}%] Project: {project} | Scanning: {video_rel_path}                ", end='\r')
            
            main_file, edit_indices, edit_files_found = check_thumbnails_optimized(video, project_path, thumb_files, edit_files)
            
            # Dimension checking for Deep Scan
            wrong_dim_edits = []
            needs_main_fix = False
            
            if deep_scan:
                nb_frames, fps, v_width, v_height = get_video_info(video)
                if v_width > 0 and v_height > 0:
                    crop_str = get_crop_params(video, nb_frames)
                    if crop_str:
                        cw, ch, cx, cy = map(int, crop_str.split(':'))
                        is_landscape = cw >= ch
                    else:
                        cw, ch = v_width, v_height
                        is_landscape = v_width >= v_height

                    if is_landscape:
                        default_max_w, default_max_h = LANDSCAPE_TARGET_WIDTH, TARGET_HEIGHT
                    else:
                        default_max_w, default_max_h = PORTRAIT_TARGET_WIDTH, TARGET_HEIGHT

                    scale = min(default_max_w / cw, default_max_h / ch)
                    target_w, target_h = int(cw * scale), int(ch * scale)
                    
                    if main_file:
                        main_path = os.path.join(thumb_dir, main_file)
                        w, h = get_image_dimensions(main_path)
                        if w != target_w or h != target_h or has_black_borders(main_path):
                            needs_main_fix = True
                            results['total_wrong_dimensions'] += 1

                    for i, f in zip(edit_indices, edit_files_found):
                        edit_path = os.path.join(edit_dir, f)
                        w, h = get_image_dimensions(edit_path)
                        if w != target_w or h != target_h or has_black_borders(edit_path):
                            wrong_dim_edits.append(i)
                            results['total_wrong_dimensions'] += 1

            if main_file:
                proj_found_main_slots += 1
                proj_found_main_names.add(video_name)
                used_thumb_files.add(main_file)
            proj_found_edit_slots += len(edit_indices)
            for i in edit_indices: proj_found_edit_slots_set.add((video_name, i))
            for f in edit_files_found: used_edit_files.add(f)
            
            missing_edits = [i for i in range(1, 11) if i not in edit_indices]
            needs_main = main_file is None or needs_main_fix
            missing_edits.extend(wrong_dim_edits)
            missing_edits = sorted(list(set(missing_edits)))
            
            # If fix was triggered by deep scan dimension mismatch, we MUST force matching 
            # for these specific slots in generate_video_thumbnails.
            force_ideal = deep_scan and (needs_main_fix or wrong_dim_edits)

            if needs_main or missing_edits:
                if video not in generation_queue:
                    generation_queue[video] = [project_path, needs_main, missing_edits, force_ideal]
                else:
                    if needs_main: generation_queue[video][1] = True
                    # Combine missing edits
                    existing_missing = set(generation_queue[video][2])
                    existing_missing.update(missing_edits)
                    generation_queue[video][2] = sorted(list(existing_missing))
                    if force_ideal: generation_queue[video][3] = True
            
            project_videos_report.append({
                'video': video_rel_path, 'main_thumbnail': main_file is not None,
                'edit_thumbnails_count': len(edit_indices)
            })
            
        results['total_videos'] += len(videos)
        results['total_unique_names'] += len(proj_all_names)
        results['total_found_main_slots'] += proj_found_main_slots
        results['total_found_edit_slots'] += proj_found_edit_slots
        results['total_unique_main_files'] += len(proj_found_main_names)
        results['total_unique_edit_files'] += len(proj_found_edit_slots_set)
        
        # Identify obsolete images in this project
        for f in thumb_files:
            if f not in used_thumb_files and any(f.lower().endswith(ext.lower()) for ext in IMAGE_EXTENSIONS):
                obsolete_images.append(os.path.join(thumb_dir, f))
        for f in edit_files:
            if f not in used_edit_files and any(f.lower().endswith(ext.lower()) for ext in IMAGE_EXTENSIONS):
                obsolete_images.append(os.path.join(edit_dir, f))

        project_reports.append({
            'name': project, 'videos': project_videos_report,
            'main_thumbs_found': proj_found_main_slots, 'main_thumbs_expected': len(videos),
            'edit_thumbs_found': proj_found_edit_slots, 'edit_thumbs_expected': len(videos) * 10,
            'missing': (len(proj_all_names) - len(proj_found_main_names)) + (len(proj_all_names) * 10 - len(proj_found_edit_slots_set))
        })

    print(f"\nScan complete.\n")
    total_missing = (results['total_unique_names'] - results['total_unique_main_files']) + \
                    (results['total_unique_names'] * 10 - results['total_unique_edit_files'])
    summary = (
        f"Total number of projects scanned: {total_projects}\n"
        f"Total number of videos found: {results['total_videos']} ({results['total_unique_names']} unique names)\n"
        f"Main Thumbs: Found {results['total_found_main_slots']}/{results['total_videos']} ({results['total_unique_main_files']} unique files)\n"
        f"Edit Thumbs: Found {results['total_found_edit_slots']}/{results['total_videos'] * 10} ({results['total_unique_edit_files']} unique files)\n"
    )
    if deep_scan:
        summary += f"Images with wrong dimensions: {results['total_wrong_dimensions']}\n"
    summary += (
        f"Total number of missing images: {total_missing}\n"
        f"Total number of obsolete images: {len(obsolete_images)}\n"
    )
    print(summary)
    
    if total_missing > 0:
        print("\nFiles with Missing Images:")
        for pr in project_reports:
            missing_in_project = [vr for vr in pr['videos'] if not vr['main_thumbnail'] or vr['edit_thumbnails_count'] < 10]
            if missing_in_project:
                print(f"\n[{pr['name']}]")
                for vr in missing_in_project:
                    status = []
                    if not vr['main_thumbnail']: status.append("Main")
                    if vr['edit_thumbnails_count'] < 10: status.append(f"Edits ({vr['edit_thumbnails_count']}/10)")
                    print(f"  - {vr['video']} | Missing: {', '.join(status)}")
        print()
    
    if obsolete_images:
        if input(f"Would you like to delete {len(obsolete_images)} obsolete images? (y/n): ").lower() == 'y':
            for img_path in obsolete_images:
                try:
                    os.remove(img_path)
                except Exception as e:
                    print(f"Error deleting {img_path}: {e}")
            print(f"Deleted {len(obsolete_images)} obsolete images.")

    if generation_queue:
        gen_main_count = sum(1 for v in generation_queue.values() if v[1])
        gen_edit_count = sum(1 for v in generation_queue.values() if v[2])
        print(f"Eligible for thumbnail generation:\n- {gen_main_count} Main, {gen_edit_count} Edit videos")
        
        if input("Would you like to generate missing thumbnails? (y/n): ").lower() == 'y':
            try: subprocess.run(['ffmpeg', '-version'], capture_output=True, check=True)
            except Exception:
                print("Error: FFmpeg not found.")
                return

            tasks = [(path, data[0], data[1], data[2], data[3] if len(data) > 3 else False) for path, data in generation_queue.items()]
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
                futures = [executor.submit(generate_video_thumbnails, task) for task in tasks]
                for i, future in enumerate(concurrent.futures.as_completed(futures)):
                    video_path, success = future.result()
                    v_rel = os.path.relpath(video_path, base_path)
                    print(f"[{i+1}/{len(tasks)}] Processed: {v_rel}            ", end='\r')
            print(f"\nGeneration complete.\n")

    if generate_report:
        with open('report.txt', 'w') as f:
            f.write(f"THUMBNAIL SCAN REPORT - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write("========================================================\n\n")
            f.write(summary)
            for pr in project_reports:
                f.write(f"\nProject: {pr['name']} | Missing: {pr['missing']}\n")
                for vr in pr['videos']:
                    f.write(f"  - {vr['video']} | Main: {'OK' if vr['main_thumbnail'] else 'MISSING'} | Edits: {vr['edit_thumbnails_count']}/10\n")
        print("report.txt generated.")

def main():
    while True:
        print("\nSC Utilities & Thumbnail Scanner")
        print("1. Update scdate.txt (newest shortcut date)")
        print("2. Update scdata.txt (shortcut listing)")
        print("3. Generate scnew.txt (for Load SC New)")
        print("4. Update selections.txt (for each project)")
        print("5. Perform ALL updates (1-4)")
        print("6. Shortcut Manager")
        print("7. Normal Scan (Scan ALL projects for missing thumbnails)")
        print("8. Deep Scan (Normal + check thumbnail dimensions)")
        print("9. Verify rotation and flip data")
        print("10. Check for empty videos")
        print("11. Check for broken shortcuts (Classic scan)")
        print("12. Exit")

        user_input = input("\nEnter choice(s) (e.g., 1, 4 or 7r): ")
        if not user_input.strip(): continue

        choices = re.split(r'[ ,]+', user_input.strip())

        for choice in choices:
            choice = choice.strip()
            if not choice: continue

            generate_report = False
            clean_choice = choice
            if choice.lower().endswith('r'):
                generate_report = True
                clean_choice = choice[:-1]

            if clean_choice == '1': update_sc_date()
            elif clean_choice == '2': update_sc_data()
            elif clean_choice == '3': generate_sc_new()
            elif clean_choice == '4': update_selections()
            elif clean_choice == '5':
                update_sc_date()
                update_sc_data()
                generate_sc_new()
                update_selections()
            elif clean_choice == '6': run_shortcut_manager_menu()
            elif clean_choice == '7': run_normal_scan(deep_scan=False, generate_report=generate_report)
            elif clean_choice == '8': run_normal_scan(deep_scan=True, generate_report=generate_report)
            elif clean_choice == '9': run_rotation_and_flip_scan()
            elif clean_choice == '10': run_empty_video_scan(generate_report=generate_report)
            elif clean_choice == '11': run_broken_shortcuts_scan(generate_report=generate_report)
            elif clean_choice == '12': return
            else: print(f"Invalid choice: {choice}")

if __name__ == "__main__":
    main()
