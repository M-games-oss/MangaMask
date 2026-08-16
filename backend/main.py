"""
Manga Cutter AI backend.

Serves two capabilities the Flutter app calls over HTTP:
  1. POST /segment_point, /segment_box, /segment_points -> SAM / MobileSAM
     click / box / multi-point segmentation
  2. POST /inpaint                                       -> LaMa inpainting
     for the AI Remove brush

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
    coherent region contains your prompt points, at whatever granularity that
    region has. On flat-shaded, low-contrast boundaries (an arm resting over
    a torso with no hard line between them) a single point is often not
    enough information for SAM to guess correctly - which is why
    /segment_points exists: multiple include/exclude points let the client
    disambiguate a case a single tap can't.
  - Inpainting uses simple-lama-inpainting (LaMa), which is a strong general
    purpose "remove and fill" model and works reasonably on line-art/flat-color
    manga panels too.
"""

import base64
import hashlib
import io
import os

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


# ---------------------------------------------------------------------------
# Image-embedding cache.
#
# predictor.set_image() runs the (slow) SAM image encoder. In a debounced
# brush-select flow the client calls the backend repeatedly *for the same
# image* as the user refines their stroke - re-encoding the whole image on
# every one of those calls is the difference between a ~150ms and a ~2-3s
# response on CPU. SamPredictor caches its encoder output on the instance as
# `.features` after set_image(), so we snapshot that (plus the size fields it
# needs) keyed by a hash of the image bytes, and restore it instead of
# re-encoding when the same image comes in again. Small LRU-ish cap so this
# can't grow unbounded across a long session with many different images.
# ---------------------------------------------------------------------------
_embedding_cache: dict[str, dict] = {}
_EMBEDDING_CACHE_MAX = 4


def _image_hash(png_bytes: bytes) -> str:
    return hashlib.sha256(png_bytes).hexdigest()


def _set_image_cached(predictor, raw_png_bytes: bytes, np_image: np.ndarray) -> None:
    h = _image_hash(raw_png_bytes)
    cached = _embedding_cache.get(h)
    if cached is not None:
        predictor.features = cached["features"]
        predictor.original_size = cached["original_size"]
        predictor.input_size = cached["input_size"]
        predictor.is_image_set = True
        return

    predictor.set_image(np_image)
    _embedding_cache[h] = {
        "features": predictor.features,
        "original_size": predictor.original_size,
        "input_size": predictor.input_size,
    }
    if len(_embedding_cache) > _EMBEDDING_CACHE_MAX:
        _embedding_cache.pop(next(iter(_embedding_cache)))


def decode_png_b64_raw(data: str) -> tuple[bytes, Image.Image]:
    raw = base64.b64decode(data)
    return raw, Image.open(io.BytesIO(raw)).convert("RGB")


def encode_png_b64(img: Image.Image) -> str:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def _encode_logits_b64(low_res_mask: np.ndarray) -> str:
    """Encodes one (256, 256) float32 logit map as raw base64 bytes (no PNG
    quantization - these are continuous scores, not an image)."""
    return base64.b64encode(low_res_mask.astype(np.float32).tobytes()).decode()


def _decode_logits_b64(data: str) -> np.ndarray:
    arr = np.frombuffer(base64.b64decode(data), dtype=np.float32)
    return arr.reshape(1, 256, 256)


def _top_candidates(
    masks: np.ndarray,
    scores: np.ndarray,
    low_res_masks: np.ndarray | None = None,
    limit: int = 3,
) -> list[dict]:
    """Sorts SAM's mask proposals by score (best first) and returns up to
    `limit` of them as base64 PNGs with their scores, instead of silently
    keeping only the single top-scoring one. On a flat-background manga
    panel, the "highest confidence" mask is sometimes the whole background
    or the whole figure - giving the client all 3 lets it show real
    alternatives instead of committing to a guess with no way to correct it.

    Also attaches each candidate's low-res logit map (`mask_input_b64`) when
    available. The client sends the logits of whichever candidate is
    currently selected back on the *next* call as `mask_input`, which lets
    SAM refine that specific mask instead of re-guessing from the
    accumulated points alone on every debounce - the standard SAM
    click-to-refine pattern. Without this, every refinement stroke was an
    independent, unstable re-guess, which is what made corrections feel
    like they were making things worse instead of converging.
    """
    order = np.argsort(scores)[::-1][:limit]
    out = []
    for idx in order:
        mask_img = Image.fromarray((masks[idx] * 255).astype(np.uint8))
        entry = {
            "mask_png_base64": encode_png_b64(mask_img),
            "score": float(scores[idx]),
        }
        if low_res_masks is not None:
            entry["mask_input_b64"] = _encode_logits_b64(low_res_masks[idx])
        out.append(entry)
    return out


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


class PointPrompt(BaseModel):
    x: int
    y: int
    label: int  # 1 = include, 0 = exclude


class SegmentPointsRequest(BaseModel):
    image_png_base64: str
    points: list[PointPrompt]
    # Low-res logits (base64 float32, 256x256) of whichever candidate the
    # client currently has selected, from a previous /segment_points call
    # in the same refinement session. Optional - omitted on the very first
    # call of a new selection.
    mask_input_b64: str | None = None


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
    raw, image = decode_png_b64_raw(req.image_png_base64)
    np_image = np.array(image)
    _set_image_cached(predictor, raw, np_image)

    masks, scores, _ = predictor.predict(
        point_coords=np.array([[req.x, req.y]]),
        point_labels=np.array([req.label]),
        multimask_output=True,
    )
    return {"candidates": _top_candidates(masks, scores)}


@app.post("/segment_box")
def segment_box(req: SegmentBoxRequest):
    predictor = get_sam_predictor()
    raw, image = decode_png_b64_raw(req.image_png_base64)
    np_image = np.array(image)
    _set_image_cached(predictor, raw, np_image)

    masks, scores, _ = predictor.predict(
        box=np.array(req.box),
        multimask_output=True,
    )
    return {"candidates": _top_candidates(masks, scores)}


@app.post("/segment_points")
def segment_points(req: SegmentPointsRequest):
    """Multi-point prompt: a mix of include (label=1) and exclude (label=0)
    points, e.g. sampled along a brush stroke plus an "exclude" stroke drawn
    over an overlapping limb. This is what the app's SAM brush tool calls -
    letting the user correct SAM's guess with more points instead of only
    ever getting one shot from a single tap.
    """
    if not req.points:
        return {"candidates": []}

    predictor = get_sam_predictor()
    raw, image = decode_png_b64_raw(req.image_png_base64)
    np_image = np.array(image)
    _set_image_cached(predictor, raw, np_image)

    coords = np.array([[p.x, p.y] for p in req.points])
    labels = np.array([p.label for p in req.points])
    mask_input = _decode_logits_b64(req.mask_input_b64) if req.mask_input_b64 else None

    masks, scores, low_res_masks = predictor.predict(
        point_coords=coords,
        point_labels=labels,
        mask_input=mask_input,
        multimask_output=True,
    )
    return {"candidates": _top_candidates(masks, scores, low_res_masks)}


@app.post("/inpaint")
def inpaint(req: InpaintRequest):
    lama = get_lama_model()
    _, image = decode_png_b64_raw(req.image_png_base64)
    _, mask = decode_png_b64_raw(req.mask_png_base64)
    result = lama(image, mask.convert("L"))
    return {"result_png_base64": encode_png_b64(result)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)