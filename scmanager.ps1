# sc_manager.ps1 - Unified SC Utilities and Shortcut Manager

$videoExtensions = @("*.mp4", "*.avi", "*.mov", "*.mkv")
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
    $videoFiles = @()
    $extensions = $videoExtensions | ForEach-Object { $_.Substring(1).ToLower() }
    $videoFiles += Get-ChildItem -LiteralPath $projectFolder.FullName -File | Where-Object { $extensions -contains $_.Extension.ToLower() }
    foreach ($subfolder in @("Landscape", "Landscape Rotate", "Edit")) {
        $subfolderPath = Join-Path $projectFolder.FullName $subfolder
        if (Test-Path -LiteralPath $subfolderPath) {
            $videoFiles += Get-ChildItem -LiteralPath $subfolderPath -File | Where-Object { $extensions -contains $_.Extension.ToLower() }
        }
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
    Write-Host "   01. Update scdate.txt (newest shortcut date)"
    Write-Host "   02. Update scdata.txt (shortcut listing)"
    Write-Host "   03. Generate scnew.txt (for Load SC New)"
    Write-Host "   04. Update selections.txt (for each project)"
    Write-Host "   05. Perform ALL updates (1-4)"
    Write-Host ""
    Write-Host "   TOOLS"
    Write-Host "   ------------------"
    Write-Host "   06. Check Thumbnails (All, Fast)"
    Write-Host "   07. Check Thumbnails (All, Dimension Check)"
    Write-Host "   08. Update New Thumbnails"
    Write-Host "   09. Shortcut Manager"
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
    # Ported from check_thumbnails.ps1

    $allProjectFolders = Get-ProjectFolders
    $overallIssues = @{ MissingRegular = 0; MissingEdit = 0; WrongDimensions = 0; Obsolete = 0 }
    $fixCommands = @()
    $obsoleteFiles = New-Object System.Collections.Generic.List[string]

    Write-Host "`nStarting thumbnail check for all project folders..." -ForegroundColor Yellow

    $totalFolders = $allProjectFolders.Count
    if ($totalFolders -eq 0) {
        Write-Host "`nNo project folders found." -ForegroundColor Yellow
        return
    }
    $currentFolderIndex = 0

    foreach ($folder in $allProjectFolders) {
        $currentFolderIndex++
        $percent = [math]::Floor(($currentFolderIndex / $totalFolders) * 100)
        Write-Host -NoNewline "`r[$percent%] Processing projects..." -ForegroundColor Yellow

        $videos = Get-VideoFiles -projectFolder $folder
        $videoBasenames = $videos | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
        $regularThumbsDir = Join-Path $folder.FullName "Thumbnails"
        $editThumbsDir = Join-Path $folder.FullName "Edit Thumbnails"

        $projectIssues = @{
            MissingRegular = New-Object System.Collections.Generic.List[string]
            MissingEdit = New-Object System.Collections.Generic.List[string]
            WrongDimensions = New-Object System.Collections.Generic.List[string]
            ObsoleteRegular = New-Object System.Collections.Generic.List[string]
            ObsoleteEdit = New-Object System.Collections.Generic.List[string]
        }

        # Fast existence check using HashSets
        $thumbFilesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        if (Test-Path -LiteralPath $regularThumbsDir) {
            Get-ChildItem -LiteralPath $regularThumbsDir -Filter *.jpg | ForEach-Object { [void]$thumbFilesSet.Add($_.Name) }
        }
        $editFilesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        if (Test-Path -LiteralPath $editThumbsDir) {
            Get-ChildItem -LiteralPath $editThumbsDir -Filter *.jpg | ForEach-Object { [void]$editFilesSet.Add($_.Name) }
        }

        # 1. Missing regular
        foreach ($video in $videos) {
            $thumbName = "$([System.IO.Path]::GetFileNameWithoutExtension($video.Name)).jpg"
            if (-not $thumbFilesSet.Contains($thumbName)) { $projectIssues.MissingRegular.Add($video.FullName) }
        }

        # 2. Missing edit
        foreach ($video in $videos) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($video.Name)
            $isMissingAll = $true
            for ($i = 1; $i -le 10; $i++) {
                if ($editFilesSet.Contains("${baseName}_${i}.jpg")) { $isMissingAll = $false; break }
            }
            if ($isMissingAll) { $projectIssues.MissingEdit.Add($video.FullName) }
        }

        # 3. Wrong dims and obsolete
        if (Test-Path -LiteralPath $regularThumbsDir) {
            Get-ChildItem -LiteralPath $regularThumbsDir -Filter *.jpg -File | ForEach-Object {
                $thumbBasename = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                if ($thumbBasename -in $videoBasenames) {
                    if (-not $Fast) {
                        try {
                            $img = [System.Drawing.Image]::FromFile($_.FullName)
                            $correctedDims = Get-CorrectedImageDimensions -image $img
                            if ($correctedDims.Width -gt $thumbWidth -or $correctedDims.Height -gt $thumbHeight) { $projectIssues.WrongDimensions.Add($_.FullName) }
                        } finally { if ($img) { $img.Dispose() } }
                    }
                } else { $projectIssues.ObsoleteRegular.Add($_.FullName) }
            }
        }
        if (Test-Path -LiteralPath $editThumbsDir) {
            Get-ChildItem -LiteralPath $editThumbsDir -Filter *.jpg -File | ForEach-Object {
                $videoBasename = Find-VideoBasenameForEditThumbnail -thumbName $_.Name -videoBasenames $videoBasenames
                if ($videoBasename -ne $null) {
                    if (-not $Fast) {
                        try {
                            $img = [System.Drawing.Image]::FromFile($_.FullName)
                            $correctedDims = Get-CorrectedImageDimensions -image $img
                            if ($correctedDims.Width -gt $thumbWidth -or $correctedDims.Height -gt $thumbHeight) { $projectIssues.WrongDimensions.Add($_.FullName) }
                        } finally { if ($img) { $img.Dispose() } }
                    }
                } else { $projectIssues.ObsoleteEdit.Add($_.FullName) }
            }
        }

        # Reporting and Fix generation
        $totalProjectIssues = $projectIssues.MissingRegular.Count + $projectIssues.MissingEdit.Count + $projectIssues.WrongDimensions.Count + $projectIssues.ObsoleteRegular.Count + $projectIssues.ObsoleteEdit.Count
        if ($totalProjectIssues -gt 0) {
            Write-Host "`nProject: $($folder.Name)" -ForegroundColor Cyan
            if ($projectIssues.MissingRegular.Count -gt 0) {
                Write-Host " - Missing Regular Thumbnails: $($projectIssues.MissingRegular.Count)" -ForegroundColor Red
                $overallIssues.MissingRegular += $projectIssues.MissingRegular.Count
                $fixCommands += 'if not exist "' + $regularThumbsDir + '" mkdir "' + $regularThumbsDir + '"'
                $projectIssues.MissingRegular | ForEach-Object {
                    $thumbPath = Join-Path $regularThumbsDir "$([System.IO.Path]::GetFileNameWithoutExtension($_)).jpg"
                    $fixCommands += "ffmpeg -y -noautorotate -i ""$_"" -ss 00:00:02.000 -update 1 -frames:v 1 -vf ""scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease"" -map_metadata -1 ""$thumbPath"""
                }
            }
            if ($projectIssues.MissingEdit.Count -gt 0) {
                Write-Host " - Missing Edit Mode Thumbnails: $($projectIssues.MissingEdit.Count)" -ForegroundColor Red
                $overallIssues.MissingEdit += $projectIssues.MissingEdit.Count
                $fixCommands += 'if not exist "' + $editThumbsDir + '" mkdir "' + $editThumbsDir + '"'
                $projectIssues.MissingEdit | ForEach-Object {
                    $videoPath = $_
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($videoPath)
                    try {
                        $durationStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i $videoPath
                        $durationInt = [math]::Floor([double]::Parse($durationStr))
                        if ($durationInt -eq 0) { $durationInt = 10 }
                        $interval = [math]::Floor($durationInt / 10)
                        if ($interval -eq 0) { $interval = 1 }
                        for ($i = 1; $i -le 10; $i++) {
                            $timestamp = ($i - 1) * $interval
                            $thumbPath = Join-Path $editThumbsDir "${baseName}_${i}.jpg"
                            $fixCommands += "ffmpeg -y -noautorotate -ss $timestamp -i ""$videoPath"" -update 1 -vframes 1 -vf ""scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease"" -map_metadata -1 ""$thumbPath"" >nul 2>&1"
                        }
                    } catch {}
                }
            }
            if ($projectIssues.WrongDimensions.Count -gt 0) {
                Write-Host " - Thumbnails with Wrong Dimensions: $($projectIssues.WrongDimensions.Count)" -ForegroundColor Red
                $overallIssues.WrongDimensions += $projectIssues.WrongDimensions.Count
                foreach ($thumbPath in $projectIssues.WrongDimensions) {
                    $thumbName = [System.IO.Path]::GetFileName($thumbPath)
                    $video = $null
                    if ($thumbPath.Contains('Edit Thumbnails')) {
                        $baseName = Find-VideoBasenameForEditThumbnail -thumbName $thumbName -videoBasenames $videoBasenames
                        $video = $videos | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $baseName } | Select-Object -First 1
                    } else {
                        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($thumbName)
                        $video = $videos | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $baseName } | Select-Object -First 1
                    }
                    if ($video) {
                        if ($thumbPath.Contains('Edit Thumbnails')) {
                            try {
                                $timestampIndex = $thumbName.Substring($thumbName.LastIndexOf('_') + 1).Split('.')[0] - 1
                                $durationStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i $video.FullName
                                $durationInt = [math]::Floor([double]::Parse($durationStr))
                                if ($durationInt -eq 0) { $durationInt = 10 }
                                $interval = [math]::Floor($durationInt / 10)
                                if ($interval -eq 0) { $interval = 1 }
                                $timestamp = $timestampIndex * $interval
                                $fixCommands += "ffmpeg -y -noautorotate -ss $timestamp -i ""$($video.FullName)"" -update 1 -vframes 1 -vf ""scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease"" -map_metadata -1 ""$thumbPath"" >nul 2>&1"
                            } catch {}
                        } else {
                            $fixCommands += "ffmpeg -y -noautorotate -i ""$($video.FullName)"" -ss 00:00:02.000 -update 1 -frames:v 1 -vf ""scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease"" -map_metadata -1 ""$thumbPath"""
                        }
                    } else { $fixCommands += 'if exist "' + $thumbPath + '" del "' + $thumbPath + '"' }
                }
            }
            if ($projectIssues.ObsoleteRegular.Count -gt 0) {
                Write-Host " - Obsolete Regular Thumbnails (No corresponding video): $($projectIssues.ObsoleteRegular.Count)" -ForegroundColor Red
                $projectIssues.ObsoleteRegular | ForEach-Object {
                    $overallIssues.Obsolete++
                    $obsoleteFiles.Add($_)
                    $fixCommands += 'if exist "' + $_ + '" del "' + $_ + '"'
                }
            }
            if ($projectIssues.ObsoleteEdit.Count -gt 0) {
                Write-Host " - Obsolete Edit Thumbnails (No corresponding video): $($projectIssues.ObsoleteEdit.Count)" -ForegroundColor Red
                $projectIssues.ObsoleteEdit | ForEach-Object {
                    $overallIssues.Obsolete++
                    $obsoleteFiles.Add($_)
                    $fixCommands += 'if exist "' + $_ + '" del "' + $_ + '"'
                }
            }
        }
    }

    Write-Host "`r[100%] Scan complete.                " -ForegroundColor Yellow

    Write-Host "`n=================================================="
    Write-Host "Overall Summary" -ForegroundColor Yellow
    Write-Host "=================================================="
    $totalOverallIssues = $overallIssues.MissingRegular + $overallIssues.MissingEdit + $overallIssues.WrongDimensions + $overallIssues.Obsolete

    if ($totalOverallIssues -gt 0) {
        Write-Host "Missing Regular Thumbnails: $($overallIssues.MissingRegular)"
        Write-Host "Missing Edit Sets:          $($overallIssues.MissingEdit)"
        Write-Host "Wrong Dimensions:           $($overallIssues.WrongDimensions)"
        Write-Host "Obsolete Thumbnails:        $($overallIssues.Obsolete)"

        if ($obsoleteFiles.Count -gt 0) {
            $delChoice = Read-Host "`n$($obsoleteFiles.Count) obsolete thumbnails (no corresponding video) found. Delete them now? (y/n)"
            if ($delChoice -eq 'y') {
                foreach ($file in $obsoleteFiles) {
                    if (Test-Path -LiteralPath $file) {
                        Remove-Item -LiteralPath $file -Force
                        Write-Host "Deleted: $file" -ForegroundColor Gray
                    }
                }
                Write-Host "Obsolete thumbnails deleted." -ForegroundColor Green
                # Clear obsolete from overall issues since they are gone
                $overallIssues.Obsolete = 0
            }
        }

        $choice = Read-Host "`nIssues found. Would you like to generate a 'fix_thumbnails.bat' script to resolve them? (y/n)"
        if ($choice -eq 'y') {
            $fixScriptContent = "@echo off`r`nsetlocal enabledelayedexpansion`r`necho Starting thumbnail fix process...`r`n" + ($fixCommands -join "`r`n") + "`r`necho.`r`necho Thumbnail fix process complete.`r`npause"
            Set-Content -LiteralPath "fix_thumbnails.bat" -Value $fixScriptContent
            Write-Host "`nfix_thumbnails.bat has been generated." -ForegroundColor Green
        }
    } else { Write-Host "All project thumbnails are in good shape!" -ForegroundColor Green }
}

function Update-New-Thumbnails {
    Write-Host "`nStarting fast thumbnail update for new videos..." -ForegroundColor Yellow
    $allProjectFolders = Get-ProjectFolders
    $fixCommands = @()
    $newVideoCount = 0
    $obsoleteFiles = New-Object System.Collections.Generic.List[string]

    $totalFolders = $allProjectFolders.Count
    if ($totalFolders -eq 0) { return }
    $currentFolderIndex = 0

    foreach ($folder in $allProjectFolders) {
        $currentFolderIndex++
        $percent = [math]::Floor(($currentFolderIndex / $totalFolders) * 100)
        Write-Host -NoNewline "`r[$percent%] Processing projects..." -ForegroundColor Yellow

        $scDatePath = Join-Path $folder.FullName "scdate.txt"
        if (-not (Test-Path $scDatePath)) { continue }

        $cutoff = [DateTime]::MinValue
        try {
            $content = (Get-Content $scDatePath -Raw).Trim()
            if ($content.StartsWith('dummy:')) { $content = $content.Substring(6).Trim() }
            $cutoff = [DateTimeOffset]::Parse($content).UtcDateTime
        } catch { continue }

        $videos = Get-VideoFiles -projectFolder $folder
        $newVideos = $videos | Where-Object { $_.LastWriteTime.ToUniversalTime() -gt $cutoff }
        
        if ($newVideos) {
            $regularThumbsDir = Join-Path $folder.FullName "Thumbnails"
            $editThumbsDir = Join-Path $folder.FullName "Edit Thumbnails"

            # Fast existence check for new videos
            $thumbFilesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
            if (Test-Path -LiteralPath $regularThumbsDir) {
                Get-ChildItem -LiteralPath $regularThumbsDir -Filter *.jpg | ForEach-Object { [void]$thumbFilesSet.Add($_.Name) }
            }
            $editFilesSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
            if (Test-Path -LiteralPath $editThumbsDir) {
                Get-ChildItem -LiteralPath $editThumbsDir -Filter *.jpg | ForEach-Object { [void]$editFilesSet.Add($_.Name) }
            }

            # Check for obsolete thumbnails (all scans should do this)
            $videoBasenames = $videos | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
            $projectObsoleteCount = 0
            foreach ($f in $thumbFilesSet) {
                if ([System.IO.Path]::GetFileNameWithoutExtension($f) -notin $videoBasenames) {
                    $fullP = Join-Path $regularThumbsDir $f
                    $obsoleteFiles.Add($fullP)
                    $fixCommands += 'if exist "' + $fullP + '" del "' + $fullP + '"'
                    $projectObsoleteCount++
                }
            }
            foreach ($f in $editFilesSet) {
                if ((Find-VideoBasenameForEditThumbnail -thumbName $f -videoBasenames $videoBasenames) -eq $null) {
                    $fullP = Join-Path $editThumbsDir $f
                    $obsoleteFiles.Add($fullP)
                    $fixCommands += 'if exist "' + $fullP + '" del "' + $fullP + '"'
                    $projectObsoleteCount++
                }
            }

            if ($projectObsoleteCount -gt 0) {
                Write-Host "`nProject: $($folder.Name)" -ForegroundColor Cyan
                Write-Host " - Obsolete Thumbnails: $projectObsoleteCount" -ForegroundColor Red
            }

            foreach ($video in $newVideos) {
                $newVideoCount++
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($video.Name)
                $vPathBatch = $video.FullName.Replace('%', '%%')

                # Check Regular Thumbnail
        if (-not $thumbFilesSet.Contains("$baseName.jpg")) {
                    $fixCommands += "if not exist `"$($regularThumbsDir.Replace('%', '%%'))`" mkdir `"$($regularThumbsDir.Replace('%', '%%'))`""
            $tPathBatch = (Join-Path $regularThumbsDir "$baseName.jpg").Replace('%', '%%')
                    $fixCommands += "ffmpeg -y -noautorotate -i `"$vPathBatch`" -ss 00:00:02.000 -update 1 -frames:v 1 -vf `"scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 `"$tPathBatch`" >nul 2>&1"
                }

                # Check Edit Thumbnails
                $missingEdit = $false
                for ($i = 1; $i -le 10; $i++) {
            if (-not $editFilesSet.Contains("${baseName}_${i}.jpg")) {
                        $missingEdit = $true
                        break
                    }
                }

                if ($missingEdit) {
                    $fixCommands += "if not exist `"$($editThumbsDir.Replace('%', '%%'))`" mkdir `"$($editThumbsDir.Replace('%', '%%'))`""
                    try {
                        $durationStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i $video.FullName
                        $durationInt = [math]::Floor([double]::Parse($durationStr))
                        if ($durationInt -eq 0) { $durationInt = 10 }
                        $interval = [math]::Floor($durationInt / 10)
                        if ($interval -eq 0) { $interval = 1 }
                        for ($i = 1; $i -le 10; $i++) {
                            $timestamp = ($i - 1) * $interval
                            $tPathBatch = (Join-Path $editThumbsDir "${baseName}_${i}.jpg").Replace('%', '%%')
                            $fixCommands += "ffmpeg -y -noautorotate -ss $timestamp -i `"$vPathBatch`" -update 1 -vframes 1 -vf `"scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 `"$tPathBatch`" >nul 2>&1"
                        }
                    } catch {}
                }
            }
        }
    }

    Write-Host "`r[100%] Scan complete.                " -ForegroundColor Yellow

    if ($obsoleteFiles.Count -gt 0) {
        $delChoice = Read-Host "`n$($obsoleteFiles.Count) obsolete thumbnails (no corresponding video) found. Delete them now? (y/n)"
        if ($delChoice -eq 'y') {
            foreach ($file in $obsoleteFiles) {
                if (Test-Path -LiteralPath $file) {
                    Remove-Item -LiteralPath $file -Force
                    Write-Host "Deleted: $file" -ForegroundColor Gray
                }
            }
            Write-Host "Obsolete thumbnails deleted." -ForegroundColor Green
        }
    }

    if ($fixCommands.Count -gt 0) {
        Write-Host "`nFound missing or obsolete thumbnails." -ForegroundColor Red
        $choice = Read-Host "Would you like to generate a 'fix_thumbnails.bat' script to resolve them? (y/n)"
        if ($choice -eq 'y') {
            $uniqueFixCommands = $fixCommands | Select-Object -Unique
            $fixScriptContent = "@echo off`r`necho Starting fast thumbnail fix process...`r`n" + ($uniqueFixCommands -join "`r`n") + "`r`necho.`r`necho Thumbnail fix process complete.`r`npause"
            # Ensure we use \r\n and correct encoding
            [System.IO.File]::WriteAllText((Join-Path (Get-Location) "fix_thumbnails.bat"), $fixScriptContent, [System.Text.Encoding]::UTF8)
            Write-Host "`nfix_thumbnails.bat has been generated." -ForegroundColor Green
        }
    } else {
        Write-Host "`nAll new videos ($newVideoCount) already have thumbnails and no obsolete thumbnails found." -ForegroundColor Green
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
            { $_ -in "1", "01" } { Update-ScDate }
            { $_ -in "2", "02" } { Update-ScData }
            { $_ -in "3", "03" } { Generate-ScNew }
            { $_ -in "4", "04" } { Update-Selections }
            { $_ -in "5", "05" } { Update-ScDate; Update-ScData; Generate-ScNew; Update-Selections }
            { $_ -in "6", "06" } { Check-Thumbnails -Fast $true }
            { $_ -in "7", "07" } { Check-Thumbnails -Fast $false }
            { $_ -in "8", "08" } { Update-New-Thumbnails }
            { $_ -in "9", "09" } { Shortcut-Manager-Menu }
            "10" { Check-EmptyVideos }
            "11" { Check-BrokenShortcutsLive }
            "12" { exit }
            Default { Write-Host "Invalid option: $c" -ForegroundColor Red }
        }
    }
    
    Write-Host "`nDone. Press any key to continue..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
