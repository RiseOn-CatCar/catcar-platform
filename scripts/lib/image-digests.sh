#!/usr/bin/env bash
# Print the image config digest from a single-image Docker save or OCI archive.
image_archive_config_digest() {
  python3 - "$1" <<'PY'
import hashlib
import json
import re
import sys
import tarfile


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def valid_digest(value):
    return isinstance(value, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value)


try:
    with tarfile.open(sys.argv[1]) as archive:
        def read(name):
            if not isinstance(name, str) or name.startswith("/") or ".." in name.split("/"):
                raise ValueError("Invalid archive member path")
            try:
                member = archive.extractfile(name)
            except KeyError:
                member = archive.extractfile("./" + name)
            if member is None:
                raise ValueError(f"Missing archive member: {name}")
            return member.read()

        try:
            docker_manifest = read("manifest.json")
        except KeyError:
            docker_manifest = None
        if docker_manifest is not None:
            entries = json.loads(docker_manifest)
            if not isinstance(entries, list) or len(entries) != 1:
                raise ValueError("Docker archive must contain exactly one image")
            result = digest(read(entries[0]["Config"]))
        else:
            index = json.loads(read("index.json"))
            for _ in range(4):
                manifests = index.get("manifests")
                if not isinstance(manifests, list) or len(manifests) != 1:
                    raise ValueError("OCI archive must resolve to exactly one manifest")
                descriptor = manifests[0]["digest"]
                if not valid_digest(descriptor):
                    raise ValueError("Invalid OCI manifest digest")
                blob = read("blobs/sha256/" + descriptor[7:])
                if digest(blob) != descriptor:
                    raise ValueError("OCI manifest blob digest mismatch")
                index = json.loads(blob)
                if "config" in index:
                    expected = index["config"]["digest"]
                    if not valid_digest(expected):
                        raise ValueError("Invalid OCI config digest")
                    if digest(read("blobs/sha256/" + expected[7:])) != expected:
                        raise ValueError("OCI config blob digest mismatch")
                    result = expected
                    break
            else:
                raise ValueError("OCI archive nesting exceeds limit")
        print(result)
except (OSError, tarfile.TarError, KeyError, TypeError, ValueError) as exc:
    print(f"Invalid image archive: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}
