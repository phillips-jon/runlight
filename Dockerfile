# Runlight's standalone server. Build with:
#   docker build -t runlight .
# Run with:
#   docker run -p 3000:3000 -v runlight-data:/data runlight

FROM node:24-slim AS build
# better-sqlite3 compiles from source where no prebuilt binary fits.
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN npm ci --no-audit --no-fund && npm run build
RUN mkdir /pack && npm pack --silent --workspace packages/sdk --workspace packages/server --pack-destination /pack
# The install the image runs, built here so the compilers stay out of it.
WORKDIR /app
RUN npm install --omit=dev --no-audit --no-fund /pack/*.tgz

FROM node:24-slim
ENV NODE_ENV=production DATA_DIR=/data PORT=3000 HOST=0.0.0.0
WORKDIR /app
COPY --from=build /app /app
RUN mkdir -p /data && chown node:node /data
USER node
VOLUME /data
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
CMD ["node", "node_modules/runlight.sh/dist/cli.js"]
