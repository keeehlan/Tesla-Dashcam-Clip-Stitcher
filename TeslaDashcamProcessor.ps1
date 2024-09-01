# Tesla Dashcam Video Processor
# Processes Tesla dashcam footage using FFmpeg with NVIDIA GPU acceleration when available

function Get-VideoProperties {
    param (
        [string]$videoPath
    )
    try {
        # Extract video properties using ffprobe
        $probeOutput = & ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=width,height,duration,nb_read_packets -of csv=p=0 $videoPath 2>&1

        # Check if the output is valid
        if ([string]::IsNullOrWhiteSpace($probeOutput) -or $probeOutput -match "Error" -or $LASTEXITCODE -ne 0) {
            Write-ColoredOutput $probeOutput
            throw "Failed to get video properties"
        }

        # Split the output into individual properties
        $properties = $probeOutput.Split(',')

        return @{
            width = [int]$properties[0]
            height = [int]$properties[1]
            duration = [float]$properties[2]
            frames = [int]$properties[3]
        }
    }
    catch {
        # Log error if video properties can't be obtained
        Write-ColoredOutput "Error processing file: $videoPath" "Red"
        Write-ColoredOutput $_.Exception.Message "Red"
        return $null
    }
}

function Test-NvencAvailable {
    # Check for NVIDIA NVENC encoder
    $ffmpegOutput = & ffmpeg -encoders 2>&1
    if ($ffmpegOutput -match "hevc_nvenc") {
        return "hevc_nvenc"
    }
    elseif ($ffmpegOutput -match "h264_nvenc") {
        return "h264_nvenc"
    }
    else {
        return $null
    }
}

function Write-ColoredOutput {
    param (
        [string]$message,
        [string]$foregroundColor = "White"
    )
    # Print colored output
    Write-Host $message -ForegroundColor $foregroundColor
}

function Test-ValidVideo {
    param (
        [string]$videoPath
    )
    try {
        # Validate the video
        $probeOutput = & ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=width,height,duration,nb_read_packets -of csv=p=0 $videoPath 2>&1
        if ([string]::IsNullOrWhiteSpace($probeOutput)) {
            return $false
        }
        # Check properties
        $properties = $probeOutput.Split(',')
        return ($properties.Count -eq 4) -and ([int]$properties[0] -eq 1920) -and ([int]$properties[1] -eq 1080) -and ([float]$properties[2] -gt 0)
    }
    catch {
        return $false
    }
}

# Define common strings for reuse
$dashcamPattern = '(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})-(front|back|left_repeater|right_repeater)\.mp4'
$outputSuffix = "_combined.mp4"
$workDir = "DashcamProcessing"

# Get all directories recursively that need to be processed
$jobDirectories = Get-ChildItem -Directory -Recurse -Exclude $workDir

# Also include the current directory itself as a separate job
$jobDirectories += Get-Item .

# Determine best encoder (NVENC if available)
$nvencEncoder = Test-NvencAvailable
if ($nvencEncoder) {
    Write-ColoredOutput "Using NVIDIA NVENC encoder: $nvencEncoder." "Green"
}
else {
    Write-ColoredOutput "NVIDIA NVENC not available, falling back to libx264." "Yellow"
    $nvencEncoder = "libx264"
}

# Process each job directory
foreach ($directory in $jobDirectories) {
    # Set processing folder path within the current job directory and delete if it exists
    $processingFolder = Join-Path -Path $directory.FullName -ChildPath $workDir
    if (Test-Path $processingFolder) {
        Remove-Item -Path $processingFolder -Recurse -Force
        Write-ColoredOutput "Deleted existing processing folder: $processingFolder" "Yellow"
    }

    # Get valid MP4 video files within the current directory only (non-recursive), matching Tesla dashcam pattern
    $videoFiles = Get-ChildItem -Path $directory.FullName -Filter "*.mp4" | Where-Object {
        $_.FullName -notmatch $workDir -and $_.Name -match $dashcamPattern
    }

    if ($videoFiles.Count -eq 0) {
        Write-ColoredOutput "No valid video files found in directory: $($directory.FullName). Skipping." "Yellow"
        continue
    }

    # Create processing folder within the current directory
    New-Item -ItemType Directory -Path $processingFolder | Out-Null

    # Extract unique timestamps from video filenames
    $timestamps = $videoFiles | ForEach-Object {
        if ($_.Name -match '(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})') {
            $matches[1]
        }
    } | Select-Object -Unique | Sort-Object

    # Store processed video files
    $processedVideos = @{}

    # Process videos for each timestamp
    foreach ($timestamp in $timestamps) {
        $clipFiles = $videoFiles | Where-Object { $_.Name -like "$timestamp-*" }

        $filterComplex = @()
        $inputs = @()
        $inputIndex = 0
        $durations = @()
        $angleMap = @{}

        Write-ColoredOutput "`nProcessing $timestamp in directory $($directory.FullName)" "Cyan"
        Write-ColoredOutput "Found $($clipFiles.Count) clip(s) for this timestamp:" "Cyan"

        # Set output file path for combined video within the processing folder
        $outputFile = Join-Path -Path $processingFolder -ChildPath "${timestamp}$outputSuffix"

        # Overwrite existing files
        $shouldProcess = $true

        # Process each clip file
        foreach ($file in $clipFiles) {
            # Extract camera angle from filename
            $angle = if ($file.Name -match '(front|back|left_repeater|right_repeater)') {
                $matches[1]
            }
            else {
                Write-ColoredOutput "Warning: Unknown angle for file $($file.Name)" "Yellow"
                "unknown"
            }
            # Get video properties
            $videoProps = Get-VideoProperties $file.FullName
            if ($null -eq $videoProps) {
                Write-ColoredOutput "Skipping file due to error: $($file.Name)" "Yellow"
                continue
            }
            # Collect durations
            $durations += $videoProps.duration

            Write-ColoredOutput "  - $($file.Name) (Angle: $angle, Duration: $($videoProps.duration)s)" "DarkCyan"

            # Add input file for FFmpeg
            $inputs += "-i `"$($file.FullName)`""

            # Add angle to map
            $angleMap[$angle] = $inputIndex
            $inputIndex++
        }

        # Find the shortest duration for synchronization
        $commonDuration = ($durations | Measure-Object -Minimum).Minimum
        Write-ColoredOutput "Common duration for synchronization: $commonDuration seconds" "Cyan"

        $filterComplex = @()
        $inputIndex = 0

        foreach ($file in $clipFiles) {
            $angle = if ($file.Name -match '(front|back|left_repeater|right_repeater)') {
                $matches[1]
            }
            else {
                Write-ColoredOutput "Warning: Unknown angle for file $($file.Name)" "Yellow"
                "unknown"
            }

            # Define filters for camera angles, trimming to common duration
            if ($angle -eq "back") {
                # Crop and scale back camera video
                $cropHeight = $videoProps.height / 2
                $cropWidth = $cropHeight * ($videoProps.width / $videoProps.height)
                $cropX = ($videoProps.width - $cropWidth) / 2
                $filterComplex += "[$inputIndex`:v]trim=end=$commonDuration,crop=$cropWidth`:$cropHeight`:$cropX`:0,scale=960:540,setsar=1[v$angle];"
            }
            else {
                # Scale and trim other camera angles
                $filterComplex += "[$inputIndex`:v]trim=end=$commonDuration,scale=960:540,setsar=1[v$angle];"
            }

            Write-ColoredOutput "Added filter for $($angle): $($filterComplex[-1])" "Gray"

            $inputIndex++
        }

        # Create black canvas for overlay
        $filterComplex += "color=black:s=1920x1080[base];"
        Write-ColoredOutput "Added base canvas: $($filterComplex[-1])" "Gray"

        # Define layout logic based on the number of videos
        if ($clipFiles.Count -eq 1) {
            # If there's only one video, scale it to full screen
            $singleAngle = $angleMap.Keys[0]
            $filterComplex += "[v$($singleAngle)]scale=1920:1080,setsar=1[scaled];[base][scaled]overlay=x=0:y=0"
        }
        elseif ($clipFiles.Count -eq 2) {
            # If there are two videos, dynamically position them side by side
            $angles = $angleMap.Keys | Sort-Object
            $filterComplex += "[base][v$($angles[0])]overlay=x=0:y=270[tmp1];[tmp1][v$($angles[1])]overlay=x=960:y=270"
        }
        else {
            # Default layout for more than two videos
            $layout = @(
                @{ angle = "front"; x = 0; y = 0 },
                @{ angle = "back"; x = 960; y = 0 },
                @{ angle = "right_repeater"; x = 0; y = 540 },
                @{ angle = "left_repeater"; x = 960; y = 540 }
            )

            $overlayCount = 0
            foreach ($item in $layout) {
                if ($angleMap.ContainsKey($item.angle)) {
                    # Apply overlay for each angle
                    $overlayPart = if ($overlayCount -eq 0) {
                        "[base][v$($item.angle)]overlay=x=$($item.x)`:y=$($item.y)"
                    }
                    else {
                        "[tmp$($overlayCount - 1)][v$($item.angle)]overlay=x=$($item.x)`:y=$($item.y)"
                    }

                    if ($overlayCount -lt ($angleMap.Count - 1)) {
                        $overlayPart += "[tmp$overlayCount];"
                    }

                    $filterComplex += $overlayPart
                    Write-ColoredOutput "Added overlay for $($item.angle): $overlayPart" "Gray"
                    $overlayCount++
                }
            }
        }

        # Cap final duration at 30 seconds, trimming to the last 30 seconds
        $finalDuration = 30
        Write-ColoredOutput "Final duration for clips: $finalDuration seconds (Trimmed to last 30 seconds)" "Cyan"

        # Construct FFmpeg command to combine videos
        $ffmpegCommand = "ffmpeg -y $($inputs -join ' ') -filter_complex `"$($filterComplex -join '')`" -c:v $nvencEncoder -ss $(($commonDuration - 30)) -t $finalDuration `"$outputFile`""

        Write-ColoredOutput "`nExecuting FFmpeg..." "Cyan"
        Invoke-Expression "$ffmpegCommand -hide_banner -loglevel warning"

        # Check FFmpeg command result
        if ($LASTEXITCODE -eq 0) {
            Write-ColoredOutput "Successfully processed $timestamp" "Green"
            # Store processed video
            $processedVideos[$timestamp] = $outputFile
        }
        else {
            Write-ColoredOutput "Error processing $timestamp" "Red"
        }
    }

    # Combine processed clips into one final video
    if ($processedVideos.Count -gt 0) {
        $sortedTimestamps = $processedVideos.Keys | Sort-Object
        $earliestTimestamp = $sortedTimestamps[0]
        $finalOutputFile = Join-Path -Path $directory -ChildPath "dashcam_${earliestTimestamp}_combined.mp4"

        # Construct FFmpeg command for final concatenation
        $concatInputs = $sortedTimestamps | ForEach-Object { "-i `"$($processedVideos[$_])`"" }
        $ffmpegConcatCommand = "ffmpeg -y $($concatInputs -join ' ') -filter_complex concat=n=$($processedVideos.Count):v=1 -c:v $nvencEncoder `"$finalOutputFile`""

        Write-ColoredOutput "`nExecuting final concatenation..." "Cyan"
        Invoke-Expression "$ffmpegConcatCommand -hide_banner -loglevel warning"

        # Check result of final concatenation
        if ($LASTEXITCODE -eq 0) {
            Write-ColoredOutput "Successfully created final video: $finalOutputFile" "Green"
        }
        else {
            Write-ColoredOutput "Error creating final video for directory: $($directory.FullName)" "Red"
        }
    }

    Write-ColoredOutput "`nProcessing complete for directory: $($directory.FullName)" "Magenta"
}

Write-ColoredOutput "`nAll processing complete." "Magenta"

# Wait for user input if script is run directly
if ($MyInvocation.InvocationName -eq $null) {
    Write-ColoredOutput "`nPress any key to exit..." "Magenta"
    $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null
}
