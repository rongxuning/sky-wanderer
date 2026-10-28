FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src
COPY migrations ./migrations

ENV NODE_ENV=production
USER node
EXPOSE 8787

CMD ["node", "--experimental-strip-types", "src/index.ts"]
