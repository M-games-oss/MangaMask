"""
Manga Cutter AI backend.

Serves two capabilities the Flutter app calls over HTTP:
  1. POST /segment_point, /segment_box  -> SAM / MobileSAM click/box segmentation
  2. POST /inpaint                       -> LaMa inpainting for the AI Remove brush

Run locally:
    pip install -r requirements.txt
    python main.py
    # server listens on http://0.0.0.0:8000

Then point the app's "AI backend settings" at http://<your-machine-ip>:8000
(use your Mac's LAN IP, not localhost, when testing from a physical iPhone).

Model choice notes:
  - We use MobileSAM (a distilled, much smaller/faster Segment Anything model)
    by default so this can run on a laptop CPU or a modest cloud GPU without
    a big cost. Swap MODEL_TYPE/CHECKPOINT for full SAM (vit_h) if you have a
    GPU and want maximum mask quality.
  - There is no manga-specific fine-grained anatomy model to download, because
    none is publicly available. SAM is class-agnostic: it segments whatever
    coherent region contains your click, at whatever granularity that region
    has, which is why it works for "the iris" as well as "the whole arm"
    without per-class training.
  - Inpainting uses simple-lama-inpainting (LaMa), which is a strong general
    purpose "remove and fill" model and works reasonably on line-art/flat-color
    manga panels too.
"""

import base64
import io

import numpy as np
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image
from pydantic import BaseModel

app = FastAPI(title="Manga Cutter AI Backend")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Lazy-loaded models (only loaded on first request so `python main.py` starts
# instantly even before you've downloaded checkpoints).
# ---------------------------------------------------------------------------
_sam_predictor = None
_lama_model = None

import os

SAM_MODEL = os.environ.get("SAM_MODEL", "mobile")  # "mobile" or "full"

if SAM_MODEL == "full":
    MODEL_TYPE = "vit_h"
    CHECKPOINT_PATH = "weights/sam_vit_h_4b8939.pth"
else:
    MODEL_TYPE = "vit_t"
    CHECKPOINT_PATH = "weights/mobile_sam.pt"


def get_sam_predictor():
    global _sam_predictor
    if _sam_predictor is None:
        if SAM_MODEL == "full":
            from segment_anything import SamPredictor, sam_model_registry
        else:
            from mobile_sam import SamPredictor, sam_model_registry
        sam = sam_model_registry[MODEL_TYPE](checkpoint=CHECKPOINT_PATH)
        sam.eval()
        _sam_predictor = SamPredictor(sam)
    return _sam_predictor


def get_lama_model():
    global _lama_model
    if _lama_model is None:
        from simple_lama_inpainting import SimpleLama
        _lama_model = SimpleLama()
    return _lama_model


def decode_png_b64(data: str) -> Image.Image:
    return Image.open(io.BytesIO(base64.b64decode(data))).convert("RGB")


def encode_png_b64(img: Image.Image) -> str:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------
class SegmentPointRequest(BaseModel):
    image_png_base64: str
    x: int
    y: int
    label: int = 1  # 1 = include, 0 = exclude


class SegmentBoxRequest(BaseModel):
    image_png_base64: str
    box: list[int]  # [x0, y0, x1, y1]


class InpaintRequest(BaseModel):
    image_png_base64: str
    mask_png_base64: str  # white = area to remove & fill


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/segment_point")
def segment_point(req: SegmentPointRequest):
    predictor = get_sam_predictor()
    image = decode_png_b64(req.image_png_base64)
    np_image = np.array(image)
    predictor.set_image(np_image)

    masks, scores, _ = predictor.predict(
        point_coords=np.array([[req.x, req.y]]),
        point_labels=np.array([req.label]),
        multimask_output=True,
    )
    best = masks[int(np.argmax(scores))]
    mask_img = Image.fromarray((best * 255).astype(np.uint8))
    return {"mask_png_base64": encode_png_b64(mask_img)}


@app.post("/segment_box")
def segment_box(req: SegmentBoxRequest):
    predictor = get_sam_predictor()
    image = decode_png_b64(req.image_png_base64)
    np_image = np.array(image)
    predictor.set_image(np_image)

    masks, scores, _ = predictor.predict(
        box=np.array(req.box),
        multimask_output=True,
    )
    best = masks[int(np.argmax(scores))]
    mask_img = Image.fromarray((best * 255).astype(np.uint8))
    return {"mask_png_base64": encode_png_b64(mask_img)}


@app.post("/inpaint")
def inpaint(req: InpaintRequest):
    lama = get_lama_model()
    image = decode_png_b64(req.image_png_base64)
    mask = decode_png_b64(req.mask_png_base64).convert("L")
    result = lama(image, mask)
    return {"result_png_base64": encode_png_b64(result)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
