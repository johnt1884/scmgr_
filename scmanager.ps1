# sc_manager.ps1 - Unified SC Utilities and Shortcut Manager

$videoExtensions = @("*.mp4", "*.mkv", "*.avi", "*.mov", "*.wmv", "*.flv", "*.webm")
$imageExtensions = @(".jpg", ".jpeg", ".png", ".webp")
$thumbWidth = 256
$thumbHeight = 256
$dbFile = "shortcut_db.txt"

# Helper for shortcuts
$ws = New-Object -ComObject WScript.Shell

# Add the System.Drawing assembly for thumbnail dimension checks
Add-Type -AssemblyName System.Drawing

# --- SHARED HELPERS ---

function Get-ProjectFolders {
    Get-ChildItem -LiteralPath . -Directory | Where-Object {
        $_.Name.ToLower() -notin @("sc", "landscape", "landscape rotate", "edit", "thumbnails", "edit thumbnails")
    }
}

function Get-VideoFiles {
    param($projectFolder)
    $extensions = $videoExtensions | ForEach-Object { $_.Substring(1).ToLower() }
    $videoFiles = Get-ChildItem -LiteralPath $projectFolder.FullName -File -Recurse | Where-Object {
        ($extensions -contains $_.Extension.ToLower()) -and
        ($_.FullName -notmatch '[\\/](thumbnails|edit thumbnails)[\\/]')
    }
    return $videoFiles | Sort-Object FullName -Unique
}

function Get-CorrectedImageDimensions {
    param($image)
    $width = $image.Width
    $height = $image.Height
    try {
        # PropertyTagId for EXIF Orientation is 0x0112
        $orientationProp = $image.GetPropertyItem(0x0112)
        $orientationValue = [System.BitConverter]::ToUInt16($orientationProp.Value, 0)
        # Values 5, 6, 7, 8 indicate a rotated image where width/height should be swapped
        if ($orientationValue -ge 5 -and $orientationValue -le 8) {
            $width = $image.Height
            $height = $image.Width
        }
    } catch {
        # Property does not exist, dimensions are as-is
    }
    return @{ Width = $width; Height = $height }
}

function Find-VideoBasenameForEditThumbnail {
    param(
        [string]$thumbName,
        [array]$videoBasenames
    )
    $bestMatch = $null
    # Find the longest matching video basename that is a prefix of the thumbnail name.
    foreach ($basename in $videoBasenames) {
        if ($thumbName.StartsWith("${basename}_")) {
            if ($bestMatch -eq $null -or $basename.Length -gt $bestMatch.Length) {
                $bestMatch = $basename
            }
        }
    }

    # If we found a potential match, validate the suffix is in the format '_#.jpg'
    if ($bestMatch -ne $null) {
        $suffix = $thumbName.Substring($bestMatch.Length)
        if ($suffix -match '^_\d+\.jpg$') {
            return $bestMatch
        }
    }
    return $null
}

function Show-Menu {
    Clear-Host
    Write-Host "======================================" -ForegroundColor Yellow
    Write-Host "   SC Utilities" -ForegroundColor Yellow
    Write-Host "======================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   UPDATES"
    Write-Host "   ------------------"
    Write-Host "   1. Update scdate.txt (newest shortcut date)"
    Write-Host "   2. Update scdata.txt (shortcut listing)"
    Write-Host "   3. Generate scnew.txt (for Load SC New)"
    Write-Host "   4. Update selections.txt (for each project)"
    Write-Host "   5. Perform ALL updates (1-4)"
    Write-Host ""
    Write-Host "   TOOLS"
    Write-Host "   ------------------"
    Write-Host "   6. Check Thumbnails (All, Fast)"
    Write-Host "   7. Check Thumbnails (All, Dimension Check)"
    Write-Host "   8. Update New Thumbnails"
    Write-Host "   9. Shortcut Manager"
    Write-Host "   10. Check for empty videos"
    Write-Host "   11. Check for broken shortcuts"
    Write-Host ""
    Write-Host "   12. Exit"
    Write-Host ""
}

function Update-ScDate {
    Write-Host "`nUpdating scdate.txt files..." -ForegroundColor Cyan
    
    $root = Get-Location
    $rootSc = Join-Path $root 'sc'
    $cached = @()
    if (Test-Path $rootSc) {
        Get-ChildItem $rootSc -Filter *.lnk | ForEach-Object {
            try {
                $t = $ws.CreateShortcut($_.FullName).TargetPath
                if ($t) { $cached += @{ Target = $t; Date = $_.LastWriteTime.ToUniversalTime() } }
            } catch {}
        }
    }

    $targetDirs = New-Object System.Collections.Generic.HashSet[string]
    $null = $targetDirs.Add($root.Path)
    
    Get-ChildItem -Path $root -Filter sc -Directory -Recurse | ForEach-Object {
        $null = $targetDirs.Add((Split-Path $_.FullName -Parent))
    }
    
    Get-ChildItem -Path $root -Directory | Where-Object { $_.Name -notmatch '^(sc|landscape|landscape rotate|edit|thumbnails|edit thumbnails)$' } | ForEach-Object {
        $null = $targetDirs.Add($_.FullName)
    }

    foreach ($dir in $targetDirs) {
        $out = Join-Path $dir 'scdate.txt'
        $newest = [DateTime]::MinValue
        $pSc = Join-Path $dir 'sc'
        if (Test-Path $pSc) {
            $lnk = Get-ChildItem $pSc -Filter *.lnk | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($lnk) { $newest = $lnk.LastWriteTime.ToUniversalTime() }
        }
        
        if ($dir -ne $root.Path) {
            foreach ($c in $cached) {
                if ($c.Target.StartsWith($dir + [IO.Path]::DirectorySeparatorChar) -or $c.Target -eq $dir) {
                    if ($c.Date -gt $newest) { $newest = $c.Date }
                }
            }
        }

        if ($newest -gt [DateTime]::MinValue) {
            $write = $true
            if (Test-Path $out) {
                try {
                    $content = (Get-Content $out -Raw).Trim()
                    $dDateStr = $content
                    if ($content.StartsWith('dummy:')) {
                        $dDateStr = $content.Substring(6).Trim()
                    }
                    $dDate = [DateTimeOffset]::Parse($dDateStr).UtcDateTime
                    if ($newest -le $dDate) { $write = $false }
                } catch {}
            }
            if ($write) {
                $isoDate = $newest.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                Set-Content -Path $out -Value $isoDate -Encoding ASCII
            }
        }
    }
}

function Check-EmptyVideos {
    Write-Host "`nScanning for empty videos (<2KB)..." -ForegroundColor Cyan
    $allProjectFolders = Get-ProjectFolders
    $emptyVideos = New-Object System.Collections.Generic.List[string]

    foreach ($folder in $allProjectFolders) {
        $videos = Get-VideoFiles -projectFolder $folder
        foreach ($v in $videos) {
            if ($v.Length -lt 2KB) {
                $emptyVideos.Add($v.FullName)
            }
        }
    }

    if ($emptyVideos.Count -gt 0) {
        Write-Host "`nEmpty videos found:" -ForegroundColor Red
        foreach ($v in $emptyVideos) {
            $size = (Get-Item -LiteralPath $v).Length
            Write-Host " - $v ($size bytes)"
        }
    } else {
        Write-Host "`nNo empty videos found." -ForegroundColor Green
    }
}

function Check-BrokenShortcutsLive {
    Write-Host "`nScanning for broken shortcuts..." -ForegroundColor Cyan
    $allLinks = Get-ChildItem -Path . -Filter *.lnk -Recurse
    $brokenLinks = @()

    foreach ($lnk in $allLinks) {
        $target = $ws.CreateShortcut($lnk.FullName).TargetPath
        if ($target -and -not (Test-Path -LiteralPath $target)) {
            $brokenLinks += $lnk
        }
    }

    if ($brokenLinks.Count -eq 0) {
        Write-Host "No broken shortcuts found." -ForegroundColor Green
        return
    }

    Write-Host "Found $($brokenLinks.Count) broken shortcuts:" -ForegroundColor Red
    foreach ($lnk in $brokenLinks) {
        Write-Host " - $($lnk.FullName)"
    }

    $fixChoice = Read-Host "`nWould you like to search for the missing files within subfolders and offer to fix? (y/n)"
    if ($fixChoice -ne 'y') { return }

    $allProjectFolders = Get-ProjectFolders
    Write-Host "Scanning all project folders for videos (caching)..." -ForegroundColor Gray
    $allVideosCache = @()
    foreach ($folder in $allProjectFolders) {
        $allVideosCache += Get-VideoFiles -projectFolder $folder
    }

    foreach ($lnk in $brokenLinks) {
        $fileName = [System.IO.Path]::GetFileName($ws.CreateShortcut($lnk.FullName).TargetPath)
        Write-Host "`nSearching for: $fileName" -ForegroundColor Yellow

        $foundFiles = $allVideosCache | Where-Object { $_.Name -eq $fileName }

        $foundCount = 0
        if ($foundFiles) { $foundCount = @($foundFiles).Count }

        if ($foundCount -gt 0) {
            Write-Host "Found match(es):" -ForegroundColor Green
            $foundFilesArray = @($foundFiles)
            for ($i = 0; $i -lt $foundFilesArray.Count; $i++) {
                Write-Host "  $($i + 1). $($foundFilesArray[$i].FullName)"
            }
            $selection = Read-Host "Select a file to repair the shortcut (1-$($foundFilesArray.Count)) or press Enter to skip"
            if ($selection -match '^\d+$') {
                $index = [int]$selection - 1
                if ($index -ge 0 -and $index -lt $foundFilesArray.Count) {
                    $newTarget = $foundFilesArray[$index].FullName
                    $s = $ws.CreateShortcut($lnk.FullName)
                    $s.TargetPath = $newTarget
                    $s.Save()
                    Write-Host "Shortcut repaired: $($lnk.Name) -> $newTarget" -ForegroundColor Green
                }
            }
        } else {
            Write-Host "No matching file found for $fileName" -ForegroundColor Gray
        }
    }
}

function Update-ScData {
    Write-Host "`nUpdating scdata.txt files..." -ForegroundColor Cyan
    
    # Recursive sc folders
    Get-ChildItem -Path . -Filter sc -Directory -Recurse | ForEach-Object {
        $links = Get-ChildItem $_.FullName -Filter *.lnk
        if ($links) {
            $parent = Split-Path $_.FullName -Parent
            $out = Join-Path $parent 'scdata.txt'
            $links.Name | Set-Content -Path $out -Encoding ASCII
        }
    }

    # Top-level ".\sc" (grouped target output)
    if (Test-Path '.\sc') {
        $out = Join-Path (Get-Location) 'rootdata.txt'
        Remove-Item $out -ErrorAction SilentlyContinue
        $groups = @{}
        Get-ChildItem '.\sc' -Filter *.lnk | ForEach-Object {
            $t = $ws.CreateShortcut($_.FullName).TargetPath
            if ($t) {
                $folderPath = Split-Path $t -Parent
                $folder = Split-Path $folderPath -Leaf
                $fileName = $_.Name
                $tag = '[ROOT]'
                $subSc = Join-Path $folderPath 'sc'
                if (Test-Path (Join-Path $subSc $fileName)) { $tag = '[BOTH]' }
                if (-not $groups.ContainsKey($folder)) { $groups[$folder] = @() }
                $groups[$folder] += "$fileName $tag"
            }
        }
        $groups.Keys | Sort-Object | ForEach-Object {
            Add-Content $out ('"' + $_ + '"')
            $groups[$_] | Sort-Object | ForEach-Object { Add-Content $out $_ }
            Add-Content $out ''
        }
    }
}

function Generate-ScNew {
    Write-Host "`nGenerating scnew.txt..." -ForegroundColor Cyan
    $root = Get-Location
    $rootSc = Join-Path $root 'sc'
    $rootLinks = @()
    if (Test-Path $rootSc) {
        $rootLinks = Get-ChildItem "$rootSc\*.lnk" -ErrorAction SilentlyContinue
    }

    Get-ChildItem $root -Directory | Where-Object { $_.Name -ne 'sc' } | ForEach-Object {
        $proj = $_
        $projSc = Join-Path $proj.FullName 'sc'
        $scnewFile = Join-Path $proj.FullName 'scnew.txt'
        
        if (-not (Test-Path $projSc) -or -not (Get-ChildItem "$projSc\*.lnk" -ErrorAction SilentlyContinue)) {
            if (Test-Path $scnewFile) { Remove-Item $scnewFile }
            return
        }

        $matchingRootLinks = @()
        if ($rootLinks.Count -gt 0) {
            $matchingRootLinks = foreach ($lnk in $rootLinks) {
                $target = $ws.CreateShortcut($lnk.FullName).TargetPath
                if ($target -and $target.StartsWith($proj.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                    $lnk
                }
            }
        }

        $newLinks = @()
        if ($matchingRootLinks.Count -eq 0) {
            $newLinks = Get-ChildItem "$projSc\*.lnk" | Sort-Object LastWriteTime
        } else {
            $cutoff = ($matchingRootLinks | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
            $newLinks = Get-ChildItem "$projSc\*.lnk" | Where-Object { $_.LastWriteTime -gt $cutoff } | Sort-Object LastWriteTime
        }

        if ($newLinks -and $newLinks.Count -gt 0) {
            $newLinks | Select-Object -ExpandProperty Name | Set-Content -Path $scnewFile -Encoding ASCII
        } else {
            if (Test-Path $scnewFile) { Remove-Item $scnewFile }
        }
    }
}

function Update-Selections {
    Write-Host "`nUpdating selections.txt files..." -ForegroundColor Cyan
    $root = Get-Location
    $specialFolders = @('sc', 'landscape', 'landscape rotate', 'edit', 'thumbnails', 'edit thumbnails')
    
    Get-ChildItem $root -Directory | ForEach-Object {
        if ($specialFolders -notcontains $_.Name.ToLower()) {
            Write-Host "Processing folder: $($_.Name)"
            $out = Join-Path $_.FullName 'selections.txt'
            $content = New-Object System.Collections.Generic.List[string]
            
            foreach ($sub in @("sc", "Landscape", "Landscape Rotate", "Edit")) {
                $content.Add("# $sub")
                $subPath = Join-Path $_.FullName $sub
                if (Test-Path $subPath) {
                    Get-ChildItem $subPath -File | ForEach-Object { $content.Add($_.Name) }
                }
                $content.Add("")
            }
            $content | Set-Content -Path $out -Encoding ASCII
        }
    }
}

function Check-Thumbnails {
    param($Fast = $false)

    $allProjectFolders = Get-ProjectFolders
    $totalFolders = $allProjectFolders.Count
    if ($totalFolders -eq 0) { Write-Host "`nNo project folders found." -ForegroundColor Yellow; return }

    $stats = @{
        total_videos = 0; total_unique_names = 0
        total_found_main_slots = 0; total_found_edit_slots = 0
        total_unique_main_files = 0; total_unique_edit_files = 0
        total_wrong_dimensions = 0
    }
    $projectReports = New-Object System.Collections.Generic.List[PSObject]
    $generationQueue = @{} # video_path -> [project_path, gen_main, missing_edits_array, force_ideal]
    $obsoleteImages = New-Object System.Collections.Generic.List[string]

    Write-Host ""
    $currentFolderIndex = 0
    foreach ($folder in $allProjectFolders) {
        $currentFolderIndex++
        $percent = [math]::Floor(($currentFolderIndex / $totalFolders) * 100)
        $progress = "{0,3}" -f $percent
        Write-Host -NoNewline "`r[$progress%] Processing projects..." -ForegroundColor Yellow

        $thumbDir = Join-Path $folder.FullName "Thumbnails"
        $editDir = Join-Path $folder.FullName "Edit Thumbnails"

        $thumbFilesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $thumbFiles = if (Test-Path $thumbDir) { Get-ChildItem -LiteralPath $thumbDir -File | Select-Object -ExpandProperty Name } else { @() }
        foreach ($f in $thumbFiles) { [void]$thumbFilesSet.Add($f) }

        $editFilesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $editFiles = if (Test-Path $editDir) { Get-ChildItem -LiteralPath $editDir -File | Select-Object -ExpandProperty Name } else { @() }
        foreach ($f in $editFiles) { [void]$editFilesSet.Add($f) }

        $videos = Get-VideoFiles -projectFolder $folder
        $projAllNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $projFoundMainNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $projFoundEditSlotsSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $projFoundMainSlots = 0; $projFoundEditSlots = 0
        $usedThumbFiles = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $usedEditFiles = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

        if (-not $videos) {
            foreach ($f in $thumbFiles) { $obsoleteImages.Add((Join-Path $thumbDir $f)) }
            foreach ($f in $editFiles) { $obsoleteImages.Add((Join-Path $editDir $f)) }
            continue
        }

        foreach ($video in $videos) {
            $videoName = [System.IO.Path]::GetFileNameWithoutExtension($video.Name)
            [void]$projAllNames.Add($videoName)

            # Check Main
            $foundMain = $null
            foreach ($ext in $imageExtensions) {
                if ($thumbFilesSet.Contains("$videoName$ext")) { $foundMain = "$videoName$ext"; break }
            }

            # Check Edits
            $foundEditIndices = @()
            for ($i = 1; $i -le 10; $i++) {
                foreach ($ext in $imageExtensions) {
                    if ($editFilesSet.Contains("${videoName}_${i}$ext")) {
                        $foundEditIndices += $i
                        [void]$projFoundEditSlotsSet.Add("${videoName}_${i}")
                        [void]$usedEditFiles.Add("${videoName}_${i}$ext")
                        break
                    }
                }
            }

            if ($foundMain) {
                $projFoundMainSlots++
                [void]$projFoundMainNames.Add($videoName)
                [void]$usedThumbFiles.Add($foundMain)
            }

            $projFoundEditSlots += $foundEditIndices.Count

            # Dimension Check logic (Simplified for PS)
            $needsMainFix = $false
            $wrongDimEdits = @()
            if (-not $Fast) {
                # [Simplified dimension check similar to existing PS logic]
                if ($foundMain) {
                    try {
                        $img = [System.Drawing.Image]::FromFile((Join-Path $thumbDir $foundMain))
                        $dims = Get-CorrectedImageDimensions -image $img
                        if ($dims.Width -gt $thumbWidth -or $dims.Height -gt $thumbHeight) { $needsMainFix = $true; $stats.total_wrong_dimensions++ }
                    } finally { if ($img) { $img.Dispose() } }
                }
                foreach ($idx in $foundEditIndices) {
                    # Actually we need the filename... find it again or store it.
                    foreach ($ext in $imageExtensions) {
                        $f = "${videoName}_${idx}$ext"
                        if ($editFilesSet.Contains($f)) {
                            try {
                                $img = [System.Drawing.Image]::FromFile((Join-Path $editDir $f))
                                $dims = Get-CorrectedImageDimensions -image $img
                                if ($dims.Width -gt $thumbWidth -or $dims.Height -gt $thumbHeight) { $wrongDimEdits += $idx; $stats.total_wrong_dimensions++ }
                            } finally { if ($img) { $img.Dispose() } }
                            break
                        }
                    }
                }
            }

            $missingEdits = (1..10 | Where-Object { $_ -notin $foundEditIndices })
            $genMain = ($foundMain -eq $null) -or $needsMainFix
            $genEdits = ($missingEdits + $wrongDimEdits) | Sort-Object -Unique

            if ($genMain -or $genEdits) {
                $generationQueue[$video.FullName] = @($folder.FullName, $genMain, $genEdits, (-not $Fast -and ($needsMainFix -or $wrongDimEdits)))
            }
        }

        $stats.total_videos += $videos.Count
        $stats.total_unique_names += $projAllNames.Count
        $stats.total_found_main_slots += $projFoundMainSlots
        $stats.total_found_edit_slots += $projFoundEditSlots
        $stats.total_unique_main_files += $projFoundMainNames.Count
        $stats.total_unique_edit_files += $projFoundEditSlotsSet.Count

        foreach ($f in $thumbFiles) { if (-not $usedThumbFiles.Contains($f)) { $obsoleteImages.Add((Join-Path $thumbDir $f)) } }
        foreach ($f in $editFiles) { if (-not $usedEditFiles.Contains($f)) { $obsoleteImages.Add((Join-Path $editDir $f)) } }

        $projectReports.Add([PSCustomObject]@{
            name = $folder.Name
            missing = ($projAllNames.Count - $projFoundMainNames.Count) + ($projAllNames.Count * 10 - $projFoundEditSlotsSet.Count)
        })
    }

    Write-Host "`nScan complete.`n"
    $totalMissing = ($stats.total_unique_names - $stats.total_unique_main_files) + ($stats.total_unique_names * 10 - $stats.total_unique_edit_files)

    $summary = "Total number of projects scanned: $totalFolders`n" +
               "Total number of videos found: $($stats.total_videos) ($($stats.total_unique_names) unique names)`n" +
               "Main Thumbs: Found $($stats.total_found_main_slots)/$($stats.total_videos) ($($stats.total_unique_main_files) unique files)`n" +
               "Edit Thumbs: Found $($stats.total_found_edit_slots)/$($stats.total_videos * 10) ($($stats.total_unique_edit_files) unique files)`n"
    if (-not $Fast) { $summary += "Images with wrong dimensions: $($stats.total_wrong_dimensions)`n" }
    $summary += "Total number of missing images: $totalMissing`n" +
                "Total number of obsolete images: $($obsoleteImages.Count)`n"

    Write-Host $summary

    if ($totalMissing -gt 0) {
        $ans = Read-Host "Would you like to print a list of projects with missing images? (y/n)"
        if ($ans -eq 'y') {
            foreach ($pr in $projectReports) { if ($pr.missing -gt 0) { Write-Host "  - [$($pr.name)] Missing: $($pr.missing)" } }
        }
    }

    if ($obsoleteImages.Count -gt 0) {
        $ans = Read-Host "Would you like to delete $($obsoleteImages.Count) obsolete images? (y/n)"
        if ($ans -eq 'y') {
            foreach ($img in $obsoleteImages) { if (Test-Path $img) { Remove-Item -LiteralPath $img -Force } }
            Write-Host "Deleted $($obsoleteImages.Count) obsolete images." -ForegroundColor Green
        }
    }

    if ($generationQueue.Count -gt 0) {
        $genMainCount = ($generationQueue.Values | Where-Object { $_[1] }).Count
        $genEditCount = ($generationQueue.Values | Where-Object { $_[2] }).Count
        Write-Host "Eligible for thumbnail generation:`n- $genMainCount Main, $genEditCount Edit videos"

        $ans = Read-Host "Would you like to generate a 'fix_thumbnails.bat' script? (y/n)"
        if ($ans -eq 'y') {
            $fixCommands = New-Object System.Collections.Generic.List[string]
            foreach ($vPath in $generationQueue.Keys) {
                $data = $generationQueue[$vPath]
                $projDir = $data[0]
                $genM = $data[1]
                $missE = $data[2]
                $videoName = [System.IO.Path]::GetFileNameWithoutExtension($vPath)
                $vPathBatch = $vPath.Replace('%', '%%')

                if ($genM) {
                    $tDir = Join-Path $projDir "Thumbnails"
                    $fixCommands.Add("if not exist `"$($tDir.Replace('%', '%%'))`" mkdir `"$($tDir.Replace('%', '%%'))`"")
                    $tPath = (Join-Path $tDir "$videoName.jpg").Replace('%', '%%')
                    $fixCommands.Add("ffmpeg -y -noautorotate -i `"$vPathBatch`" -ss 00:00:02.000 -update 1 -frames:v 1 -vf `"scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 `"$tPath`" >nul 2>&1")
                }
                if ($missE) {
                    $eDir = Join-Path $projDir "Edit Thumbnails"
                    $fixCommands.Add("if not exist `"$($eDir.Replace('%', '%%'))`" mkdir `"$($eDir.Replace('%', '%%'))`"")
                    try {
                        $durationStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i $vPath
                        $durationInt = [math]::Floor([double]::Parse($durationStr))
                        if ($durationInt -eq 0) { $durationInt = 10 }
                        $interval = [math]::Floor($durationInt / 10)
                        if ($interval -eq 0) { $interval = 1 }
                        foreach ($idx in $missE) {
                            $timestamp = ($idx - 1) * $interval
                            $tPath = (Join-Path $eDir "${videoName}_${idx}.jpg").Replace('%', '%%')
                            $fixCommands.Add("ffmpeg -y -noautorotate -ss $timestamp -i `"$vPathBatch`" -update 1 -vframes 1 -vf `"scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 `"$tPath`" >nul 2>&1")
                        }
                    } catch {}
                }
            }
            $fixScriptContent = "@echo off`r`necho Starting thumbnail fix process...`r`n" + (($fixCommands | Select-Object -Unique) -join "`r`n") + "`r`necho.`r`necho Thumbnail fix process complete.`r`npause"
            [System.IO.File]::WriteAllText((Join-Path (Get-Location) "fix_thumbnails.bat"), $fixScriptContent, [System.Text.Encoding]::UTF8)
            Write-Host "`nfix_thumbnails.bat has been generated." -ForegroundColor Green
        }
    }
}

function Update-New-Thumbnails {
    $allProjectFolders = Get-ProjectFolders
    $totalFolders = $allProjectFolders.Count
    if ($totalFolders -eq 0) { return }

    $stats = @{ total_videos = 0; total_unique_names = 0; total_found_main_slots = 0; total_found_edit_slots = 0; total_unique_main_files = 0; total_unique_edit_files = 0 }
    $generationQueue = @{}
    $obsoleteImages = New-Object System.Collections.Generic.List[string]

    Write-Host "`nStarting fast thumbnail update for new videos..." -ForegroundColor Yellow
    $currentFolderIndex = 0
    foreach ($folder in $allProjectFolders) {
        $currentFolderIndex++
        $percent = [math]::Floor(($currentFolderIndex / $totalFolders) * 100)
        $progress = "{0,3}" -f $percent
        Write-Host -NoNewline "`r[$progress%] Processing projects..." -ForegroundColor Yellow

        $scDatePath = Join-Path $folder.FullName "scdate.txt"
        if (-not (Test-Path $scDatePath)) { continue }
        try {
            $content = (Get-Content $scDatePath -Raw).Trim()
            if ($content.StartsWith('dummy:')) { $content = $content.Substring(6).Trim() }
            $cutoff = [DateTimeOffset]::Parse($content).UtcDateTime
        } catch { continue }

        $thumbDir = Join-Path $folder.FullName "Thumbnails"
        $editDir = Join-Path $folder.FullName "Edit Thumbnails"
        $thumbFilesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $thumbFiles = if (Test-Path $thumbDir) { Get-ChildItem -LiteralPath $thumbDir -File | Select-Object -ExpandProperty Name } else { @() }
        foreach ($f in $thumbFiles) { [void]$thumbFilesSet.Add($f) }

        $editFilesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $editFiles = if (Test-Path $editDir) { Get-ChildItem -LiteralPath $editDir -File | Select-Object -ExpandProperty Name } else { @() }
        foreach ($f in $editFiles) { [void]$editFilesSet.Add($f) }

        $videos = Get-VideoFiles -projectFolder $folder
        $videoBasenames = $videos | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
        $newVideos = $videos | Where-Object { $_.LastWriteTime.ToUniversalTime() -gt $cutoff }
        
        # Obsolete Check
        $usedThumbFiles = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $usedEditFiles = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($vName in $videoBasenames) {
            foreach ($ext in $imageExtensions) {
                if ($thumbFilesSet.Contains("$vName$ext")) { [void]$usedThumbFiles.Add("$vName$ext") }
                for ($i = 1; $i -le 10; $i++) {
                    if ($editFilesSet.Contains("${vName}_${i}$ext")) { [void]$usedEditFiles.Add("${vName}_${i}$ext") }
                }
            }
        }
        foreach ($f in $thumbFilesSet) { if (-not $usedThumbFiles.Contains($f)) { $obsoleteImages.Add((Join-Path $thumbDir $f)) } }
        foreach ($f in $editFilesSet) { if (-not $usedEditFiles.Contains($f)) { $obsoleteImages.Add((Join-Path $editDir $f)) } }

        if ($newVideos) {
            foreach ($video in $newVideos) {
                $videoName = [System.IO.Path]::GetFileNameWithoutExtension($video.Name)
                $foundMain = $null
                foreach ($ext in $imageExtensions) { if ($thumbFilesSet.Contains("$videoName$ext")) { $foundMain = "$videoName$ext"; break } }
                $missE = @()
                for ($i = 1; $i -le 10; $i++) {
                    $found = $false
                    foreach ($ext in $imageExtensions) { if ($editFilesSet.Contains("${videoName}_${i}$ext")) { $found = $true; break } }
                    if (-not $found) { $missE += $i }
                }
                if (($foundMain -eq $null) -or $missE) { $generationQueue[$video.FullName] = @($folder.FullName, ($foundMain -eq $null), $missE, $false) }
            }
        }
    }

    Write-Host "`nScan complete.`n"
    if ($obsoleteImages.Count -gt 0) {
        $ans = Read-Host "Would you like to delete $($obsoleteImages.Count) obsolete images? (y/n)"
        if ($ans -eq 'y') { foreach ($img in $obsoleteImages) { if (Test-Path $img) { Remove-Item -LiteralPath $img -Force } } }
    }

    if ($generationQueue.Count -gt 0) {
        $ans = Read-Host "Eligible for generation: $($generationQueue.Count) videos. Generate 'fix_thumbnails.bat'? (y/n)"
        if ($ans -eq 'y') {
            $fixCommands = New-Object System.Collections.Generic.List[string]
            foreach ($vPath in $generationQueue.Keys) {
                $data = $generationQueue[$vPath]; $projDir = $data[0]; $genM = $data[1]; $missE = $data[2]; $vName = [System.IO.Path]::GetFileNameWithoutExtension($vPath); $vPathBatch = $vPath.Replace('%', '%%')
                if ($genM) {
                    $tDir = Join-Path $projDir "Thumbnails"; $fixCommands.Add("if not exist `"$($tDir.Replace('%', '%%'))`" mkdir `"$($tDir.Replace('%', '%%'))`"")
                    $tPath = (Join-Path $tDir "$vName.jpg").Replace('%', '%%'); $fixCommands.Add("ffmpeg -y -noautorotate -i `"$vPathBatch`" -ss 00:00:02.000 -update 1 -frames:v 1 -vf `"scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 `"$tPath`" >nul 2>&1")
                }
                if ($missE) {
                    $eDir = Join-Path $projDir "Edit Thumbnails"; $fixCommands.Add("if not exist `"$($eDir.Replace('%', '%%'))`" mkdir `"$($eDir.Replace('%', '%%'))`"")
                    try {
                        $durationStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i $vPath
                        $durationInt = [math]::Floor([double]::Parse($durationStr)); if ($durationInt -eq 0) { $durationInt = 10 }; $interval = [math]::Floor($durationInt / 10); if ($interval -eq 0) { $interval = 1 }
                        foreach ($idx in $missE) { $timestamp = ($idx - 1) * $interval; $tPath = (Join-Path $eDir "${vName}_${idx}.jpg").Replace('%', '%%'); $fixCommands.Add("ffmpeg -y -noautorotate -ss $timestamp -i `"$vPathBatch`" -update 1 -vframes 1 -vf `"scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 `"$tPath`" >nul 2>&1") }
                    } catch {}
                }
            }
            $fixScriptContent = "@echo off`r`necho Starting fast thumbnail fix process...`r`n" + (($fixCommands | Select-Object -Unique) -join "`r`n") + "`r`necho.`r`necho Thumbnail fix process complete.`r`npause"
            [System.IO.File]::WriteAllText((Join-Path (Get-Location) "fix_thumbnails.bat"), $fixScriptContent, [System.Text.Encoding]::UTF8)
            Write-Host "`nfix_thumbnails.bat has been generated." -ForegroundColor Green
        }
    }
}

# --- Shortcut Manager Logic ---

function Get-MD5 {
    param([string]$path)
    if (Test-Path $path) {
        return (Get-FileHash $path -Algorithm MD5).Hash
    }
    return $null
}

function Update-ShortcutDatabase {
    Write-Host "`nUpdating Shortcut Database..." -ForegroundColor Cyan
    
    $database = @()
    if (Test-Path $dbFile) {
        # Parsing the human-readable format back into objects if it exists
        $content = Get-Content $dbFile
        $currentEntry = @{}
        foreach ($line in $content) {
            if ($line -match '^Folder path: (.*)') { $currentEntry.FolderPath = $matches[1] }
            elseif ($line -match '^Shortcut: (.*)') { $currentEntry.ShortcutName = $matches[1] }
            elseif ($line -match '^Shortcut Video Path: (.*)') { $currentEntry.VideoPath = $matches[1] }
            elseif ($line -match '^Shortcut md5: (.*)') { $currentEntry.MD5 = $matches[1] }
            elseif ($line -eq '---') {
                if ($currentEntry.FolderPath) { $database += New-Object PSObject -Property $currentEntry }
                $currentEntry = @{}
            }
        }
    }

    # Find all shortcuts in subfolders
    $allLinks = Get-ChildItem -Path . -Filter *.lnk -Recurse
    
    $newDatabase = @()

    foreach ($lnk in $allLinks) {
        $target = $ws.CreateShortcut($lnk.FullName).TargetPath
        if (-not $target) { continue }

        # Check if target is a video
        $ext = [System.IO.Path]::GetExtension($target).ToLower()
        $isVideo = $false
        foreach ($vExt in $videoExtensions) {
            if ("*$ext" -eq $vExt) { $isVideo = $true; break }
        }
        if (-not $isVideo) { continue }

        # Check if we already have this shortcut in our database
        $existing = $database | Where-Object { $_.FolderPath -eq $lnk.DirectoryName -and $_.ShortcutName -eq $lnk.Name }
        
        if ($existing) {
            # Update VideoPath and MD5 if target exists
            if (Test-Path $target) {
                $existing.VideoPath = $target
                $existing.MD5 = Get-MD5 $target
            }
            $newDatabase += $existing
        } else {
            # New shortcut
            if (Test-Path $target) {
                $md5 = Get-MD5 $target
                $newDatabase += [PSCustomObject]@{
                    FolderPath = $lnk.DirectoryName
                    ShortcutName = $lnk.Name
                    VideoPath = $target
                    MD5 = $md5
                }
                Write-Host "Added: $($lnk.Name)" -ForegroundColor Green
            }
        }
    }

    # Save to file in the requested format
    $output = @()
    foreach ($entry in $newDatabase) {
        $output += "Folder path: $($entry.FolderPath)"
        $output += "Shortcut: $($entry.ShortcutName)"
        $output += "Shortcut Video Path: $($entry.VideoPath)"
        $output += "Shortcut md5: $($entry.MD5)"
        $output += "---"
    }
    $output | Set-Content $dbFile -Encoding ASCII
    Write-Host "Database updated. Total entries: $($newDatabase.Count)" -ForegroundColor Green
}

function Scan-BrokenShortcuts {
    Write-Host "`nScanning for broken shortcuts..." -ForegroundColor Cyan
    if (-not (Test-Path $dbFile)) {
        Write-Warning "Shortcut database not found. Please run 'Update shortcut Database' first."
        return
    }

    # Load database
    $database = @()
    $content = Get-Content $dbFile
    $currentEntry = @{}
    foreach ($line in $content) {
        if ($line -match '^Folder path: (.*)') { $currentEntry.FolderPath = $matches[1] }
        elseif ($line -match '^Shortcut: (.*)') { $currentEntry.ShortcutName = $matches[1] }
        elseif ($line -match '^Shortcut Video Path: (.*)') { $currentEntry.VideoPath = $matches[1] }
        elseif ($line -match '^Shortcut md5: (.*)') { $currentEntry.MD5 = $matches[1] }
        elseif ($line -eq '---') {
            if ($currentEntry.FolderPath) { $database += New-Object PSObject -Property $currentEntry }
            $currentEntry = @{}
        }
    }

    foreach ($entry in $database) {
        $lnkPath = Join-Path $entry.FolderPath $entry.ShortcutName
        if (-not (Test-Path $lnkPath)) { continue } # Shortcut file itself is gone

        $target = $ws.CreateShortcut($lnkPath).TargetPath
        if (-not (Test-Path $target)) {
            Write-Host "`nBroken Shortcut found: $($entry.ShortcutName) in $($entry.FolderPath)" -ForegroundColor Red
            Write-Host "Original Target: $($entry.VideoPath)"
            
            $originalDir = Split-Path $entry.VideoPath -Parent
            if (Test-Path $originalDir) {
                Write-Host "Searching for matching file in: $originalDir" -ForegroundColor Yellow
                $files = Get-ChildItem $originalDir -File
                $foundMatch = $null
                foreach ($f in $files) {
                    $fExt = [System.IO.Path]::GetExtension($f.FullName).ToLower()
                    $isVid = $false
                    foreach ($vExt in $videoExtensions) {
                        if ("*$fExt" -eq $vExt) { $isVid = $true; break }
                    }
                    if ($isVid) {
                        if ((Get-MD5 $f.FullName) -eq $entry.MD5) {
                            $foundMatch = $f
                            break
                        }
                    }
                }
                
                if ($foundMatch) {
                    Write-Host "Match found! New file name: $($foundMatch.Name)" -ForegroundColor Green
                    $choice = Read-Host "Repair shortcut? (y/n)"
                    if ($choice -eq 'y') {
                        $shortcut = $ws.CreateShortcut($lnkPath)
                        $shortcut.TargetPath = $foundMatch.FullName
                        $shortcut.Save()
                        Write-Host "Shortcut repaired." -ForegroundColor Green
                    }
                } else {
                    Write-Host "No matching file found by MD5 in the original directory." -ForegroundColor Gray
                }
            } else {
                Write-Host "Original target directory no longer exists: $originalDir" -ForegroundColor Gray
            }
        }
    }
}

function Shortcut-Manager-Menu {
    while ($true) {
        Write-Host "`n--- Shortcut Manager ---" -ForegroundColor Yellow
        Write-Host "1. Update shortcut Database"
        Write-Host "2. Scan for broken Shortcuts"
        Write-Host "3. Back"
        $choice = Read-Host "`nSelect an option"
        
        switch ($choice) {
            "1" { Update-ShortcutDatabase }
            "2" { Scan-BrokenShortcuts }
            "3" { return }
            Default { Write-Host "Invalid choice." -ForegroundColor Red }
        }
    }
}

# --- Main Script ---

while ($true) {
    Show-Menu
    $choices = Read-Host "Choose one or more options (e.g., 1 3 6)"
    if (-not $choices) { continue }
    
    $choiceArray = $choices -split '[\s,;]+' | Where-Object { $_ }
    
    foreach ($c in $choiceArray) {
        switch ($c) {
            "1" { Update-ScDate }
            "2" { Update-ScData }
            "3" { Generate-ScNew }
            "4" { Update-Selections }
            "5" { Update-ScDate; Update-ScData; Generate-ScNew; Update-Selections }
            "6" { Check-Thumbnails -Fast $true }
            "7" { Check-Thumbnails -Fast $false }
            "8" { Update-New-Thumbnails }
            "9" { Shortcut-Manager-Menu }
            "10" { Check-EmptyVideos }
            "11" { Check-BrokenShortcutsLive }
            "12" { exit }
            Default { Write-Host "Invalid option: $c" -ForegroundColor Red }
        }
    }
    
    Write-Host "`nDone. Press any key to continue..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
