# StreetView Pipeline

Windows desktop app for acquiring 360-degree imagery and processing it for photogrammetry and Gaussian splatting.

## Features

- Draw a route on Google Maps and discover Street View panoramas along the path
- Batch-download equirectangular panoramas (tile-stitch primary, Static API fallback)
- Extract frames from local 360 video via FFmpeg
- Split equirectangular images into overlapping perspective views for RealityCapture / Postshot

## Prerequisites

- **Python 3.11+**
- **FFmpeg** on PATH ([download](https://ffmpeg.org/download.html))
- **Google Cloud API key** with these APIs enabled:
  - Maps JavaScript API
  - Maps Drawing Library
  - Street View Static API
  - Street View Metadata API

## Setup

```powershell
cd C:\Users\Alex\Desktop\StreetViewApp
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy .env.example .env
# Edit .env and set GOOGLE_MAPS_API_KEY
python scripts\create_test_image.py
```

## Run

Press **F5** in Cursor (configuration: **Run StreetViewApp**) or:

```powershell
python main.py
```

## Test split without API key

1. Launch the app
2. Open the **3. Process** tab
3. Click **Test split on sample image**
4. Check `output/test_split/sample_equirect/` for 6 perspective crops

## Full pipeline

1. **Map** — Draw a polyline, click **Check Street View along route**
2. **Download** — Choose output folder, click **Download panoramas** → saves to `output/equirect/`
3. **Process** — Drop a 360 video, extract frames, or split an equirect folder into perspective views

## Download modes

- **Primary:** Tile stitching at configurable zoom (`STREETVIEW_TILE_ZOOM`, default 3) for full-resolution equirect
- **Fallback:** Street View Static API (640×640 preview) when tile download fails

## Notes

- Google Maps Platform usage is billable; monitor quotas in Google Cloud Console
- Insta360 `.insv` files may need export to equirect MP4 before FFmpeg extraction
- Split output uses equatorial camera rig (yaw evenly spaced, pitch 0°)
