# Open WebUI on Dockhold.
#
# Open WebUI is distributed under the Open WebUI License (see README). This
# image is the upstream release image, unchanged, plus a start script that
# wires it to Dockhold's port, App storage, your admin account and your
# model provider. Nothing is rebuilt here.
#
# Upgrading: change the tag and the digest together. The digest is the
# linux/amd64 entry printed by
#   docker buildx imagetools inspect ghcr.io/open-webui/open-webui:v<version>
# A digest that does not match the tag fails the build. That is the point.

FROM ghcr.io/open-webui/open-webui:v0.11.3@sha256:9cd136effce6bb12a6a1988a35ab3b82cb40c48a6768fceeb17c83baf7cfac9c

COPY entrypoint.sh /app/entrypoint.sh
# The image is 1.7 GB compressed and root-owned throughout. There is no
# recursive chown here: it would copy every file into a new layer. The app
# runs as user 1001 and writes only to App storage; the one exception is
# below.
#
# Upstream refreshes its favicon, splash and loader files in this folder on
# every start (it deletes the old copies and copies the bundled ones back).
# With the folder root-owned that fails, harmlessly, but with twenty
# "Permission denied" error lines at the top of every start. Handing the
# folder itself (not its contents: fonts alone are 63 MB) to user 1001 lets
# the refresh succeed and keeps the log clean. The layer holds one directory
# entry.
RUN chmod 0755 /app/entrypoint.sh \
 && chown 1001:1001 /app/backend/open_webui/static
USER 1001:1001
# Upstream has no init process of its own: its own image starts uvicorn as
# the main process. The start script execs upstream's start.sh, which execs
# uvicorn, so the stop signal from the platform reaches the server directly.
ENTRYPOINT ["/app/entrypoint.sh"]
