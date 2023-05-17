#!/bin/bash

# Extract the patch content
patch_content=$(yq e '.patches[0].patch' kustomization.yaml)

# Modify the extracted patch content
modified_patch_content=$(echo "$patch_content" | yq e '.[0].value = 50' - | yq e '.[1].value = 50' -)

# Replace the patch content in the original Kustomization file
yq e ".patches[0].patch = \"$modified_patch_content\"" kustomization.yaml > kustomization_modified.yaml
mv kustomization_modified.yaml kustomization.yaml
rm -rf kustomization_modified.yaml