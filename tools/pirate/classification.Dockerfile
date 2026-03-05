# classification.Dockerfile - Classification image containing all three library variants
#
# Builds on top of the three already-built campaign images and collects
# each variant's /magma_out into /classification/{vulnerable,oracle,patched}/.
# The harness binary from the vulnerable build remains in $OUT and is
# shared across all replay runs; only LD_LIBRARY_PATH changes per variant.
#
# Build args:
#   vulnerable_image  image name for CANARY_MODE=1 build
#   oracle_image      image name for CANARY_MODE=3 build
#   patched_image     image name for CANARY_MODE=4 build

ARG vulnerable_image
ARG oracle_image
ARG patched_image

FROM ${vulnerable_image} AS vuln
FROM ${oracle_image}     AS oracle
FROM ${patched_image}    AS patched

# Use the vulnerable image as the base so the harness binary,
# afl-qemu-trace, and all runtime dependencies are available.
FROM ${vulnerable_image}

USER root:root
RUN mkdir -p /classification/vulnerable /classification/oracle /classification/patched

# Copy each variant's full $OUT into its own classification subdirectory.
# At replay time, set LD_LIBRARY_PATH to the desired subdirectory.
COPY --from=vuln    /magma_out /classification/vulnerable
COPY --from=oracle  /magma_out /classification/oracle
COPY --from=patched /magma_out /classification/patched

# Re-copy pirate scripts so start_classification.sh is always up to date,
# even if the base images were built before it was written.
COPY --chown=magma:magma tools/pirate/ /magma/tools/pirate/

USER magma:magma
ENTRYPOINT ["/bin/bash"]