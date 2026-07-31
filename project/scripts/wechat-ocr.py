import json
import sys
import hashlib
from pathlib import Path

import cv2
import numpy as np


def edge_score(image: np.ndarray, left: bool) -> float:
    width = min(64, image.shape[1] // 4)
    region = image[:, :width] if left else image[:, -width:]
    background = np.median(image.reshape(-1, 3), axis=0)
    difference = np.abs(region.astype(np.float32) - background).mean(axis=2)
    return float((difference > 18).mean())


def sender_identity(image: np.ndarray) -> dict:
    left = edge_score(image, True)
    right = edge_score(image, False)
    side = "right" if right > left * 1.2 else "left"
    height, width = image.shape[:2]
    avatar_width = min(64, width // 4)
    avatar_height = min(64, height)
    avatar = image[:avatar_height, -avatar_width:] if side == "right" else image[:avatar_height, :avatar_width]
    gray = cv2.cvtColor(avatar, cv2.COLOR_BGR2GRAY)
    thumbnail = cv2.resize(gray, (16, 16), interpolation=cv2.INTER_AREA)
    bits = (thumbnail > thumbnail.mean()).astype(np.uint8)
    avatar_hash = hashlib.sha256(bits.tobytes()).hexdigest()[:20]
    return {
        "senderId": f"avatar-{side}-{avatar_hash}",
        "side": side,
        "leftScore": round(left, 4),
        "rightScore": round(right, 4),
    }


def media_box(image: np.ndarray) -> dict | None:
    """Find the largest non-background region excluding the sender avatar area."""
    height, width = image.shape[:2]
    if height < 24 or width < 80:
        return None

    background = np.median(image.reshape(-1, 3), axis=0)
    difference = np.abs(image.astype(np.float32) - background).mean(axis=2)
    mask = (difference > 22).astype(np.uint8) * 255

    # Avatars live at either edge and are not part of the message media.
    edge = min(62, width // 5)
    mask[:, :edge] = 0
    mask[:, width - edge :] = 0
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))

    count, _, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    candidates = []
    for index in range(1, count):
        x, y, box_width, box_height, area = stats[index]
        if area < 450 or box_width < 24 or box_height < 24:
            continue
        # Small text near the top is typically the nickname, not media.
        if y < height * 0.35 and box_height < height * 0.25:
            continue
        candidates.append((area, x, y, box_width, box_height))

    if not candidates:
        return None
    _, x, y, box_width, box_height = max(candidates)
    padding = 3
    left = max(0, x - padding)
    top = max(0, y - padding)
    right = min(width, x + box_width + padding)
    bottom = min(height, y + box_height + padding)
    return {
        "x": int(left),
        "y": int(top),
        "width": int(right - left),
        "height": int(bottom - top),
    }


def main() -> int:
    output = []
    arguments = sys.argv[1:]
    output_path = None
    identity_only = len(arguments) >= 1 and arguments[0] == "--identity"
    if identity_only:
        arguments = arguments[1:]
    if len(arguments) >= 2 and arguments[0] == "--output":
        output_path = Path(arguments[1])
        arguments = arguments[2:]

    if identity_only:
        engine = None
    else:
        from rapidocr_onnxruntime import RapidOCR

        engine = RapidOCR()

    for raw_path in arguments:
        path = Path(raw_path)
        image = cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            output.append({"path": str(path), "error": "unable to read image", "lines": []})
            continue

        identity = sender_identity(image)
        if identity_only:
            output.append({"path": str(path), **identity, "mediaBox": media_box(image)})
            continue

        scale = 3
        ocr_image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
        result, _ = engine(ocr_image)
        lines = []
        for box, text, confidence in result or []:
            points = np.asarray(box, dtype=np.float32) / scale
            lines.append(
                {
                    "text": text,
                    "confidence": round(float(confidence), 4),
                    "x": round(float(points[:, 0].min()), 1),
                    "y": round(float(points[:, 1].min()), 1),
                    "width": round(float(points[:, 0].max() - points[:, 0].min()), 1),
                    "height": round(float(points[:, 1].max() - points[:, 1].min()), 1),
                }
            )
        lines.sort(key=lambda line: (line["y"], line["x"]))
        output.append(
            {
                "path": str(path),
                "width": int(image.shape[1]),
                "height": int(image.shape[0]),
                **identity,
                "lines": lines,
                "mediaBox": media_box(image),
            }
        )
    payload = json.dumps(output, ensure_ascii=False)
    if output_path is None:
        print(payload)
    else:
        output_path.write_text(payload, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
