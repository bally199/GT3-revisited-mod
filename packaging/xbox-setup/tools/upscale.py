"""GT3 Revisited HD packs: Real-ESRGAN through PyTorch on CUDA (no Vulkan).

    python upscale.py <model.pth> <in folder> <out folder> [--alpha-model]

Every PNG in <in folder> comes out 4x (the model's scale) in <out folder>, same name, RGBA.
The colour goes through the model; the alpha is scaled with lanczos (a model softens or invents
steps in masks), or with --alpha-model goes through the model too, as a grey picture (the font
atlases: their glyphs' shapes are in the alpha). Each image is padded by a few mirrored pixels first so its edges see
neighbours, then cropped back. Images that fail are left out (hd-pack.ps1 checks every one
against its original and falls back for those). Prints one line per 200 images.

Needs: PyTorch with CUDA for the card (RTX 50: the cu128 wheels, PyTorch 2.7 or later),
spandrel (loads the model file), numpy and Pillow.
"""
import sys
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from spandrel import ModelLoader

PAD = 4


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    alpha_model = "--alpha-model" in sys.argv[1:]
    if len(args) != 3:
        print(__doc__)
        return 2
    model_path, src, dst = Path(args[0]), Path(args[1]), Path(args[2])
    dst.mkdir(parents=True, exist_ok=True)
    if not torch.cuda.is_available():
        print("upscale.py: no CUDA device (is the CUDA build of PyTorch installed?)")
        return 1
    device = torch.device("cuda")
    model = ModelLoader().load_from_file(str(model_path)).to(device).eval()
    half = model.supports_half
    if half:
        model.model.half()
    scale = model.scale
    print(f"upscale.py: {model.architecture.name} x{scale} on {torch.cuda.get_device_name(0)}"
          f"{' (fp16)' if half else ''}")
    files = sorted(src.glob("*.png"))
    done = failed = 0
    start = time.time()
    with torch.inference_mode():
        for i, f in enumerate(files):
            try:
                im = Image.open(f)
                im.load()
                rgba = np.asarray(im.convert("RGBA"))
                h, w = rgba.shape[:2]
                p = min(PAD, h - 1, w - 1)
                def run(rgb):
                    if p > 0:
                        rgb = np.pad(rgb, ((p, p), (p, p), (0, 0)), mode="reflect")
                    t = torch.from_numpy(np.ascontiguousarray(rgb)).to(device)
                    t = t.permute(2, 0, 1).unsqueeze(0)
                    t = t.half() if half else t.float()
                    out = model(t / 255.0)
                    out = out.clamp_(0, 1).mul_(255).round_().squeeze(0).permute(1, 2, 0)
                    up = out.to(torch.uint8).cpu().numpy()
                    if p > 0:
                        up = up[p * scale:(p + h) * scale, p * scale:(p + w) * scale]
                    return up

                up = run(rgba[..., :3])
                if alpha_model:
                    grey = run(np.repeat(rgba[..., 3:4], 3, axis=2)).astype(np.uint16)
                    alpha = ((grey[..., 0] + grey[..., 1] + grey[..., 2] + 1) // 3).astype(np.uint8)
                else:
                    alpha = np.asarray(Image.fromarray(np.ascontiguousarray(rgba[..., 3])).resize(
                        (w * scale, h * scale), Image.LANCZOS))
                result = np.dstack([up, alpha])
                Image.fromarray(np.ascontiguousarray(result), "RGBA").save(dst / f.name)
                done += 1
            except Exception as e:  # one bad image must not stop the rest
                failed += 1
                print(f"upscale.py: {f.name}: {e}")
            if (i + 1) % 200 == 0:
                print(f"upscale.py: {i + 1} of {len(files)} ({time.time() - start:.0f} s)")
    print(f"upscale.py: {done} made, {failed} failed, {time.time() - start:.0f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
