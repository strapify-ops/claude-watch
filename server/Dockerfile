# node:20-alpine is already on the box, so this adds almost nothing to its disk.
FROM node:20-alpine
WORKDIR /app
COPY server.js push.js ./
RUN mkdir /data && chown node:node /data
ENV PORT=8792 DATA_DIR=/data
EXPOSE 8792
USER node
CMD ["node", "server.js"]
