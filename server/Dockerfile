FROM node:20-slim

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

ENV NODE_ENV=production
ENV DB_TABLETS_PATH=/data/tablets.sqlite
ENV DB_JUDGES_PATH=/data/judges.sqlite

EXPOSE 5000

CMD ["node", "src/server.js"]
