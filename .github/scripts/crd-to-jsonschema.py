# Converts CustomResourceDefinitions (CRDs) into the JSON schemas that kubeconform reads: one
# file per kind and served version, named <kind>-<first part of the group>-<version>.json
# (for example httproute-gateway-v1.json), the names kubeconform looks for.
# Strict, like the core schemas: every object that lists its fields refuses any other field,
# unless the CRD allows unknown fields there (x-kubernetes-preserve-unknown-fields).
# Run by .github/scripts/update-k8s-schemas.sh, with no network.
# Usage: crd-to-jsonschema.py <output folder> <kinds> <CRD file>...
#   <kinds>: the kinds to convert, separated by spaces (the other CRDs are skipped)
import json
import os
import sys

import yaml


def strict(schema):
    """Adds additionalProperties: false to every object that lists its properties."""
    if isinstance(schema, dict):
        if ("properties" in schema and "additionalProperties" not in schema
                and not schema.get("x-kubernetes-preserve-unknown-fields")):
            schema["additionalProperties"] = False
        for value in schema.values():
            strict(value)
    elif isinstance(schema, list):
        for value in schema:
            strict(value)
    return schema


def main():
    if len(sys.argv) < 4:
        sys.exit("Usage: crd-to-jsonschema.py <output folder> <kinds> <CRD file>...")
    out_dir, kinds, files = sys.argv[1], set(sys.argv[2].split()), sys.argv[3:]
    written = set()
    for path in files:
        with open(path) as f:
            for doc in yaml.safe_load_all(f):
                if not doc or doc.get("kind") != "CustomResourceDefinition":
                    continue
                spec = doc["spec"]
                kind = spec["names"]["kind"]
                if kind not in kinds:
                    continue
                for version in spec["versions"]:
                    if not version.get("served"):
                        continue
                    schema = strict(version["schema"]["openAPIV3Schema"])
                    name = f"{kind}-{spec['group'].split('.')[0]}-{version['name']}.json".lower()
                    with open(os.path.join(out_dir, name), "w") as out:
                        json.dump(schema, out, indent=2, sort_keys=True)
                        out.write("\n")
                    written.add(kind)
                    print(name, flush=True)
    missing = kinds - written
    if missing:
        sys.exit(f"No served CRD version found for: {' '.join(sorted(missing))}")


main()
