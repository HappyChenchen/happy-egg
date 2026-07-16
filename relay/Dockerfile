FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
RUN mkdir -p /data && chown node:node /data
COPY --chown=node:node server.mjs registry.mjs ./
EXPOSE 8080
USER node
CMD ["node", "server.mjs"]
