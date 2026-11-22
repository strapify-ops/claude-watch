# node:20-alpine is already on the box, so this adds almost nothing to its disk.
FROM node:20-alpine
WORKDIR /app
COPY server.js ./
ENV PORT=8792
EXPOSE 8792
USER node
CMD ["node", "server.js"]
