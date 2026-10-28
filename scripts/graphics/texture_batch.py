"""Fit reviewed image_gen outputs to source dimensions; back up and verify installs."""

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_path(base, relative):
    path = (base / relative).resolve()
    if not path.is_relative_to(base.resolve()):
        raise ValueError(f"Path leaves its asset directory: {relative}")
    return path


def validate_image(original, replacement):
    with Image.open(original) as before, Image.open(replacement) as after:
        before.load()
        after.load()
        if before.size != after.size:
            raise ValueError(f"Dimensions changed: {replacement}")
        if getattr(after, "n_frames", 1) != 1 or after.format != "PNG":
            raise ValueError(f"Expected a single-frame PNG: {replacement}")
        if before.convert("RGBA").getchannel("A").tobytes() != after.convert("RGBA").getchannel("A").tobytes():
            raise ValueError(f"Transparency changed: {replacement}")


def fit_detail(original, generated):
    original_rgba = original.convert("RGBA")
    alpha = original_rgba.getchannel("A")
    detail = generated.convert("RGBA")
    bounds = (0, 0, original.width, original.height)
    if alpha.getextrema()[0] < 255:
        bounds = alpha.getbbox()
        generated_bounds = detail.getchannel("A").point(lambda value: 255 if value >= 128 else 0).getbbox()
        if not bounds or not generated_bounds:
            raise ValueError("Cannot fit an empty transparent asset")
        # Generated sprites may have extra transparent padding; align visible content.
        detail = detail.crop(generated_bounds)
    size = (bounds[2] - bounds[0], bounds[3] - bounds[1])
    tolerance = .10 if alpha.getextrema()[0] < 255 else .01
    if abs((detail.width / detail.height) / (size[0] / size[1]) - 1) > tolerance:
        raise ValueError("Generated content has the wrong aspect ratio")
    if detail.width < size[0] or detail.height < size[1]:
        raise ValueError("Generated image is too small")
    layer = Image.new("RGBA", original.size)
    layer.paste(detail.resize(size, Image.Resampling.LANCZOS), bounds[:2])
    output = Image.alpha_composite(original_rgba, layer)
    output.putalpha(alpha)
    return output.convert("RGB") if original.mode == "RGB" else output


def prepare(batch, jobs):
    entries = []
    for job in jobs["entries"]:
        source = checked_path(ROOT / "Graphics", Path(job["source"]).relative_to("Graphics"))
        backup = checked_path(batch / "originals", job["source"])
        ready = checked_path(batch / "ready", job["source"])
        raw = checked_path(batch / "generated", job["source"])
        if backup.exists() and digest(source) != digest(backup):
            raise ValueError(f"Game asset differs from immutable original backup: {source}")
        with Image.open(source) as original, Image.open(job["generated"]) as generated:
            if original.format != "PNG" or getattr(original, "n_frames", 1) != 1:
                raise ValueError(f"This batch requires static PNG sources: {source}")
            original.load()
            generated.load()
            output = fit_detail(original, generated)
            ready.parent.mkdir(parents=True, exist_ok=True)
            output.save(ready, format="PNG", optimize=True)
            dimensions = list(original.size)
        validate_image(source, ready)
        backup.parent.mkdir(parents=True, exist_ok=True)
        if not backup.exists():
            shutil.copy2(source, backup)
        raw.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(job["generated"], raw)
        entries.append({"source": job["source"], "size": dimensions,
                        "before_sha256": digest(backup), "after_sha256": digest(ready),
                        "generated_sha256": digest(raw)})
    (batch / "manifest.json").write_text(json.dumps({"batch": jobs["batch"], "entries": entries}, indent=2) + "\n", encoding="utf-8")
    print(f"PREPARED {len(entries)} images with original dimensions and alpha")


def install_or_verify(batch, action):
    manifest = json.loads((batch / "manifest.json").read_text(encoding="utf-8"))
    paths = []
    for entry in manifest["entries"]:
        source = checked_path(ROOT / "Graphics", Path(entry["source"]).relative_to("Graphics"))
        backup = checked_path(batch / "originals", entry["source"])
        ready = checked_path(batch / "ready", entry["source"])
        if digest(backup) != entry["before_sha256"] or digest(ready) != entry["after_sha256"]:
            raise ValueError(f"Backup or reviewed output was modified: {source}")
        expected = entry["after_sha256"] if action in ("verify", "restore") else entry["before_sha256"]
        if digest(source) != expected:
            raise ValueError(f"Game asset changed since preparation; refusing to overwrite: {source}")
        validate_image(backup, ready)
        paths.append((source, backup if action == "restore" else ready, entry))
    # Validate the entire batch before replacing any game assets.
    for source, replacement, entry in paths:
        if action != "verify":
            temporary = source.with_name(source.name + ".texture-hd.tmp")
            shutil.copyfile(replacement, temporary)
            temporary.replace(source)
        validate_image(checked_path(batch / "originals", entry["source"]), source)
        expected = entry["before_sha256"] if action == "restore" else entry["after_sha256"]
        if digest(source) != expected:
            raise ValueError(f"Installed checksum does not match: {source}")
    print(f"{action.upper()} PASS images={len(paths)} dimensions=unchanged alpha=unchanged hashes=matched")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "apply", "verify", "restore"))
    parser.add_argument("batch", type=Path)
    args = parser.parse_args()
    batch = args.batch.resolve()
    if not batch.is_relative_to((ROOT / "output/texture-hd").resolve()):
        raise ValueError("Batch must be inside output/texture-hd")
    if args.action == "prepare":
        prepare(batch, json.loads((batch / "jobs.json").read_text(encoding="utf-8")))
    else:
        install_or_verify(batch, args.action)


if __name__ == "__main__":
    main()
