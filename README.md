# Manga Cutter — iOS app for cutting up manga characters/panels into layers

## Honest note on "AI body part detection" before you build this

There is no existing model — free or paid — that outputs manga-specific
labeled body parts (iris vs. eyelid vs. sclera, individual fingers, etc.).
Nobody has published one, and training one from scratch would need a large
hand-labeled manga dataset. Any app claiming to do that out of the box is
either using something much coarser than it sounds, or lying.

What actually works well for this job, and what this app is built around:

1. **Flood-fill "Smart Select"** — fully on-device, no ML, no backend needed.
   Manga art is almost always flat color/tone cels bounded by black line art,
   so tap-to-select-region is a genuinely reliable way to grab an eye, a hair
   lock, a sleeve, etc. This is the tool you'll use most.
2. **SAM (Segment Anything / MobileSAM) click-select** — tap the iris and
   *only the iris* gets selected; tap the whole arm and the whole arm gets
   selected. SAM is class-agnostic, so it adapts to whatever granularity you
   click at, which is a much better match for "detect any body part" than a
   fixed-class detector would be. Requires the small Python backend in
   `backend/`.
3. **Magnetic lasso** — Sobel edge detection snaps your free-drawn line to
   line-art contours. On-device, no backend.
4. **Manual polygon lasso, brush eraser, restore brush** — precision fallback
   for anything the automatic tools get wrong.
5. **AI Remove brush** (LaMa inpainting, via the same backend) — paint over
   something and it's filled in using the surrounding art, instead of leaving
   a blank hole. Falls back to a soft transparent erase if the backend isn't
   configured, so the app is fully usable offline.
6. **Auto panel detection** — connected-component analysis finds panel
   boundaries on a scanned page so you can crop to one panel before cutting a
   character out of it.

Everything in (1), (3), (4), (6) works with zero setup. (2) and (5) need the
optional backend below.

## Project structure

```
manga_cutter/
  lib/
    models/          Layer + tool enums
    services/         flood fill, edge detection, panel detection,
                       SAM + inpaint backend clients, undo/redo, main controller
    widgets/           canvas, layers panel, toolbar
    screens/           editor screen
    main.dart
  backend/             optional FastAPI server for SAM + LaMa
```

## Running the Flutter app

You need a Mac with Xcode for iOS. This container can't run `flutter` or
build for iOS, so do this locally:

```bash
# 1. Get Flutter: https://docs.flutter.dev/get-started/install/macos
flutter --version

# 2. Copy this manga_cutter/ folder to your Mac, then inside it:
flutter create --platforms=ios .    # generates the ios/ native runner
flutter pub get

# 3. Add photo library permission (required for image_picker on iOS):
#    open ios/Runner/Info.plist and add:
#      <key>NSPhotoLibraryUsageDescription</key>
#      <string>Manga Cutter needs access to your photos to import artwork.</string>

# 4. Run on a simulator or device
open -a Simulator
flutter run
```

## Running the optional AI backend

```bash
cd backend
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt

# Download the MobileSAM checkpoint (~40MB):
mkdir -p weights
curl -L -o weights/mobile_sam.pt \
  https://github.com/ChaoningZhang/MobileSAM/raw/master/weights/mobile_sam.pt

python main.py
# -> listening on http://0.0.0.0:8000
```

In the app, tap the antenna icon in the top bar and set both backend URLs to
`http://<your-computer's-LAN-IP>:8000` (not `localhost` — your phone is a
separate device on the network). Testing on the iOS Simulator, `localhost`
does work.

For real use you'd deploy `backend/` to a small GPU box (Modal, RunPod,
Fly.io + GPU, a spare machine with an NVIDIA card, etc.) — MobileSAM runs
adequately on CPU for single images, but a GPU makes it near-instant.

## Swapping in full-size SAM for higher quality masks

`backend/main.py` defaults to MobileSAM for speed. To use full SAM (better
edges, slower):

```python
MODEL_TYPE = "vit_h"
CHECKPOINT_PATH = "weights/sam_vit_h_4b8939.pth"
```
and `pip install git+https://github.com/facebookresearch/segment-anything.git`
instead of the MobileSAM package, download the `vit_h` checkpoint from Meta's
SAM repo, and swap the import in `get_sam_predictor()` accordingly.

## How the core workflow works

1. Import a manga page or character image.
2. (Optional) Auto-detect panels, tap one to crop the canvas to just that panel.
3. Pick **Smart Select** (offline) or **AI Select** (backend) and tap a part —
   it's cut into its own new layer with the source layer punched transparent
   underneath.
4. Use **Magnetic/Polygon Lasso** for parts flood fill can't isolate cleanly
   (e.g. a part that spans several colors).
5. Clean up edges with the **Eraser**; use **Restore Brush** to bring back
   any pixels you removed by mistake (it reads from an untouched backup of
   the layer, so it's always available, no backend needed).
6. Use the **AI Remove brush** to erase stray marks/lines and have the hole
   filled in automatically instead of left blank.
7. **Duplicate** layers from the layers panel (top-right toggle) to make
   variants, reorder by dragging, adjust opacity, rename.
8. **Export** — flattened PNG, or any single layer (e.g. just "Left Eye") as
   its own transparent PNG.
