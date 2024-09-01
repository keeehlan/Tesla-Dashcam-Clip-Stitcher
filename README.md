
# Tesla Dashcam Video Processor

A PowerShell script to process Tesla dashcam footage using FFmpeg, with support for NVIDIA GPU acceleration when available.

## Requirements

- [FFmpeg and FFprobe](https://ffmpeg.org/download.html): FFmpeg is a powerful multimedia framework that includes FFprobe, a tool for analyzing multimedia files. Ensure both tools are installed and added to your system's PATH.
- NVIDIA GPU (optional for hardware acceleration)

## Installation

1. **Download the Latest Release:**

   Download the latest release of `TeslaDashcamProcessor.ps1` from the [Releases](https://github.com/keeehlan/Tesla-Dashcam-Clip-Stitcher/releases/latest) page and save it to your desired location.

2. **Prepare Your Video Files:**

   Place your Tesla dashcam video files in a folder. The script will recursively search for folders containing videos that match the Tesla dashcam naming convention.

## Usage

1. **Open PowerShell:**

   Open PowerShell as an administrator.

2. **Navigate to the Script's Directory:**

   ```powershell
   cd path\to\TeslaDashcamProcessor
   ```

3. **Run the Script:**

   ```powershell
   .\TeslaDashcamProcessor.ps1
   ```

   The script will automatically detect Tesla dashcam video files in the current directory and its subdirectories, then process them using FFmpeg.

## Multi-Angle Video Support

This script allows you to customize the final video by selecting which camera angles to include. Tesla dashcams record from multiple cameras (front, back, left, and right), and you can control which angles appear in the processed video:

1. **Choose the Angles You Want:**
   - To include specific camera angles, copy only the video files from the desired angles (`front`, `back`, `left_repeater`, or `right_repeater`) into the working directory where you run the script.

2. **Remove Unwanted Angles:**
   - Alternatively, you can delete the video files for any camera angles you do not want to include from the working directory before running the script.

3. **Automatic Layout Optimization:**
   - The script detects the available video files and arranges them to make the best use of screen space:
     - **One video**: Scaled to fill the entire screen.
     - **Two videos**: Positioned side-by-side.
     - **Three or more videos**: Arranged in a grid format (e.g., front and back on top, left and right repeaters on the bottom).

By managing the video files in the working directory, you control which angles are included in the final output, and the script automatically optimizes the layout for the best possible viewing experience.

## Managing Clip Files

- The script looks for video files that match the pattern `YYYY-MM-DD_HH-MM-SS-(front|back|left_repeater|right_repeater).mp4`.
- You can organize your video files into different folders as needed. The script will process each folder separately and create a combined video for each unique timestamp.
- If you want to process a combination of folders, place them in a parent folder and run the script in that parent folder.

## Viewing Output

- The processed videos will be saved in a folder named `DashcamProcessing` inside each original folder.
- The final combined video will also be created in the original folder with a name like `dashcam_<timestamp>_combined.mp4`.

## Script Output

- If the script is run directly, it will wait for input before closing, allowing you to read any messages or errors.

## Contributing

Contributions are welcome! Feel free to submit issues or pull requests to improve the script.

## License

This project is licensed under the MIT License.
