FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.mjs ./
EXPOSE 8080
USER node
CMD ["npm", "start"]
